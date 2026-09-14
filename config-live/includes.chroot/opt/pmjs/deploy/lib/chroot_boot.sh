#!/bin/bash

INSTALL_BOOT_READY=0
CHROOT_BOOT_GRUB_INSTALLED=0
CHROOT_BOOT_RESOLV_BACKUP_DIR=""
CHROOT_BOOT_RESOLV_PREPARED=0
CHROOT_BOOT_MOUNTS_CREATED=()

chroot_boot_is_dry_run() {
    [ "${INSTALL_EXECUTION_MODE:-dry-run}" != "real" ]
}

chroot_boot_log_command() {
    local quoted=""
    local argument=""

    for argument in "$@"; do
        printf -v quoted '%s%q ' "$quoted" "$argument"
    done
    log_info "Comando de boot: ${quoted% }"
}

chroot_boot_resolve_path() {
    readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"
}

chroot_boot_validate_mount() {
    local target="$1"
    local expected_source="$2"
    local label="$3"
    local actual_source=""

    if ! mountpoint -q "$target"; then
        ui_error "$label não está montada exatamente em $target."
        log_error "Montagem ausente para $label em $target."
        return 1
    fi

    actual_source=$(findmnt -rn -M "$target" -o SOURCE 2>/dev/null || true)
    if [ "$(chroot_boot_resolve_path "$actual_source")" != \
         "$(chroot_boot_resolve_path "$expected_source")" ]; then
        ui_error "A origem de $label em $target é inesperada: ${actual_source:-não identificada}."
        log_error "Origem de montagem inesperada para $label."
        return 1
    fi
}

chroot_boot_find_kernels() {
    find "$INSTALL_TARGET_ROOT/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -size +0c -print 2>/dev/null
}

chroot_boot_find_initramfs() {
    find "$INSTALL_TARGET_ROOT/boot" -maxdepth 1 -type f -name 'initrd.img-*' -size +0c -print 2>/dev/null
}

chroot_boot_dpkg_status_has_package() {
    local status_file="$1"
    local package="$2"

    awk -v wanted="$package" '
        BEGIN { RS=""; FS="\n" }
        {
            found_package=0
            found_status=0
            for (i=1; i<=NF; i++) {
                if ($i == "Package: " wanted) found_package=1
                if ($i == "Status: install ok installed") found_status=1
            }
            if (found_package && found_status) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$status_file"
}

chroot_boot_validate_legacy_disk_layout() {
    local table_type=""
    local bios_grub=""

    [ "${INSTALL_BOOT_MODE:-}" = "legacy" ] || return 0

    if [ "${INSTALL_STORAGE_MODE:-}" = "clean" ]; then
        log_info "Preflight Legacy: o plano clean criará tabela MBR/MSDOS."
        return 0
    fi

    table_type=$(parted -sm "$INSTALL_DISK" print 2>/dev/null | awk -F: 'NR==2 {print $6}' || true)
    case "$table_type" in
        msdos)
            log_info "Preflight Legacy: tabela MBR/MSDOS compatível detectada em $INSTALL_DISK."
            return 0
            ;;
        gpt)
            bios_grub=$(parted -sm "$INSTALL_DISK" print 2>/dev/null |
                awk -F: 'NR>2 && $7 ~ /bios_grub/ {print $1; exit}' || true)
            if [ -n "$bios_grub" ]; then
                log_info "Preflight Legacy: partição bios_grub detectada em $INSTALL_DISK (número $bios_grub)."
                return 0
            fi
            ui_error "Modo Legacy bloqueado: $INSTALL_DISK usa GPT sem partição bios_grub."
            log_error "Layout Legacy incompatível: GPT sem bios_grub em $INSTALL_DISK."
            return 1
            ;;
        *)
            ui_error "Não foi possível identificar uma tabela MBR ou GPT válida em $INSTALL_DISK."
            log_error "Tabela de partição não identificada no preflight Legacy: ${table_type:-vazia}."
            return 1
            ;;
    esac
}

