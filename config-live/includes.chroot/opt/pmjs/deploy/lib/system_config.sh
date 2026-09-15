#!/bin/bash

INSTALL_SYSTEM_CONFIG_READY=0
SYSTEM_CONFIG_ROOT_UUID=""
SYSTEM_CONFIG_HOME_UUID=""
SYSTEM_CONFIG_SWAP_UUID=""
SYSTEM_CONFIG_EFI_UUID=""

system_config_is_dry_run() {
    [ "${INSTALL_EXECUTION_MODE:-dry-run}" != "real" ]
}

system_config_log_command() {
    log_info "Configuração do sistema: $*"
}

system_config_validate_hostname() {
    local hostname_value="${INSTALL_HOSTNAME:-}"

    [ ${#hostname_value} -ge 1 ] &&
        [ ${#hostname_value} -le 63 ] &&
        [[ "$hostname_value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

system_config_validate() {
    local target_root="${INSTALL_TARGET_ROOT:-}"
    local mounted_source=""

    if [ -z "$target_root" ] || [ "$target_root" = "/" ]; then
        ui_error "O destino raiz da configuração é inválido: ${target_root:-não definido}"
        log_error "Destino raiz inválido para configuração do sistema."
        return 1
    fi

    if ! system_config_validate_hostname; then
        ui_error "Hostname inválido: ${INSTALL_HOSTNAME:-não definido}"
        log_error "Hostname ausente ou inválido para configuração do sistema."
        return 1
    fi

    case "${INSTALL_BOOT_MODE:-}" in
        uefi|legacy) ;;
        *)
            ui_error "Modo de boot inválido: ${INSTALL_BOOT_MODE:-não definido}"
            log_error "Modo de boot inválido para configuração do sistema."
            return 1
            ;;
    esac

    if [ -z "${INSTALL_ROOT_PARTITION:-}" ] ||
       [ -z "${INSTALL_HOME_PARTITION:-}" ] ||
       [ -z "${INSTALL_SWAP_PARTITION:-}" ]; then
        ui_error "As partições root, home e swap devem estar definidas."
        log_error "Partições obrigatórias ausentes na configuração do sistema."
        return 1
    fi

    if [ "$INSTALL_BOOT_MODE" = "uefi" ] && [ -z "${INSTALL_EFI_PARTITION:-}" ]; then
        ui_error "A partição EFI deve estar definida no modo UEFI."
        log_error "Partição EFI ausente na configuração do sistema."
        return 1
    fi

    if system_config_is_dry_run; then
        return 0
    fi

    if [ "${INSTALL_EXTRACT_READY:-0}" -ne 1 ]; then
        ui_error "O sistema ainda não foi extraído para configuração."
        log_error "INSTALL_EXTRACT_READY não está habilitado."
        return 1
    fi

    if ! mountpoint -q "$target_root"; then
        ui_error "O destino raiz não é uma montagem exata: $target_root"
        log_error "Destino raiz não montado para configuração do sistema."
        return 1
    fi

    mounted_source=$(findmnt -rn -M "$target_root" -o SOURCE 2>/dev/null || true)
    if [ "$(mounts_resolve_path "$mounted_source" 2>/dev/null || true)" != \
         "$(mounts_resolve_path "$INSTALL_ROOT_PARTITION" 2>/dev/null || true)" ]; then
        ui_error "A origem de $target_root não é $INSTALL_ROOT_PARTITION."
        log_error "Origem inesperada na montagem raiz: ${mounted_source:-não identificada}"
        return 1
    fi

    if [ ! -d "$target_root/etc" ]; then
        ui_error "O diretório $target_root/etc não existe."
        log_error "Diretório etc ausente no sistema extraído."
        return 1
    fi

    return 0
}

system_config_read_uuid() {
    local partition="$1"
    local label="$2"
    local uuid=""

    uuid=$(blkid -s UUID -o value "$partition" 2>/dev/null || true)
    if [ -z "$uuid" ]; then
        ui_error "Não foi possível obter o UUID da partição $label: $partition"
        log_error "UUID ausente para $label em $partition."
        return 1
    fi

    printf '%s\n' "$uuid"
}

system_config_read_uuids() {
    SYSTEM_CONFIG_ROOT_UUID=$(system_config_read_uuid "$INSTALL_ROOT_PARTITION" "root") || return 1
    SYSTEM_CONFIG_HOME_UUID=$(system_config_read_uuid "$INSTALL_HOME_PARTITION" "home") || return 1
    SYSTEM_CONFIG_SWAP_UUID=$(system_config_read_uuid "$INSTALL_SWAP_PARTITION" "swap") || return 1

    SYSTEM_CONFIG_EFI_UUID=""
    if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
        SYSTEM_CONFIG_EFI_UUID=$(system_config_read_uuid "$INSTALL_EFI_PARTITION" "EFI") || return 1
    fi
}

system_config_atomic_write() {
    local destination="$1"
    local mode="$2"
    local content="$3"
    local directory=""
    local temporary=""

    directory=$(dirname "$destination")
    [ -d "$directory" ] || return 1
    temporary=$(mktemp "$directory/.pmjs-config.XXXXXX") || return 1

    if ! printf '%s' "$content" > "$temporary" ||
       ! chmod "$mode" "$temporary" ||
       ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
}

system_config_generate_fstab() {
    local destination="$INSTALL_TARGET_ROOT/etc/fstab"
    local content=""

    content="UUID=$SYSTEM_CONFIG_ROOT_UUID  /          btrfs  defaults,noatime  0  0
UUID=$SYSTEM_CONFIG_HOME_UUID  /home      btrfs  defaults,noatime  0  0
UUID=$SYSTEM_CONFIG_SWAP_UUID  none       swap   sw               0  0
"
    if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
        content+="UUID=$SYSTEM_CONFIG_EFI_UUID  /boot/efi  vfat   defaults,umask=0077  0  2
"
    fi
    content+="/dev/sr0  /media/cdrom0  udf,iso9660  user,noauto  0  0
"

    system_config_log_command "gerar atomicamente $destination (sem subvol=@rootfs)"
    system_config_atomic_write "$destination" 0644 "$content"
}

system_config_set_hostname() {
    local destination="$INSTALL_TARGET_ROOT/etc/hostname"

    system_config_log_command "definir hostname em $destination como $INSTALL_HOSTNAME"
    system_config_atomic_write "$destination" 0644 "$INSTALL_HOSTNAME"$'\n'
}

system_config_update_hosts() {
    local destination="$INSTALL_TARGET_ROOT/etc/hosts"
    local content=""

    content="127.0.0.1 localhost
127.0.1.1 $INSTALL_HOSTNAME

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
"
    system_config_log_command "gerar hosts sem entradas duplicadas em $destination"
    system_config_atomic_write "$destination" 0644 "$content"
}

system_config_set_resume() {
    local resume_dir="$INSTALL_TARGET_ROOT/etc/initramfs-tools/conf.d"
    local destination="$resume_dir/resume"

    system_config_log_command "definir resume da swap em $destination"
    if [ -L "$INSTALL_TARGET_ROOT/etc/initramfs-tools" ] || [ -L "$resume_dir" ]; then
        ui_error "O caminho da configuração de resume contém link simbólico inseguro."
        log_error "Link simbólico rejeitado em etc/initramfs-tools/conf.d."
        return 1
    fi
    mkdir -p "$resume_dir" || return 1
    system_config_atomic_write "$destination" 0644 \
        "RESUME=UUID=$SYSTEM_CONFIG_SWAP_UUID"$'\n'
}

system_config_reset_machine_id() {
    local machine_id="$INSTALL_TARGET_ROOT/etc/machine-id"
    local dbus_machine_id="$INSTALL_TARGET_ROOT/var/lib/dbus/machine-id"

    system_config_log_command "truncar $machine_id e remover $dbus_machine_id"
    if [ -L "$INSTALL_TARGET_ROOT/var/lib" ] || [ -L "$INSTALL_TARGET_ROOT/var/lib/dbus" ]; then
        ui_error "O caminho de machine-id do D-Bus contém link simbólico inseguro."
        log_error "Link simbólico rejeitado no diretório var/lib/dbus."
        return 1
    fi

    mkdir -p "$INSTALL_TARGET_ROOT/var/lib/dbus" || return 1
    system_config_atomic_write "$machine_id" 0444 "" || return 1
    rm -f "$dbus_machine_id"
}

system_config_verify() {
    local fstab="$INSTALL_TARGET_ROOT/etc/fstab"

    grep -Fq "UUID=$SYSTEM_CONFIG_ROOT_UUID" "$fstab" || return 1
    grep -Fq "UUID=$SYSTEM_CONFIG_HOME_UUID" "$fstab" || return 1
    grep -Fq "UUID=$SYSTEM_CONFIG_SWAP_UUID" "$fstab" || return 1
    if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
        grep -Fq "UUID=$SYSTEM_CONFIG_EFI_UUID" "$fstab" || return 1
    fi
    [ "$(cat "$INSTALL_TARGET_ROOT/etc/hostname")" = "$INSTALL_HOSTNAME" ] || return 1
    grep -Fxq "127.0.1.1 $INSTALL_HOSTNAME" "$INSTALL_TARGET_ROOT/etc/hosts" || return 1
    grep -Fxq "RESUME=UUID=$SYSTEM_CONFIG_SWAP_UUID" \
        "$INSTALL_TARGET_ROOT/etc/initramfs-tools/conf.d/resume" || return 1
    [ -f "$INSTALL_TARGET_ROOT/etc/machine-id" ] || return 1
    [ ! -s "$INSTALL_TARGET_ROOT/etc/machine-id" ] || return 1
    [ ! -e "$INSTALL_TARGET_ROOT/var/lib/dbus/machine-id" ] || return 1
}

system_config_restore_backup() {
    local backup_dir="$1"
    local relative=""

    for relative in etc/fstab etc/hostname etc/hosts etc/initramfs-tools/conf.d/resume etc/machine-id var/lib/dbus/machine-id; do
        if [ -e "$backup_dir/$relative" ] || [ -L "$backup_dir/$relative" ]; then
            mkdir -p "$(dirname "$INSTALL_TARGET_ROOT/$relative")"
            cp -a "$backup_dir/$relative" "$INSTALL_TARGET_ROOT/$relative"
        else
            rm -f "$INSTALL_TARGET_ROOT/$relative"
        fi
    done
}

system_config_apply() {
    local backup_dir=""
    local relative=""

    INSTALL_SYSTEM_CONFIG_READY=0
    system_config_validate || return 1

    if system_config_is_dry_run; then
        system_config_log_command "ler UUIDs de root, home, swap${INSTALL_BOOT_MODE:+ e EFI quando aplicável}"
        system_config_log_command "alterar $INSTALL_TARGET_ROOT/etc/fstab"
        system_config_log_command "alterar $INSTALL_TARGET_ROOT/etc/hostname"
        system_config_log_command "alterar $INSTALL_TARGET_ROOT/etc/hosts"
        system_config_log_command "alterar $INSTALL_TARGET_ROOT/etc/initramfs-tools/conf.d/resume"
        system_config_log_command "zerar $INSTALL_TARGET_ROOT/etc/machine-id"
        system_config_log_command "remover $INSTALL_TARGET_ROOT/var/lib/dbus/machine-id se existir"
        ui_warning "Dry-run da configuração do sistema: nenhuma alteração foi executada."
        return 0
    fi

    system_config_read_uuids || return 1
    backup_dir=$(mktemp -d "$INSTALL_TARGET_ROOT/.pmjs-system-config.XXXXXX") || return 1

    for relative in etc/fstab etc/hostname etc/hosts etc/initramfs-tools/conf.d/resume etc/machine-id var/lib/dbus/machine-id; do
        if [ -e "$INSTALL_TARGET_ROOT/$relative" ] || [ -L "$INSTALL_TARGET_ROOT/$relative" ]; then
            if ! mkdir -p "$backup_dir/$(dirname "$relative")" ||
               ! cp -a "$INSTALL_TARGET_ROOT/$relative" "$backup_dir/$relative"; then
                rm -rf "$backup_dir"
                return 1
            fi
        fi
    done

    if ! system_config_generate_fstab ||
       ! system_config_set_hostname ||
       ! system_config_update_hosts ||
       ! system_config_set_resume ||
       ! system_config_reset_machine_id ||
       ! system_config_verify; then
        ui_error "Falha ao configurar ou verificar o sistema extraído; restaurando arquivos."
        log_error "Configuração inicial falhou; iniciando restauração."
        system_config_restore_backup "$backup_dir" || true
        rm -rf "$backup_dir"
        return 1
    fi

    rm -rf "$backup_dir"
    INSTALL_SYSTEM_CONFIG_READY=1
    ui_success "Configuração inicial do sistema concluída em $INSTALL_TARGET_ROOT"
    log_info "fstab, hostname, hosts, resume e machine-id configurados com sucesso."
}
