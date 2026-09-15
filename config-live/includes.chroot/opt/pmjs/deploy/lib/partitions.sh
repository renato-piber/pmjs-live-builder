#!/bin/bash

PARTITIONS_DRY_RUN="${PARTITIONS_DRY_RUN:-1}"
 
partitions_is_dry_run() {
    case "${PARTITIONS_DRY_RUN,,}" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

partitions_log_command() {
    local command="$*"
    log_info "Comando de particionamento: $command"
}

partitions_unmount_target_partitions() {
    local disk="$1"
    local path type pkname

    while read -r path type pkname; do
        [ -n "$path" ] || continue
        [ "$type" = "part" ] || continue
        [ -n "$pkname" ] || continue
        [ "$pkname" = "$(basename "$disk")" ] || continue

        if mountpoint -q "$path"; then
            partitions_log_command "umount $path"
            log_run_external umount "$path" || {
                ui_error "Falha ao desmontar $path"
                log_error "Falha ao desmontar $path"
                return 1
            }
        fi
    done < <(lsblk -nrpo PATH,TYPE,PKNAME "$disk" 2>/dev/null || true)
}

partitions_list_real_partitions() {
    local disk="$1"
    local path type pkname

    while read -r path type pkname; do
        [ -n "$path" ] || continue
        [ "$type" = "part" ] || continue
        [ -n "$pkname" ] || continue
        [ "$(basename "$pkname")" = "$(basename "$disk")" ] || continue

        printf '%s\n' "$path"
    done < <(
        lsblk -nrpo PATH,TYPE,PKNAME "$disk" 2>/dev/null |
            sort -V
    )
}

partitions_apply_clean_plan() {
    local disk="$1"
    local efi_bytes swap_bytes root_bytes home_bytes
    local efi_mib swap_mib root_mib
    local -a partitions=()
    local partition_count=0
    local partition_path
    local partition_table="gpt"
    local actual_partition_table=""
    local expected_partition_count=4
    efi_bytes="$STORAGE_EFI_SIZE_MIN_BYTES"
    swap_bytes=$(numfmt --from=iec "$DEFAULT_SWAP_SIZE")
    root_bytes=$(numfmt --from=iec "$DEFAULT_ROOT_SIZE")

    if [ "${INSTALL_BOOT_MODE:-}" = "legacy" ]; then
        partition_table="msdos"
    fi

    ui_warning "Aplicando plano de particionamento em modo clean para $disk"
    log_info "Iniciando execução segura do plano de particionamento clean para $disk"

    validate_disk || return 1

    if ! disks_is_protected "$disk"; then
        :
    else
        ui_error "O disco $disk está protegido e não pode ser alterado."
        log_error "Tentativa de particionar disco protegido: $disk"
        return 1
    fi

    if partitions_is_dry_run; then
        ui_warning "Dry-run ativo: nenhuma escrita em disco será executada."
        log_info "Dry-run ativo; somente a validação e o plano serão simulados."
        return 0
    fi

    if ! partitions_unmount_target_partitions "$disk"; then
        return 1
    fi

    efi_mib=$(( (efi_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))
    swap_mib=$(( (swap_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))
    root_mib=$(( (root_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))

    efi_start_mib=1
    efi_end_mib=$((efi_start_mib + efi_mib))

    if [ "$partition_table" = "gpt" ]; then
        swap_start_mib=$efi_end_mib
    else
        swap_start_mib=1
    fi
    swap_end_mib=$((swap_start_mib + swap_mib))

    root_start_mib=$swap_end_mib
    root_end_mib=$((root_start_mib + root_mib))

    partitions_log_command "parted -s $disk mklabel $partition_table"

    log_run_external parted -s "$disk" mklabel "$partition_table" || {
        ui_error "Falha ao criar a tabela $partition_table em $disk"
        log_error "Falha ao criar a tabela $partition_table em $disk"
        return 1
    }

    partitions_log_command "partprobe $disk"

    log_run_external partprobe "$disk" || {
        ui_error "Falha ao atualizar o kernel após recriar a tabela em $disk"
        log_error "Falha ao atualizar o kernel após recriar a tabela em $disk"
        return 1
    }

    partitions_log_command "udevadm settle"

    log_run_external udevadm settle || {
        ui_error "Falha ao aguardar o udev após recriar a tabela em $disk"
        log_error "Falha ao aguardar o udev após recriar a tabela em $disk"
        return 1
    }

    if [ "$partition_table" = "gpt" ]; then
        partitions_log_command \
            "parted -s $disk unit MiB mkpart EFI fat32 ${efi_start_mib}MiB ${efi_end_mib}MiB"
        log_run_external parted -s "$disk" unit MiB \
            mkpart EFI fat32 "${efi_start_mib}MiB" "${efi_end_mib}MiB"
    fi || {
            ui_error "Falha ao criar a partição EFI em $disk"
            log_error "Falha ao criar a partição EFI em $disk"
            return 1
        }

    if [ "$partition_table" = "gpt" ]; then
        partitions_log_command "parted -s $disk set 1 esp on"
        log_run_external parted -s "$disk" set 1 esp on || {
            ui_error "Falha ao marcar a partição EFI como ESP em $disk"
            log_error "Falha ao marcar a partição EFI como ESP em $disk"
            return 1
        }
    fi

    if [ "$partition_table" = "gpt" ]; then
        partitions_log_command "parted -s $disk unit MiB mkpart swap linux-swap ${swap_start_mib}MiB ${swap_end_mib}MiB"
        log_run_external parted -s "$disk" unit MiB mkpart swap linux-swap "${swap_start_mib}MiB" "${swap_end_mib}MiB"
    else
        partitions_log_command "parted -s $disk unit MiB mkpart primary linux-swap ${swap_start_mib}MiB ${swap_end_mib}MiB"
        log_run_external parted -s "$disk" unit MiB mkpart primary linux-swap "${swap_start_mib}MiB" "${swap_end_mib}MiB"
    fi || {
            ui_error "Falha ao criar a partição swap em $disk"
            log_error "Falha ao criar a partição swap em $disk"
            return 1
        }

    if [ "$partition_table" = "gpt" ]; then
        partitions_log_command "parted -s $disk unit MiB mkpart root btrfs ${root_start_mib}MiB ${root_end_mib}MiB"
        log_run_external parted -s "$disk" unit MiB mkpart root btrfs "${root_start_mib}MiB" "${root_end_mib}MiB"
    else
        partitions_log_command "parted -s $disk unit MiB mkpart primary btrfs ${root_start_mib}MiB ${root_end_mib}MiB"
        log_run_external parted -s "$disk" unit MiB mkpart primary btrfs "${root_start_mib}MiB" "${root_end_mib}MiB"
    fi || {
            ui_error "Falha ao criar a partição root em $disk"
            log_error "Falha ao criar a partição root em $disk"
            return 1
        }

    if [ "$partition_table" = "gpt" ]; then
        partitions_log_command "parted -s $disk unit MiB mkpart home btrfs ${root_end_mib}MiB 100%"
        log_run_external parted -s "$disk" unit MiB mkpart home btrfs "${root_end_mib}MiB" 100%
    else
        partitions_log_command "parted -s $disk unit MiB mkpart primary btrfs ${root_end_mib}MiB 100%"
        log_run_external parted -s "$disk" unit MiB mkpart primary btrfs "${root_end_mib}MiB" 100%
    fi || {
            ui_error "Falha ao criar a partição home em $disk"
            log_error "Falha ao criar a partição home em $disk"
            return 1
        }

    partitions_log_command "partprobe $disk"

    log_run_external partprobe "$disk" || {
        ui_error "Falha ao atualizar o kernel para $disk"
        log_error "Falha ao atualizar o kernel para $disk"
        return 1
    }

    partitions_log_command "udevadm settle"

    log_run_external udevadm settle || {
        ui_error "Falha ao aguardar a estabilização do udev"
        log_error "Falha ao aguardar a estabilização do udev"
        return 1
    }

    actual_partition_table=$(parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2 {print $6}' || true)
    if [ "$actual_partition_table" != "$partition_table" ]; then
        ui_error "Tabela de partição inesperada em $disk: ${actual_partition_table:-não identificada}"
        log_error "Esperada tabela $partition_table, detectada ${actual_partition_table:-vazia}."
        return 1
    fi
    log_info "Tabela de partição confirmada em $disk: $actual_partition_table"

    while IFS= read -r partition_path; do
        [ -n "$partition_path" ] || continue
        partitions+=("$partition_path")
        partition_count=$((partition_count + 1))
    done < <(partitions_list_real_partitions "$disk")

    if [ "$partition_table" = "msdos" ]; then
        expected_partition_count=3
    fi
    if [ "$partition_count" -ne "$expected_partition_count" ]; then
        ui_error "Esperadas $expected_partition_count partições, mas foram detectadas $partition_count em $disk"
        log_error "Particionamento incompleto: $partition_count partições detectadas"
        return 1
    fi

    if [ "$partition_table" = "gpt" ]; then
        INSTALL_EFI_PARTITION="${partitions[0]}"
        INSTALL_SWAP_PARTITION="${partitions[1]}"
        INSTALL_ROOT_PARTITION="${partitions[2]}"
        INSTALL_HOME_PARTITION="${partitions[3]}"
    else
        INSTALL_EFI_PARTITION=""
        INSTALL_SWAP_PARTITION="${partitions[0]}"
        INSTALL_ROOT_PARTITION="${partitions[1]}"
        INSTALL_HOME_PARTITION="${partitions[2]}"
    fi

    ui_success "$expected_partition_count partições detectadas e registradas para $disk"
    log_info "Partições detectadas: $INSTALL_EFI_PARTITION | $INSTALL_SWAP_PARTITION | $INSTALL_ROOT_PARTITION | $INSTALL_HOME_PARTITION"

    return 0
}

partitions_apply_preserve_home_plan() {
    local disk="$1"

    ui_warning "Modo preserve_home: nenhuma alteração será feita no disco $disk"
    log_info "Iniciando execução segura do plano preserve_home para $disk"

    validate_disk || return 1

    if ! storage_detect_eduinstall_layout "$disk"; then
        ui_error "Não foi possível confirmar um layout EduInstall válido em $disk"
        log_error "Layout EduInstall não confirmado em $disk"
        return 1
    fi

    if [ -z "$INSTALL_SWAP_PARTITION" ] || [ -z "$INSTALL_ROOT_PARTITION" ] || [ -z "$INSTALL_HOME_PARTITION" ]; then
        ui_error "As partições do layout EduInstall não foram preenchidas para $disk"
        log_error "Variáveis de partição incompletas para $disk"
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ] && [ -z "$INSTALL_EFI_PARTITION" ]; then
        ui_error "A partição EFI do layout UEFI não foi identificada em $disk"
        log_error "Partição EFI ausente no layout UEFI de $disk"
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "legacy" ] && [ -n "$INSTALL_EFI_PARTITION" ]; then
        ui_error "O layout Legacy oficial não deve conter partição EFI em $disk"
        log_error "Partição EFI inesperada no layout Legacy de $disk: $INSTALL_EFI_PARTITION"
        return 1
    fi

    log_info "Plano preserve_home concluído sem alterações: $disk"
    return 0
}

partitions_apply_plan() {
    local disk="${INSTALL_DISK:-}"

    if [ -z "$disk" ]; then
        ui_error "Nenhum disco de destino definido para particionar."
        log_error "Tentativa de aplicar plano sem disco definido"
        return 1
    fi

    if [[ "$disk" != /dev/* ]]; then
        ui_error "O disco de destino não é válido: $disk"
        log_error "Dispositivo inválido para particionamento: $disk"
        return 1
    fi

    log_info "Iniciando execução do plano de particionamento para $disk"

    case "${INSTALL_STORAGE_MODE:-}" in
        clean)
            partitions_apply_clean_plan "$disk"
            ;;
        preserve_home)
            partitions_apply_preserve_home_plan "$disk"
            ;;
        *)
            ui_error "Modo de armazenamento inválido para particionamento: ${INSTALL_STORAGE_MODE:-não definido}"
            log_error "Modo de armazenamento inválido: ${INSTALL_STORAGE_MODE:-não definido}"
            return 1
            ;;
    esac
}