chroot_boot_preflight_legacy_image() {
    local archive="${EXTRACT_ROOTFS_ARCHIVE:-}"

    [ "${INSTALL_BOOT_MODE:-}" = "legacy" ] || return 0
    if [ -z "$archive" ]; then
        archive="${INSTALL_IMAGE_DIR:-}/rootfs.tar.gz"
    fi

    log_info "Preflight Legacy leve no archive: $archive"
    if [ -z "${INSTALL_IMAGE_DIR:-}" ] || [ -z "$archive" ]; then
        ui_error "O caminho do archive rootfs não foi definido para a instalação Legacy."
        log_error "Preflight Legacy falhou: caminho do rootfs não definido."
        return 1
    fi
    if [ ! -e "$archive" ]; then
        ui_error "O archive rootfs não existe para a instalação Legacy: $archive"
        log_error "Preflight Legacy falhou: archive rootfs inexistente: $archive"
        return 1
    fi
    if [ ! -f "$archive" ]; then
        ui_error "O caminho do rootfs não é um arquivo regular: $archive"
        log_error "Preflight Legacy falhou: rootfs não é arquivo regular: $archive"
        return 1
    fi
    log_info "Preflight Legacy: archive rootfs existente."

    if [ ! -r "$archive" ]; then
        ui_error "O archive rootfs não é legível para a instalação Legacy: $archive"
        log_error "Preflight Legacy falhou: archive rootfs sem permissão de leitura: $archive"
        return 1
    fi
    log_info "Preflight Legacy: archive rootfs legível."

    if [ ! -s "$archive" ]; then
        ui_error "O archive rootfs está vazio: $archive"
        log_error "Preflight Legacy falhou: archive rootfs vazio."
        return 1
    fi
    log_info "Preflight Legacy: archive rootfs não vazio."

    chroot_boot_validate_legacy_disk_layout || return 1
    log_info "Preflight Legacy leve concluído sem leitura integral e antes do particionamento."
}

chroot_boot_validate_legacy_target() {
    local status_file="$INSTALL_TARGET_ROOT/var/lib/dpkg/status"

    [ "$INSTALL_BOOT_MODE" = "legacy" ] || return 0
    if [ ! -s "$INSTALL_TARGET_ROOT/usr/lib/grub/i386-pc/modinfo.sh" ]; then
        ui_error "Módulos GRUB Legacy ausentes: /usr/lib/grub/i386-pc/modinfo.sh"
        log_error "modinfo.sh do target ausente ou vazio."
        return 1
    fi
    log_info "Dependência Legacy confirmada no target: /usr/lib/grub/i386-pc/modinfo.sh"
    if [ ! -r "$status_file" ]; then
        ui_error "Banco dpkg do sistema instalado não está acessível."
        log_error "Banco dpkg ausente ou ilegível no target: $status_file"
        return 1
    fi
    if ! chroot_boot_dpkg_status_has_package "$status_file" "grub-pc-bin"; then
        ui_error "Pacote Legacy não está instalado no target: grub-pc-bin"
        log_error "Validação pós-extração falhou para o pacote grub-pc-bin."
        return 1
    fi
    log_info "Pacote Legacy obrigatório confirmado no target: grub-pc-bin"
    if chroot_boot_dpkg_status_has_package "$status_file" "grub-pc"; then
        log_info "Pacote Legacy confirmado no target: grub-pc"
    else
        log_warning "Pacote grub-pc não consta como instalado no target; grub-pc-bin e os módulos i386-pc estão disponíveis."
    fi
    if [ ! -x "$INSTALL_TARGET_ROOT/usr/sbin/grub-install" ] &&
       [ ! -x "$INSTALL_TARGET_ROOT/sbin/grub-install" ]; then
        ui_error "grub-install não existe no sistema Legacy extraído."
        log_error "Validação Legacy pós-extração falhou: grub-install ausente ou não executável."
        return 1
    fi
    log_info "Executável Legacy confirmado no target: grub-install"

    if [ ! -x "$INSTALL_TARGET_ROOT/usr/sbin/update-grub" ] &&
       [ ! -x "$INSTALL_TARGET_ROOT/sbin/update-grub" ]; then
        ui_error "update-grub não existe no sistema Legacy extraído."
        log_error "Validação Legacy pós-extração falhou: update-grub ausente ou não executável."
        return 1
    fi
    log_info "Executável Legacy confirmado no target: update-grub"

    chroot_boot_validate_legacy_disk_layout
}

