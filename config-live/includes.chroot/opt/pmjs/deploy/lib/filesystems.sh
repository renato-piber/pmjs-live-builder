#!/bin/bash

FILESYSTEMS_DRY_RUN="${FILESYSTEMS_DRY_RUN:-1}"

filesystems_is_dry_run() {
    case "${FILESYSTEMS_DRY_RUN,,}" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

filesystems_log_command() {
    local command="$*"
    log_info "Comando de filesystem: $command"
}

filesystems_validate_partitions() {
    local disk="$1"

    if [ -z "$disk" ]; then
        ui_error "Nenhum disco definido para formatação."
        log_error "Disco ausente na validação de filesystem."
        return 1
    fi

    if [[ "$disk" != /dev/* ]]; then
        ui_error "Disco inválido para formatação: $disk"
        log_error "Disco inválido: $disk"
        return 1
    fi

    if [ ! -b "$disk" ]; then
        ui_error "O caminho não é um dispositivo de bloco: $disk"
        log_error "Dispositivo de bloco inválido: $disk"
        return 1
    fi

    if [ -z "$INSTALL_SWAP_PARTITION" ] || [ -z "$INSTALL_ROOT_PARTITION" ] || [ -z "$INSTALL_HOME_PARTITION" ]; then
        ui_error "As partições de instalação não foram identificadas."
        log_error "Partições ausentes antes da formatação."
        return 1
    fi

    local -a partitions_to_validate=("$INSTALL_SWAP_PARTITION" "$INSTALL_ROOT_PARTITION" "$INSTALL_HOME_PARTITION")
    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        if [ -z "$INSTALL_EFI_PARTITION" ]; then
            ui_error "A partição EFI não foi identificada no modo UEFI."
            return 1
        fi
        partitions_to_validate=("$INSTALL_EFI_PARTITION" "${partitions_to_validate[@]}")
    fi

    for partition in "${partitions_to_validate[@]}"; do
        if [ -z "$partition" ]; then
            ui_error "Uma das partições está vazia: $partition"
            log_error "Partição vazia detectada."
            return 1
        fi

        if [[ "$partition" != /dev/* ]]; then
            ui_error "Partição inválida: $partition"
            log_error "Partição inválida: $partition"
            return 1
        fi

        if [ ! -b "$partition" ]; then
            ui_error "A partição não é um dispositivo de bloco: $partition"
            log_error "Dispositivo de bloco inválido: $partition"
            return 1
        fi

        if [ "$(lsblk -no PKNAME "$partition" 2>/dev/null | xargs || true)" != "$(basename "$disk")" ]; then
            ui_error "A partição não pertence ao disco alvo: $partition"
            log_error "Partição fora do disco alvo: $partition"
            return 1
        fi
    done

    if [ "$INSTALL_ROOT_PARTITION" = "$INSTALL_HOME_PARTITION" ]; then
        ui_error "Root e home não podem ser a mesma partição."
        log_error "Root e home coincidem."
        return 1
    fi

    if disks_is_protected "$disk"; then
        ui_error "O disco alvo está protegido: $disk"
        log_error "Tentativa de formatar disco protegido: $disk"
        return 1
    fi

    return 0
}

filesystems_verify() {
    local disk="$1"
    local expected_efi="$2"
    local expected_swap="$3"
    local expected_root="$4"
    local expected_home="$5"
    local actual_efi_fs actual_swap_fs actual_root_fs actual_home_fs

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        actual_efi_fs=$(blkid -o value -s TYPE "$INSTALL_EFI_PARTITION" 2>/dev/null || true)
    fi
    actual_swap_fs=$(blkid -o value -s TYPE "$INSTALL_SWAP_PARTITION" 2>/dev/null || true)
    actual_root_fs=$(blkid -o value -s TYPE "$INSTALL_ROOT_PARTITION" 2>/dev/null || true)
    actual_home_fs=$(blkid -o value -s TYPE "$INSTALL_HOME_PARTITION" 2>/dev/null || true)

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ] && [ "$actual_efi_fs" != "$expected_efi" ]; then
        ui_error "Tipo incorreto na EFI: esperado $expected_efi, obtido $actual_efi_fs"
        log_error "Verificação de EFI falhou"
        return 1
    fi

    if [ "$actual_swap_fs" != "$expected_swap" ]; then
        ui_error "Tipo incorreto em swap: esperado $expected_swap, obtido $actual_swap_fs"
        log_error "Verificação de swap falhou"
        return 1
    fi

    if [ "$actual_root_fs" != "$expected_root" ]; then
        ui_error "Tipo incorreto em root: esperado $expected_root, obtido $actual_root_fs"
        log_error "Verificação de root falhou"
        return 1
    fi

    if [ "$actual_home_fs" != "$expected_home" ]; then
        ui_error "Tipo incorreto em home: esperado $expected_home, obtido $actual_home_fs"
        log_error "Verificação de home falhou"
        return 1
    fi

    log_info "Verificação de filesystem concluída com sucesso em $disk"
    return 0
}

filesystems_format_clean() {
    local disk="$1"

    ui_warning "Formatando as partições em modo clean para $disk"
    log_info "Iniciando formatação clean para $disk"

    filesystems_validate_partitions "$disk" || return 1

    if filesystems_is_dry_run; then 
        if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
            filesystems_log_command "mkfs.vfat -F 32 -n PMJS_EFI ${INSTALL_EFI_PARTITION}"
        fi
        filesystems_log_command "mkswap -L PMJS_SWAP ${INSTALL_SWAP_PARTITION}"
        filesystems_log_command "mkfs.btrfs -f -L PMJS_ROOT ${INSTALL_ROOT_PARTITION}"
        filesystems_log_command "mkfs.btrfs -f -L PMJS_HOME ${INSTALL_HOME_PARTITION}"
        log_info "Dry-run ativo para formatação clean."
        return 0
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        filesystems_log_command "mkfs.vfat -F 32 -n PMJS_EFI ${INSTALL_EFI_PARTITION}"
        log_run_external mkfs.vfat -F 32 -n PMJS_EFI "$INSTALL_EFI_PARTITION" || {
            ui_error "Falha ao formatar EFI"
            log_error "Falha ao formatar EFI"
            return 1
        }
    fi

    filesystems_log_command "mkswap -L PMJS_SWAP ${INSTALL_SWAP_PARTITION}"
    log_run_external mkswap -L PMJS_SWAP "$INSTALL_SWAP_PARTITION" || {
        ui_error "Falha ao inicializar swap"
        log_error "Falha ao inicializar swap"
        return 1
    }

    filesystems_log_command "mkfs.btrfs -f -L PMJS_ROOT ${INSTALL_ROOT_PARTITION}"
    log_run_external mkfs.btrfs -f -L PMJS_ROOT "$INSTALL_ROOT_PARTITION" || {
        ui_error "Falha ao formatar root"
        log_error "Falha ao formatar root"
        return 1
    }

    filesystems_log_command "mkfs.btrfs -f -L PMJS_HOME ${INSTALL_HOME_PARTITION}"
    log_run_external mkfs.btrfs -f -L PMJS_HOME "$INSTALL_HOME_PARTITION" || {
        ui_error "Falha ao formatar home"
        log_error "Falha ao formatar home"
        return 1
    }

    log_run_external udevadm settle || {
        ui_error "Falha ao aguardar o udev após a formatação"
        log_error "Falha ao aguardar o udev após a formatação"
        return 1
    }

    filesystems_verify "$disk" "vfat" "swap" "btrfs" "btrfs" || return 1

    return 0
}

filesystems_format_preserve_home() {
    local disk="$1"
    local home_uuid_before home_uuid_after

    ui_warning "Formatando somente root em modo preserve_home para $disk"
    log_info "Iniciando formatação preserve_home para $disk"

    filesystems_validate_partitions "$disk" || return 1
    storage_preserve_home_validate_snapshot || return 1
    if [ "$INSTALL_ROOT_PARTITION" = "$INSTALL_HOME_PARTITION" ] ||
       [ "$INSTALL_ROOT_PARTITION" = "$INSTALL_SWAP_PARTITION" ] ||
       { [ -n "${INSTALL_EFI_PARTITION:-}" ] &&
         [ "$INSTALL_ROOT_PARTITION" = "$INSTALL_EFI_PARTITION" ]; }; then
        ui_error "O alvo da formatação root coincide com uma partição preservada."
        log_error "Preserve_home pré-destrutivo: mkfs bloqueado para root=$INSTALL_ROOT_PARTITION home=$INSTALL_HOME_PARTITION swap=$INSTALL_SWAP_PARTITION EFI=${INSTALL_EFI_PARTITION:-não aplicável}."
        return 1
    fi

    if filesystems_is_dry_run; then
        filesystems_log_command "mkfs.btrfs -f -L PMJS_ROOT ${INSTALL_ROOT_PARTITION}"
        log_info "Dry-run ativo para formatação preserve_home."
        return 0
    fi

    home_uuid_before=$(blkid -s UUID -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
    if [ -z "$home_uuid_before" ] ||
       [ "$home_uuid_before" != "$PRESERVE_HOME_SNAPSHOT_UUID" ]; then
        ui_error "O UUID da home não pôde ser reconfirmado antes da formatação."
        log_error "Preserve_home pré-destrutivo: UUID final antes do mkfs é '${home_uuid_before:-vazio}'."
        return 1
    fi

    filesystems_log_command "mkfs.btrfs -f -L PMJS_ROOT ${INSTALL_ROOT_PARTITION}"
    INSTALL_DESTRUCTIVE_STARTED=1
    log_warning "Preserve_home: ponto destrutivo iniciado; formatando somente root=$INSTALL_ROOT_PARTITION. Home=$INSTALL_HOME_PARTITION permanece protegida."
    log_run_external mkfs.btrfs -f -L PMJS_ROOT "$INSTALL_ROOT_PARTITION" || {
        ui_error "Falha ao formatar root em preserve_home"
        log_error "Preserve_home pós-ponto-destrutivo: falha ao formatar root; nenhum rollback será simulado."
        return 1
    }

    log_run_external udevadm settle || {
        ui_error "Falha ao aguardar o udev após a formatação preserve_home"
        log_error "Falha ao aguardar o udev após a formatação preserve_home"
        return 1
    }

    home_uuid_after=$(blkid -s UUID -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)

    if [ -z "$home_uuid_after" ] || [ "$home_uuid_before" != "$home_uuid_after" ]; then
        ui_error "UUID da home mudou durante o preserve_home"
        log_error "Preserve_home pós-ponto-destrutivo: UUID da home mudou ou desapareceu."
        return 1
    fi

    log_info "home preservada: UUID antes=$home_uuid_before depois=$home_uuid_after"
    filesystems_verify "$disk" "vfat" "swap" "btrfs" "btrfs" || return 1

    return 0
}

filesystems_apply_plan() {
    local disk="${INSTALL_DISK:-}"

    if [ -z "$disk" ]; then
        ui_error "Nenhum disco definido para formatação."
        log_error "Disco ausente para a formatação."
        return 1
    fi

    if [ -z "${INSTALL_STORAGE_MODE:-}" ]; then
        ui_error "Modo de armazenamento não definido."
        log_error "Modo de armazenamento ausente."
        return 1
    fi

    case "$INSTALL_STORAGE_MODE" in
        clean)
            filesystems_format_clean "$disk"
            ;;
        preserve_home)
            filesystems_format_preserve_home "$disk"
            ;;
        *)
            ui_error "Modo de armazenamento não suportado para formatação: $INSTALL_STORAGE_MODE"
            log_error "Modo de armazenamento inválido para formatação"
            return 1
            ;;
    esac
}
