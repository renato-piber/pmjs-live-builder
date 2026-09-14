#!/bin/bash

MOUNTS_DRY_RUN="${MOUNTS_DRY_RUN:-1}"
INSTALL_TARGET_ROOT=""
INSTALL_TARGET_HOME=""
INSTALL_TARGET_EFI=""
INSTALL_MOUNTS_READY=0

mounts_is_dry_run() {
    case "${MOUNTS_DRY_RUN,,}" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

mounts_log_command() {
    local command="$*"
    log_info "Comando de montagem: $command"
}

mounts_resolve_path() {
    local path="$1"

    readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
}

mounts_partition_belongs_to_disk() {
    local partition="$1"
    local disk="$2"
    local parent=""

    [ -n "$partition" ] || return 1
    [ -n "$disk" ] || return 1

    parent=$(lsblk -no PKNAME "$partition" 2>/dev/null | xargs || true)

    [ -n "$parent" ] || return 1

    [ "$(basename "$parent")" = "$(basename "$disk")" ]
}

mounts_validate_partition_device() {
    local partition="$1"
    local label="$2"

    if [ -z "$partition" ]; then
        ui_error "A partição $label não foi definida."
        log_error "Partição ausente na validação de montagem: $label"
        return 1
    fi

    if [[ "$partition" != /dev/* ]]; then
        ui_error "A partição $label não começa com /dev/: $partition"
        log_error "Partição inválida para montagem: $partition"
        return 1
    fi

    if [ ! -e "$partition" ]; then
        ui_error "A partição $label não existe: $partition"
        log_error "Dispositivo inexistente na validação de montagem: $partition"
        return 1
    fi

    if [ ! -b "$partition" ]; then
        ui_error "A partição $label não é um dispositivo de bloco: $partition"
        log_error "Dispositivo de bloco inválido: $partition"
        return 1
    fi

    if ! mounts_partition_belongs_to_disk "$partition" "$INSTALL_DISK"; then
        ui_error "A partição $label não pertence ao disco alvo: $partition"
        log_error "Partição fora do disco alvo: $partition"
        return 1
    fi

    return 0
}

mounts_validate_target_mount() {
    local target_mount="$1"
    local resolved_target=""

    if [ -z "$target_mount" ]; then
        ui_error "O ponto de montagem não foi definido."
        log_error "Ponto de montagem ausente na validação de montagem."
        return 1
    fi

    if [[ "$target_mount" != /* ]]; then
        ui_error "O ponto de montagem deve ser um caminho absoluto: $target_mount"
        log_error "Ponto de montagem relativo inválido: $target_mount"
        return 1
    fi

    if [ -e "$target_mount" ] && [ ! -d "$target_mount" ]; then
        ui_error "O ponto de montagem não é um diretório: $target_mount"
        log_error "Ponto de montagem inválido: $target_mount"
        return 1
    fi

    resolved_target=$(mounts_resolve_path "$target_mount" 2>/dev/null || true)

    case "$resolved_target" in
        /|/home|/boot|/boot/efi|/dev|/proc|/sys|/run|/mnt|/tmp|/var|/etc|/usr|/lib|/bin|/sbin|/root)
            ui_error "O ponto de montagem não pode ser um diretório crítico do sistema Live: $target_mount"
            log_error "Ponto de montagem crítico rejeitado: $target_mount"
            return 1
            ;;
    esac

    if mountpoint -q "$target_mount"; then
        local mounted_source=""
        mounted_source=$(findmnt -rn -M "$target_mount" -o SOURCE 2>/dev/null || true)
        mounted_source=$(mounts_resolve_path "$mounted_source" 2>/dev/null || true)

        if [ -n "$mounted_source" ] && [ "$mounted_source" != "$(mounts_resolve_path "$INSTALL_ROOT_PARTITION" 2>/dev/null || true)" ]; then
            ui_error "O ponto de montagem já está ocupado por outro filesystem: $target_mount"
            log_error "Ponto de montagem já montado: $target_mount"
            return 1
        fi
    fi

    return 0
}

mounts_validate() {
    local target_mount="${INSTALL_TARGET_MOUNT:-}"
    local efi_fs=""
    local root_fs=""
    local home_fs=""
    local actual_source=""

    if [ -z "${INSTALL_DISK:-}" ]; then
        ui_error "Nenhum disco de destino foi definido para montagem."
        log_error "Disco ausente antes da montagem."
        return 1
    fi

    if ! validate_disk; then
        return 1
    fi

    if [ -z "${INSTALL_ROOT_PARTITION:-}" ] || [ -z "${INSTALL_HOME_PARTITION:-}" ]; then
        ui_error "As partições de montagem não foram identificadas."
        log_error "Partições ausentes antes de montar."
        return 1
    fi

    if [ "$INSTALL_ROOT_PARTITION" = "$INSTALL_HOME_PARTITION" ]; then
        ui_error "Root e home devem ser partições diferentes."
        log_error "Partições de montagem duplicadas."
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        if [ -z "${INSTALL_EFI_PARTITION:-}" ]; then
            ui_error "A partição EFI não foi definida no modo UEFI."
            return 1
        fi
        if [ "$INSTALL_EFI_PARTITION" = "$INSTALL_ROOT_PARTITION" ] || [ "$INSTALL_EFI_PARTITION" = "$INSTALL_HOME_PARTITION" ]; then
            ui_error "Root, home e EFI devem ser partições diferentes."
            return 1
        fi
        if ! mounts_validate_partition_device "$INSTALL_EFI_PARTITION" "EFI"; then
            return 1
        fi
    fi

    if ! mounts_validate_partition_device "$INSTALL_ROOT_PARTITION" "root"; then
        return 1
    fi

    if ! mounts_validate_partition_device "$INSTALL_HOME_PARTITION" "home"; then
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        efi_fs=$(blkid -o value -s TYPE "$INSTALL_EFI_PARTITION" 2>/dev/null || true)
    fi
    root_fs=$(blkid -o value -s TYPE "$INSTALL_ROOT_PARTITION" 2>/dev/null || true)
    home_fs=$(blkid -o value -s TYPE "$INSTALL_HOME_PARTITION" 2>/dev/null || true)

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        case "$efi_fs" in
            vfat|fat32) ;;
            *)
                ui_error "O sistema de arquivos da EFI não é válido para montagem: $efi_fs"
                log_error "Tipo de filesystem inválido para EFI: $efi_fs"
                return 1
                ;;
        esac
    fi

    case "$root_fs" in
        btrfs)
            ;;
        *)
            ui_error "O sistema de arquivos da root não é btrfs: $root_fs"
            log_error "Tipo de filesystem inválido para root: $root_fs"
            return 1
            ;;
    esac

    case "$home_fs" in
        btrfs)
            ;;
        *)
            ui_error "O sistema de arquivos da home não é btrfs: $home_fs"
            log_error "Tipo de filesystem inválido para home: $home_fs"
            return 1
            ;;
    esac

    case "${INSTALL_STORAGE_MODE:-}" in
        clean|preserve_home)
            ;;
        *)
            ui_error "Modo de armazenamento inválido para montagem: ${INSTALL_STORAGE_MODE:-não definido}"
            log_error "Modo de armazenamento inválido: ${INSTALL_STORAGE_MODE:-não definido}"
            return 1
            ;;
    esac

    if disks_is_protected "$INSTALL_DISK"; then
        ui_error "O disco alvo está protegido e não pode ser montado: $INSTALL_DISK"
        log_error "Tentativa de montar disco protegido: $INSTALL_DISK"
        return 1
    fi

    if ! mounts_validate_target_mount "$target_mount"; then
        return 1
    fi

    # if mountpoint -q "$INSTALL_TARGET_MOUNT"; then
    # actual_source=$(findmnt -rn -M "$INSTALL_TARGET_MOUNT" -o SOURCE 2>/dev/null || true)

    # if [ "$(mounts_resolve_path "$actual_source")" != \
    #      "$(mounts_resolve_path "$INSTALL_ROOT_PARTITION")" ]; then
    #     ui_error "O ponto de montagem já está ocupado por outro dispositivo: $actual_source"
    #     log_error "Ponto $INSTALL_TARGET_MOUNT já ocupado por $actual_source"
    #     return 1
    # fi
    # fi

    return 0
}

mounts_unmount_mountpoint() {
    local mountpoint_path="$1"
    local expected_source="$2"
    local actual_source=""

    [ -n "$mountpoint_path" ] || return 0

    # Não existe uma montagem exata neste ponto.
    if ! mountpoint -q "$mountpoint_path"; then
        return 0
    fi

    actual_source=$(
        findmnt -rn -M "$mountpoint_path" -o SOURCE 2>/dev/null || true
    )

    if [ -z "$actual_source" ]; then
        ui_error "Não foi possível identificar a montagem em $mountpoint_path"
        log_error "Montagem exata não identificada em $mountpoint_path"
        return 1
    fi

    if [ -n "$expected_source" ] &&
       [ "$(mounts_resolve_path "$actual_source")" != \
         "$(mounts_resolve_path "$expected_source")" ]; then
        ui_error "O ponto $mountpoint_path está montado com $actual_source, não com $expected_source"
        log_error "Montagem inesperada detectada em $mountpoint_path: $actual_source"
        return 1
    fi

    mounts_log_command "umount $mountpoint_path"

    log_run_external umount "$mountpoint_path" || {
        ui_error "Falha ao desmontar $mountpoint_path"
        log_error "Falha ao desmontar $mountpoint_path"
        return 1
    }

    return 0
}

mounts_unmount_target() {
    local target_root="$INSTALL_TARGET_MOUNT"
    local target_home="$target_root/home"
    local target_efi="$target_root/boot/efi"

    [ -n "$target_root" ] || return 0

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        if ! mounts_unmount_mountpoint "$target_efi" "$INSTALL_EFI_PARTITION"; then
            return 1
        fi
    fi

    if ! mounts_unmount_mountpoint "$target_home" "$INSTALL_HOME_PARTITION"; then
        return 1
    fi

    if ! mounts_unmount_mountpoint "$target_root" "$INSTALL_ROOT_PARTITION"; then
        return 1
    fi

    return 0
}

mounts_prepare_directories() {
    local target_root="${INSTALL_TARGET_ROOT:-$INSTALL_TARGET_MOUNT}"

    if mounts_is_dry_run; then
        mounts_log_command "mkdir -p $target_root"
        return 0
    fi

    mkdir -p "$target_root" || {
        ui_error "Falha ao criar o diretório raiz de montagem em $target_root"
        log_error "Falha ao preparar o diretório raiz de montagem"
        return 1
    }

    return 0
}

mounts_mount_partitions() {
    local target_root="${INSTALL_TARGET_ROOT:-$INSTALL_TARGET_MOUNT}"
    local target_home="${INSTALL_TARGET_HOME:-$target_root/home}"
    local target_efi="${INSTALL_TARGET_EFI:-$target_root/boot/efi}"

    if mounts_is_dry_run; then
        mounts_log_command "mount $INSTALL_ROOT_PARTITION $target_root"
        mounts_log_command "mkdir -p $target_home"
        if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
            mounts_log_command "mkdir -p $target_efi"
        fi
        mounts_log_command "mount $INSTALL_HOME_PARTITION $target_home"
        if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
            mounts_log_command "mount $INSTALL_EFI_PARTITION $target_efi"
        fi
        return 0
    fi

    mounts_log_command "mount $INSTALL_ROOT_PARTITION $target_root"

    log_run_external mount "$INSTALL_ROOT_PARTITION" "$target_root" || {
        ui_error "Falha ao montar root em $target_root"
        log_error "Falha ao montar root em $target_root"
        mounts_cleanup_on_error
        return 1
    }

    mkdir -p "$target_home" || {
        ui_error "Falha ao criar o diretório home em $target_home"
        log_error "Falha ao criar $target_home"
        mounts_cleanup_on_error
        return 1
    }

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        mkdir -p "$target_efi" || {
            ui_error "Falha ao criar o diretório EFI em $target_efi"
            log_error "Falha ao criar $target_efi"
            mounts_cleanup_on_error
            return 1
        }
    fi

    mounts_log_command "mount $INSTALL_HOME_PARTITION $target_home"

    log_run_external mount "$INSTALL_HOME_PARTITION" "$target_home" || {
        ui_error "Falha ao montar home em $target_home"
        log_error "Falha ao montar home em $target_home"
        mounts_cleanup_on_error
        return 1
    }

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        mounts_log_command "mount $INSTALL_EFI_PARTITION $target_efi"
        log_run_external mount "$INSTALL_EFI_PARTITION" "$target_efi" || {
            ui_error "Falha ao montar EFI em $target_efi"
            log_error "Falha ao montar EFI em $target_efi"
            mounts_cleanup_on_error
            return 1
        }
    fi

    return 0
}

mounts_verify() {
    local target_root="${INSTALL_TARGET_ROOT:-$INSTALL_TARGET_MOUNT}"
    local target_home="${INSTALL_TARGET_HOME:-$target_root/home}"
    local target_efi="${INSTALL_TARGET_EFI:-$target_root/boot/efi}"
    local actual_source=""
    local actual_fstype=""

    if ! mountpoint -q "$target_root"; then
        ui_error "O ponto raiz não está montado: $target_root"
        log_error "Verificação da montagem raiz falhou"
        return 1
    fi

    actual_source=$(findmnt -rn -M "$target_root" -o SOURCE 2>/dev/null || true)
    actual_source=$(mounts_resolve_path "$actual_source" 2>/dev/null || true)

    if [ "$actual_source" != "$(mounts_resolve_path "$INSTALL_ROOT_PARTITION" 2>/dev/null || true)" ]; then
        ui_error "A montagem raiz não corresponde ao dispositivo esperado: $actual_source"
        log_error "Verificação da montagem raiz falhou"
        return 1
    fi

    actual_fstype=$(findmnt -rn -M "$target_root" -o FSTYPE 2>/dev/null || true)
    if [ "$actual_fstype" != "btrfs" ]; then
        ui_error "O sistema de arquivos montado em $target_root não é btrfs: $actual_fstype"
        log_error "Verificação de filesystem root falhou"
        return 1
    fi

    if ! mountpoint -q "$target_home"; then
        ui_error "O ponto home não está montado: $target_home"
        log_error "Verificação da montagem home falhou"
        return 1
    fi

    actual_source=$(findmnt -rn -M "$target_home" -o SOURCE 2>/dev/null || true)
    actual_source=$(mounts_resolve_path "$actual_source" 2>/dev/null || true)

    if [ "$actual_source" != "$(mounts_resolve_path "$INSTALL_HOME_PARTITION" 2>/dev/null || true)" ]; then
        ui_error "A montagem home não corresponde ao dispositivo esperado: $actual_source"
        log_error "Verificação da montagem home falhou"
        return 1
    fi

    actual_fstype=$(findmnt -rn -M "$target_home" -o FSTYPE 2>/dev/null || true)
    if [ "$actual_fstype" != "btrfs" ]; then
        ui_error "O sistema de arquivos montado em $target_home não é btrfs: $actual_fstype"
        log_error "Verificação de filesystem home falhou"
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ] && ! mountpoint -q "$target_efi"; then
        ui_error "O ponto EFI não está montado: $target_efi"
        log_error "Verificação da montagem EFI falhou"
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        actual_source=$(findmnt -rn -M "$target_efi" -o SOURCE 2>/dev/null || true)
        actual_source=$(mounts_resolve_path "$actual_source" 2>/dev/null || true)

        if [ "$actual_source" != "$(mounts_resolve_path "$INSTALL_EFI_PARTITION" 2>/dev/null || true)" ]; then
            ui_error "A montagem EFI não corresponde ao dispositivo esperado: $actual_source"
            log_error "Verificação da montagem EFI falhou"
            return 1
        fi

        actual_fstype=$(findmnt -rn -M "$target_efi" -o FSTYPE 2>/dev/null || true)
        if [ "$actual_fstype" != "vfat" ]; then
            ui_error "O sistema de arquivos montado em $target_efi não é vfat: $actual_fstype"
            log_error "Verificação de filesystem EFI falhou"
            return 1
        fi
    fi

    log_info "Verificação das montagens concluída com sucesso"
    return 0
}

mounts_cleanup_on_error() {
    local target_root="${INSTALL_TARGET_ROOT:-$INSTALL_TARGET_MOUNT}"
    local target_home="${INSTALL_TARGET_HOME:-$target_root/home}"
    local target_efi="${INSTALL_TARGET_EFI:-$target_root/boot/efi}"

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ] && [ -n "$target_efi" ] && ! mounts_unmount_mountpoint "$target_efi" "$INSTALL_EFI_PARTITION"; then
        return 1
    fi

    if [ -n "$target_home" ] && ! mounts_unmount_mountpoint "$target_home" "$INSTALL_HOME_PARTITION"; then
        return 1
    fi

    if [ -n "$target_root" ] && ! mounts_unmount_mountpoint "$target_root" "$INSTALL_ROOT_PARTITION"; then
        return 1
    fi

    return 0
}

mounts_apply() {
    local target_mount="${INSTALL_TARGET_MOUNT:-/mnt/pmjs-target}"

    INSTALL_TARGET_ROOT=""
    INSTALL_TARGET_HOME=""
    INSTALL_TARGET_EFI=""
    INSTALL_MOUNTS_READY=0

    INSTALL_TARGET_MOUNT="${INSTALL_TARGET_MOUNT:-$target_mount}"
    INSTALL_TARGET_ROOT="$INSTALL_TARGET_MOUNT"
    INSTALL_TARGET_HOME="$INSTALL_TARGET_MOUNT/home"
    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        INSTALL_TARGET_EFI="$INSTALL_TARGET_MOUNT/boot/efi"
    fi

    if ! mounts_validate; then
        return 1
    fi

    if mounts_is_dry_run; then
        ui_warning "Dry-run de montagem ativo: nenhum ponto será criado nem montado."
        log_info "Dry-run ativo para montagem; somente o plano será registrado."
        INSTALL_MOUNTS_READY=0
        return 0
    fi

    if ! mounts_unmount_target; then
        return 1
    fi

    if ! mounts_prepare_directories; then
        return 1
    fi

    if ! mounts_mount_partitions; then
        mounts_cleanup_on_error "$INSTALL_TARGET_ROOT" "$INSTALL_TARGET_HOME" "$INSTALL_TARGET_EFI"
        INSTALL_MOUNTS_READY=0
        return 1
    fi

    if ! mounts_verify; then
        mounts_cleanup_on_error "$INSTALL_TARGET_ROOT" "$INSTALL_TARGET_HOME" "$INSTALL_TARGET_EFI"
        INSTALL_MOUNTS_READY=0
        return 1
    fi

    INSTALL_MOUNTS_READY=1
    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        ui_success "Montagem concluída: $INSTALL_TARGET_ROOT, $INSTALL_TARGET_HOME e $INSTALL_TARGET_EFI"
    else
        ui_success "Montagem concluída: $INSTALL_TARGET_ROOT e $INSTALL_TARGET_HOME"
    fi
    log_info "Montagem concluída para $INSTALL_DISK"

    return 0
}