chroot_boot_validate() {
    local target_root="${INSTALL_TARGET_ROOT:-}"
    local disk_type=""
    local efi_fstype=""

    if [ -z "$target_root" ] || [ "$target_root" = "/" ]; then
        ui_error "Destino raiz inválido para preparação do boot: ${target_root:-não definido}."
        log_error "INSTALL_TARGET_ROOT inválido para chroot."
        return 1
    fi

    if [ -z "${INSTALL_DISK:-}" ] || [[ "$INSTALL_DISK" != /dev/* ]]; then
        ui_error "O disco inteiro de destino não foi definido corretamente."
        log_error "INSTALL_DISK inválido para instalação do boot."
        return 1
    fi

    case "${INSTALL_BOOT_MODE:-}" in
        uefi|legacy) ;;
        *)
            ui_error "Modo de boot inválido: ${INSTALL_BOOT_MODE:-não definido}."
            log_error "Modo de boot inválido para chroot."
            return 1
            ;;
    esac

    if [ -z "${INSTALL_ROOT_PARTITION:-}" ] || [ -z "${INSTALL_HOME_PARTITION:-}" ]; then
        ui_error "As partições root e home devem estar definidas para o chroot."
        log_error "Partições root/home ausentes para instalação do boot."
        return 1
    fi

    if chroot_boot_is_dry_run; then
        return 0
    fi

    if [ "$(id -u)" -ne 0 ]; then
        ui_error "A preparação do boot deve ser executada como root."
        return 1
    fi

    if [ ! -b "$INSTALL_DISK" ]; then
        ui_error "O destino não é um dispositivo de bloco: $INSTALL_DISK."
        return 1
    fi
    disk_type=$(lsblk -dn -o TYPE -- "$INSTALL_DISK" 2>/dev/null | head -n1 || true)
    if [ "$disk_type" != "disk" ]; then
        ui_error "O destino do GRUB não é um disco inteiro: $INSTALL_DISK."
        return 1
    fi
    if disks_is_protected "$INSTALL_DISK"; then
        ui_error "O disco $INSTALL_DISK está protegido e não pode receber o GRUB."
        return 1
    fi

    if [ "${INSTALL_EXTRACT_READY:-0}" -ne 1 ] || [ "${INSTALL_SYSTEM_CONFIG_READY:-0}" -ne 1 ]; then
        ui_error "Extração e configuração do sistema devem estar concluídas antes do boot."
        log_error "Estados anteriores incompletos para instalação do boot."
        return 1
    fi

    chroot_boot_validate_mount "$target_root" "$INSTALL_ROOT_PARTITION" "root" || return 1
    chroot_boot_validate_mount "$target_root/home" "$INSTALL_HOME_PARTITION" "home" || return 1

    if [ ! -x "$target_root/bin/bash" ]; then
        ui_error "O target não contém /bin/bash executável."
        return 1
    fi
    if [ ! -s "$target_root/etc/fstab" ] || [ ! -s "$target_root/etc/hostname" ]; then
        ui_error "fstab ou hostname ausente/vazio no sistema instalado."
        return 1
    fi
    if [ -z "$(chroot_boot_find_kernels)" ] || [ -z "$(chroot_boot_find_initramfs)" ]; then
        ui_error "Kernel ou initramfs não foi encontrado em $target_root/boot."
        return 1
    fi
    if ! command -v chroot >/dev/null 2>&1; then
        ui_error "O comando chroot não está disponível no ambiente Live."
        return 1
    fi
    if [ ! -x "$target_root/usr/bin/env" ]; then
        ui_error "O target não contém /usr/bin/env executável."
        return 1
    fi
    if [ ! -x "$target_root/usr/sbin/update-initramfs" ] && [ ! -x "$target_root/sbin/update-initramfs" ]; then
        ui_error "update-initramfs não existe no sistema instalado."
        return 1
    fi
    if [ ! -x "$target_root/usr/sbin/grub-install" ] && [ ! -x "$target_root/sbin/grub-install" ]; then
        ui_error "grub-install não existe no sistema instalado."
        return 1
    fi
    if [ ! -x "$target_root/usr/sbin/update-grub" ] &&
       [ ! -x "$target_root/sbin/update-grub" ] &&
       [ ! -x "$target_root/usr/sbin/grub-mkconfig" ] &&
       [ ! -x "$target_root/sbin/grub-mkconfig" ]; then
        ui_error "update-grub e grub-mkconfig não existem no sistema instalado."
        return 1
    fi

    chroot_boot_validate_legacy_target || return 1

    if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
        if [ -z "${INSTALL_EFI_PARTITION:-}" ]; then
            ui_error "A partição EFI não foi definida."
            return 1
        fi
        chroot_boot_validate_mount "$target_root/boot/efi" "$INSTALL_EFI_PARTITION" "EFI" || return 1
        efi_fstype=$(findmnt -rn -M "$target_root/boot/efi" -o FSTYPE 2>/dev/null || true)
        case "$efi_fstype" in
            vfat|fat32) ;;
            *)
                ui_error "O filesystem montado na EFI não é vfat: ${efi_fstype:-não identificado}."
                return 1
                ;;
        esac
        [ -d "$target_root/boot/efi" ] || mkdir -p "$target_root/boot/efi"
    fi
}

chroot_boot_prepare_resolv_conf() {
    local target_resolv="$INSTALL_TARGET_ROOT/etc/resolv.conf"

    CHROOT_BOOT_RESOLV_PREPARED=0
    CHROOT_BOOT_RESOLV_BACKUP_DIR=""
    if [ ! -s /etc/resolv.conf ]; then
        log_warning "resolv.conf do Live indisponível; DNS temporário não é necessário para esta Sprint."
        return 0
    fi

    CHROOT_BOOT_RESOLV_BACKUP_DIR=$(mktemp -d "$INSTALL_TARGET_ROOT/etc/.pmjs-resolv.XXXXXX") || return 1
    if [ -e "$target_resolv" ] || [ -L "$target_resolv" ]; then
        if ! cp -a "$target_resolv" "$CHROOT_BOOT_RESOLV_BACKUP_DIR/resolv.conf"; then
            rmdir "$CHROOT_BOOT_RESOLV_BACKUP_DIR" 2>/dev/null || true
            CHROOT_BOOT_RESOLV_BACKUP_DIR=""
            return 1
        fi
    fi

    CHROOT_BOOT_RESOLV_PREPARED=1
    rm -f "$target_resolv" || return 1
    cp -L /etc/resolv.conf "$target_resolv" || return 1
    chmod 0644 "$target_resolv" || return 1
    log_info "DNS temporário preparado no target."
}

chroot_boot_restore_resolv_conf() {
    local target_resolv="${INSTALL_TARGET_ROOT:-}/etc/resolv.conf"

    [ "$CHROOT_BOOT_RESOLV_PREPARED" -eq 1 ] || return 0
    rm -f "$target_resolv" || return 1
    if [ -e "$CHROOT_BOOT_RESOLV_BACKUP_DIR/resolv.conf" ] ||
       [ -L "$CHROOT_BOOT_RESOLV_BACKUP_DIR/resolv.conf" ]; then
        cp -a "$CHROOT_BOOT_RESOLV_BACKUP_DIR/resolv.conf" "$target_resolv" || return 1
    fi
    rm -f "$CHROOT_BOOT_RESOLV_BACKUP_DIR/resolv.conf"
    rmdir "$CHROOT_BOOT_RESOLV_BACKUP_DIR" 2>/dev/null || true
    CHROOT_BOOT_RESOLV_PREPARED=0
    CHROOT_BOOT_RESOLV_BACKUP_DIR=""
}

chroot_boot_mount_one() {
    local source="$1"
    local target="$2"
    local kind="$3"

    if mountpoint -q "$target"; then
        log_info "Montagem pré-existente preservada em $target."
        return 0
    fi

    case "$kind" in
        rbind)
            chroot_boot_log_command mount --rbind "$source" "$target"
            log_run_external mount --rbind "$source" "$target" || return 1
            chroot_boot_log_command mount --make-rslave "$target"
            log_run_external mount --make-rslave "$target" || {
                log_run_external umount --recursive "$target" || true
                return 1
            }
            ;;
        proc)
            chroot_boot_log_command mount -t proc proc "$target"
            log_run_external mount -t proc proc "$target" || return 1
            ;;
    esac
    CHROOT_BOOT_MOUNTS_CREATED+=("$target")
}

chroot_boot_mount_pseudo_filesystems() {
    local target_root="$INSTALL_TARGET_ROOT"

    CHROOT_BOOT_MOUNTS_CREATED=()
    mkdir -p "$target_root/dev/pts" "$target_root/proc" "$target_root/sys" "$target_root/run" || return 1
    chroot_boot_mount_one /dev "$target_root/dev" rbind || return 1
    chroot_boot_mount_one proc "$target_root/proc" proc || return 1
    chroot_boot_mount_one /sys "$target_root/sys" rbind || return 1
    chroot_boot_mount_one /run "$target_root/run" rbind || return 1
}

chroot_boot_unmount_pseudo_filesystems() {
    local index=0
    local target=""
    local failed=0

    for ((index=${#CHROOT_BOOT_MOUNTS_CREATED[@]} - 1; index >= 0; index--)); do
        target="${CHROOT_BOOT_MOUNTS_CREATED[$index]}"
        if mountpoint -q "$target"; then
            chroot_boot_log_command umount --recursive "$target"
            if ! log_run_external umount --recursive "$target"; then
                ui_error "Falha ao desmontar pseudo-filesystem criado em $target."
                log_error "Cleanup de pseudo-filesystem falhou em $target."
                failed=1
            fi
        fi
    done
    CHROOT_BOOT_MOUNTS_CREATED=()
    [ "$failed" -eq 0 ]
}

chroot_boot_cleanup() {
    chroot_boot_restore_resolv_conf || true
    chroot_boot_unmount_pseudo_filesystems || true
}

chroot_boot_signal_handler() {
    local signal="$1"
    log_error "Instalação do boot interrompida por $signal."
    chroot_boot_cleanup
    trap - EXIT INT TERM
    [ "$signal" = "INT" ] && exit 130
    exit 143
}

chroot_boot_run() {
    local status=0

    chroot_boot_log_command chroot "$INSTALL_TARGET_ROOT" /usr/bin/env \
        HOME=/root LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
    log_run_external chroot "$INSTALL_TARGET_ROOT" /usr/bin/env \
        HOME=/root LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$@" || status=$?
    log_info "Comando no chroot finalizado com código $status: $*"
    return "$status"
}

chroot_boot_update_initramfs() {
    local status=0

    log_info "Boot: antes de executar update-initramfs -u -k all."
    chroot_boot_run update-initramfs -u -k all || status=$?
    log_info "Boot: update-initramfs -u -k all terminou completamente com código $status."
    [ "$status" -eq 0 ] || return "$status"
    [ -n "$(chroot_boot_find_kernels)" ] && [ -n "$(chroot_boot_find_initramfs)" ]
}

chroot_boot_install_grub_uefi() {
    chroot_boot_run grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=debian --no-nvram --recheck || return 1
    chroot_boot_run grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=debian --no-nvram --removable --recheck || return 1
    CHROOT_BOOT_GRUB_INSTALLED=1
}

chroot_boot_install_grub_legacy() {
    local disk_type=""

    disk_type=$(lsblk -dn -o TYPE -- "$INSTALL_DISK" 2>/dev/null | head -n1 || true)
    [ "$disk_type" = "disk" ] || return 1
    chroot_boot_run grub-install --target=i386-pc --recheck "$INSTALL_DISK" || return 1
    CHROOT_BOOT_GRUB_INSTALLED=1
}

chroot_boot_generate_config() {
    if [ -x "$INSTALL_TARGET_ROOT/usr/sbin/update-grub" ] || [ -x "$INSTALL_TARGET_ROOT/sbin/update-grub" ]; then
        chroot_boot_run update-grub
    else
        chroot_boot_run grub-mkconfig -o /boot/grub/grub.cfg
    fi
}

chroot_boot_verify_grub_config() {
    local config="$INSTALL_TARGET_ROOT/boot/grub/grub.cfg"
    local kernel=""

    [ -s "$config" ] || return 1
    while IFS= read -r kernel; do
        if grep -Fq "$(basename "$kernel")" "$config"; then
            return 0
        fi
    done < <(chroot_boot_find_kernels)
    return 1
}

chroot_boot_verify_uefi() {
    local debian_loader="$INSTALL_TARGET_ROOT/boot/efi/EFI/debian/grubx64.efi"
    local fallback_loader="$INSTALL_TARGET_ROOT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    local efi_root="$INSTALL_TARGET_ROOT/boot/efi/EFI"
    local loader=""

    if [ -d "$efi_root" ]; then
        while IFS= read -r loader; do
            log_info "Artefato EFI: $loader"
        done < <(find "$efi_root" -type f -print 2>/dev/null)
    else
        log_error "Diretório de artefatos EFI ausente: $efi_root"
    fi

    if [ ! -s "$debian_loader" ]; then
        ui_error "Carregador EFI Debian ausente ou vazio: $debian_loader"
        log_error "Artefato UEFI obrigatório ausente: EFI/debian/grubx64.efi"
        return 1
    fi
    if [ ! -s "$fallback_loader" ]; then
        ui_error "Carregador EFI de fallback ausente ou vazio: $fallback_loader"
        log_error "Artefato UEFI obrigatório ausente: EFI/BOOT/BOOTX64.EFI"
        return 1
    fi

    log_info "Carregadores UEFI Debian e fallback verificados simultaneamente."
}

chroot_boot_verify_legacy() {
    [ "$CHROOT_BOOT_GRUB_INSTALLED" -eq 1 ]
}

chroot_boot_verify() {
    [ -n "$(chroot_boot_find_kernels)" ] || return 1
    [ -n "$(chroot_boot_find_initramfs)" ] || return 1
    chroot_boot_verify_grub_config || return 1
    if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
        chroot_boot_verify_uefi
    else
        chroot_boot_verify_legacy
    fi
}

chroot_boot_log_plan() {
    chroot_boot_log_command mount --rbind /dev "$INSTALL_TARGET_ROOT/dev"
    chroot_boot_log_command mount --make-rslave "$INSTALL_TARGET_ROOT/dev"
    chroot_boot_log_command mount -t proc proc "$INSTALL_TARGET_ROOT/proc"
    chroot_boot_log_command mount --rbind /sys "$INSTALL_TARGET_ROOT/sys"
    chroot_boot_log_command mount --make-rslave "$INSTALL_TARGET_ROOT/sys"
    chroot_boot_log_command mount --rbind /run "$INSTALL_TARGET_ROOT/run"
    chroot_boot_log_command mount --make-rslave "$INSTALL_TARGET_ROOT/run"
    chroot_boot_log_command chroot "$INSTALL_TARGET_ROOT" update-initramfs -u -k all
    if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
        chroot_boot_log_command chroot "$INSTALL_TARGET_ROOT" grub-install --target=x86_64-efi \
            --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --recheck
        chroot_boot_log_command chroot "$INSTALL_TARGET_ROOT" grub-install --target=x86_64-efi \
            --efi-directory=/boot/efi --bootloader-id=debian --no-nvram --removable --recheck
    else
        chroot_boot_log_command chroot "$INSTALL_TARGET_ROOT" grub-install --target=i386-pc --recheck "$INSTALL_DISK"
    fi
    chroot_boot_log_command chroot "$INSTALL_TARGET_ROOT" update-grub
}

chroot_boot_apply() {
    local cleanup_failed=0

    INSTALL_BOOT_READY=0
    CHROOT_BOOT_GRUB_INSTALLED=0
    CHROOT_BOOT_MOUNTS_CREATED=()

    chroot_boot_validate || return 1
    if chroot_boot_is_dry_run; then
        postinstall_run || return 1
        chroot_boot_log_plan
        ui_warning "Dry-run do boot ativo: nenhuma montagem ou comando chroot foi executado."
        return 0
    fi

    trap chroot_boot_cleanup EXIT
    trap 'chroot_boot_signal_handler INT' INT
    trap 'chroot_boot_signal_handler TERM' TERM

    if ! chroot_boot_mount_pseudo_filesystems ||
       ! chroot_boot_prepare_resolv_conf ||
       ! postinstall_run ||
       ! chroot_boot_update_initramfs ||
       { [ "$INSTALL_BOOT_MODE" = "uefi" ] && ! chroot_boot_install_grub_uefi; } ||
       { [ "$INSTALL_BOOT_MODE" = "legacy" ] && ! chroot_boot_install_grub_legacy; } ||
       ! chroot_boot_generate_config ||
       ! chroot_boot_verify; then
        ui_error "Falha na preparação do chroot ou instalação do boot."
        log_error "Sprint 6.4 falhou; executando cleanup próprio."
        chroot_boot_cleanup
        trap - EXIT INT TERM
        return 1
    fi

    if ! chroot_boot_restore_resolv_conf; then
        cleanup_failed=1
    fi
    if ! chroot_boot_unmount_pseudo_filesystems; then
        cleanup_failed=1
    fi
    if [ "$cleanup_failed" -ne 0 ]; then
        ui_error "O boot foi instalado, mas o cleanup dos recursos temporários falhou."
        INSTALL_BOOT_READY=0
        trap - EXIT INT TERM
        return 1
    fi

    trap - EXIT INT TERM
    INSTALL_BOOT_READY=1
    ui_success "Boot instalado e verificado; sistema pronto para inicialização."
    log_info "Sprint 6.4 concluída com sucesso em modo $INSTALL_BOOT_MODE."
}
