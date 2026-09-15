#!/bin/bash

PRESERVE_HOME_PREFLIGHT_READY=0
PRESERVE_HOME_SNAPSHOT_DISK=""
PRESERVE_HOME_SNAPSHOT_EFI=""
PRESERVE_HOME_SNAPSHOT_SWAP=""
PRESERVE_HOME_SNAPSHOT_ROOT=""
PRESERVE_HOME_SNAPSHOT_HOME=""
PRESERVE_HOME_SNAPSHOT_UUID=""
PRESERVE_HOME_SNAPSHOT_FSTYPE=""
PRESERVE_HOME_SNAPSHOT_USER_UID=""
PRESERVE_HOME_SNAPSHOT_USER_GID=""
PRESERVE_HOME_SNAPSHOT_USER_MODE=""
PRESERVE_HOME_MIN_FREE_BYTES="${PRESERVE_HOME_MIN_FREE_BYTES:-16777216}"
PRESERVE_HOME_PROBE_DIR=""

storage_preserve_home_reset_snapshot() {
    PRESERVE_HOME_PREFLIGHT_READY=0
    PRESERVE_HOME_SNAPSHOT_DISK=""
    PRESERVE_HOME_SNAPSHOT_EFI=""
    PRESERVE_HOME_SNAPSHOT_SWAP=""
    PRESERVE_HOME_SNAPSHOT_ROOT=""
    PRESERVE_HOME_SNAPSHOT_HOME=""
    PRESERVE_HOME_SNAPSHOT_UUID=""
    PRESERVE_HOME_SNAPSHOT_FSTYPE=""
    PRESERVE_HOME_SNAPSHOT_USER_UID=""
    PRESERVE_HOME_SNAPSHOT_USER_GID=""
    PRESERVE_HOME_SNAPSHOT_USER_MODE=""
}

storage_partition_parent_matches_disk() {
    local partition="$1"
    local disk="$2"
    local parent=""

    parent=$(lsblk -no PKNAME -- "$partition" 2>/dev/null | xargs || true)
    [ -n "$parent" ] && [ "$(basename "$parent")" = "$(basename "$disk")" ]
}

storage_preserve_home_preflight_cleanup() {
    local probe="${PRESERVE_HOME_PROBE_DIR:-}"
    local status=0

    [ -n "$probe" ] || return 0
    if mountpoint -q "$probe" 2>/dev/null; then
        log_run_external umount "$probe" || status=$?
    fi
    rmdir "$probe" 2>/dev/null || true
    PRESERVE_HOME_PROBE_DIR=""
    return "$status"
}

storage_preserve_home_preflight() {
    local probe=""
    local home_uuid=""
    local home_fstype=""
    local mounted_target=""
    local mounted_source=""
    local mount_options=""
    local available_bytes=""
    local target_user="${TARGET_USER:-usuario}"
    local user_dir=""
    local user_uid=""
    local user_gid=""
    local user_mode=""
    local content_entry=""
    local status=0
    local witness="${PRESERVE_HOME_TEST_WITNESS:-}"

    [ "${INSTALL_STORAGE_MODE:-}" = "preserve_home" ] || return 0
    storage_preserve_home_reset_snapshot
    log_info "Preserve_home preflight: iniciando validação antes do ponto destrutivo."

    if ! storage_detect_eduinstall_layout "$INSTALL_DISK"; then
        ui_error "O layout do disco mudou antes da validação da home."
        log_error "Preserve_home pré-destrutivo: layout EduInstall não foi reconfirmado."
        return 1
    fi
    if ! storage_partition_parent_matches_disk "$INSTALL_HOME_PARTITION" "$INSTALL_DISK"; then
        ui_error "A partição home não pertence mais ao disco selecionado."
        log_error "Preserve_home pré-destrutivo: parent disk inválido para $INSTALL_HOME_PARTITION."
        return 1
    fi

    home_uuid=$(blkid -s UUID -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
    home_fstype=$(blkid -s TYPE -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
    if [ -z "$home_uuid" ] || [ "$home_fstype" != "btrfs" ]; then
        ui_error "A home não possui UUID válido ou não usa Btrfs."
        log_error "Preserve_home pré-destrutivo: UUID='${home_uuid:-vazio}', filesystem='${home_fstype:-vazio}'."
        return 1
    fi

    mounted_target=$(findmnt -rn -S "$INSTALL_HOME_PARTITION" -o TARGET 2>/dev/null | head -n1 || true)
    if [ -n "$mounted_target" ]; then
        ui_error "A partição home já está montada em $mounted_target."
        log_error "Preserve_home pré-destrutivo: montagem preexistente inesperada da home."
        return 1
    fi

    probe=$(mktemp -d /tmp/pmjs-home-preflight.XXXXXX) || return 1
    PRESERVE_HOME_PROBE_DIR="$probe"
    if ! log_run_external mount -o ro,nosuid,nodev,noexec \
        "$INSTALL_HOME_PARTITION" "$probe"; then
        ui_error "A partição home não pôde ser montada somente para leitura."
        log_error "Preserve_home pré-destrutivo: teste de montagem read-only falhou."
        status=1
    else
        mounted_source=$(findmnt -rn -M "$probe" -o SOURCE 2>/dev/null || true)
        mount_options=$(findmnt -rn -M "$probe" -o OPTIONS 2>/dev/null || true)
        if [ "$(readlink -f "$mounted_source" 2>/dev/null || true)" != \
             "$(readlink -f "$INSTALL_HOME_PARTITION" 2>/dev/null || true)" ] ||
           [[ ",$mount_options," != *,ro,* ]]; then
            ui_error "A montagem de teste da home não corresponde ao dispositivo ou não está read-only."
            log_error "Preserve_home pré-destrutivo: source='$mounted_source', opções='$mount_options'."
            status=1
        fi

        available_bytes=$(df -B1 --output=avail "$probe" 2>/dev/null |
            awk 'NR == 2 {gsub(/[[:space:]]/, "", $1); print $1}' || true)
        if ! [[ "$available_bytes" =~ ^[0-9]+$ ]] ||
           [ "$available_bytes" -lt "$PRESERVE_HOME_MIN_FREE_BYTES" ]; then
            ui_error "A home não possui o espaço livre mínimo para uma reinstalação segura."
            log_error "Preserve_home pré-destrutivo: livres=${available_bytes:-desconhecido}, mínimo=$PRESERVE_HOME_MIN_FREE_BYTES."
            status=1
        fi

        content_entry=$(find "$probe" -mindepth 1 -maxdepth 1 \
            ! -name lost+found -print -quit 2>/dev/null || true)
        if [ -z "$content_entry" ]; then
            ui_error "A partição home está vazia ou seu conteúdo não está acessível."
            log_error "Preserve_home pré-destrutivo: nenhum conteúdo útil encontrado."
            status=1
        fi

        user_dir="$probe/$target_user"
        if [ ! -d "$user_dir" ] || [ ! -r "$user_dir" ] || [ ! -x "$user_dir" ]; then
            ui_error "O diretório do usuário $target_user não está acessível na home."
            log_error "Preserve_home pré-destrutivo: diretório $target_user ausente ou inacessível."
            status=1
        else
            user_uid=$(stat -c %u "$user_dir" 2>/dev/null || true)
            user_gid=$(stat -c %g "$user_dir" 2>/dev/null || true)
            user_mode=$(stat -c %a "$user_dir" 2>/dev/null || true)
        fi

        if [ -n "$witness" ]; then
            case "$witness" in
                /*|*..*)
                    log_error "Preserve_home teste: caminho de testemunha inseguro: $witness."
                    status=1
                    ;;
                *)
                    if [ ! -e "$probe/$witness" ]; then
                        log_error "Preserve_home teste: arquivo-testemunha não encontrado: $witness."
                        status=1
                    fi
                    ;;
            esac
        fi
    fi

    if ! storage_preserve_home_preflight_cleanup; then
        ui_error "Falha ao desmontar a home após o teste somente leitura."
        log_error "Preserve_home pré-destrutivo: cleanup da montagem de teste falhou."
        status=1
    fi
    [ "$status" -eq 0 ] || return 1

    PRESERVE_HOME_SNAPSHOT_DISK="$INSTALL_DISK"
    PRESERVE_HOME_SNAPSHOT_EFI="$INSTALL_EFI_PARTITION"
    PRESERVE_HOME_SNAPSHOT_SWAP="$INSTALL_SWAP_PARTITION"
    PRESERVE_HOME_SNAPSHOT_ROOT="$INSTALL_ROOT_PARTITION"
    PRESERVE_HOME_SNAPSHOT_HOME="$INSTALL_HOME_PARTITION"
    PRESERVE_HOME_SNAPSHOT_UUID="$home_uuid"
    PRESERVE_HOME_SNAPSHOT_FSTYPE="$home_fstype"
    PRESERVE_HOME_SNAPSHOT_USER_UID="$user_uid"
    PRESERVE_HOME_SNAPSHOT_USER_GID="$user_gid"
    PRESERVE_HOME_SNAPSHOT_USER_MODE="$user_mode"
    PRESERVE_HOME_PREFLIGHT_READY=1
    log_info "Preserve_home preflight concluído: home=$INSTALL_HOME_PARTITION UUID=$home_uuid filesystem=$home_fstype livres=${available_bytes}B."
}

storage_preserve_home_validate_snapshot() {
    local expected_disk="$PRESERVE_HOME_SNAPSHOT_DISK"
    local expected_efi="$PRESERVE_HOME_SNAPSHOT_EFI"
    local expected_swap="$PRESERVE_HOME_SNAPSHOT_SWAP"
    local expected_root="$PRESERVE_HOME_SNAPSHOT_ROOT"
    local expected_home="$PRESERVE_HOME_SNAPSHOT_HOME"
    local current_uuid=""
    local current_fstype=""

    [ "${INSTALL_STORAGE_MODE:-}" = "preserve_home" ] || return 0
    if [ "$PRESERVE_HOME_PREFLIGHT_READY" -ne 1 ]; then
        ui_error "O preflight da home não foi concluído; formatação bloqueada."
        log_error "Preserve_home pré-destrutivo: snapshot ausente."
        return 1
    fi
    if ! storage_detect_eduinstall_layout "$expected_disk"; then
        ui_error "O layout mudou após o preflight; formatação bloqueada."
        log_error "Preserve_home pré-destrutivo: layout não reconfirmado imediatamente antes do mkfs."
        return 1
    fi
    if [ "$INSTALL_DISK" != "$expected_disk" ] ||
       [ "$INSTALL_EFI_PARTITION" != "$expected_efi" ] ||
       [ "$INSTALL_SWAP_PARTITION" != "$expected_swap" ] ||
       [ "$INSTALL_ROOT_PARTITION" != "$expected_root" ] ||
       [ "$INSTALL_HOME_PARTITION" != "$expected_home" ]; then
        ui_error "O mapeamento das partições mudou após o preflight; formatação bloqueada."
        log_error "Preserve_home pré-destrutivo: snapshot divergiu (EFI=$INSTALL_EFI_PARTITION swap=$INSTALL_SWAP_PARTITION root=$INSTALL_ROOT_PARTITION home=$INSTALL_HOME_PARTITION)."
        return 1
    fi
    current_uuid=$(blkid -s UUID -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
    current_fstype=$(blkid -s TYPE -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
    if [ "$current_uuid" != "$PRESERVE_HOME_SNAPSHOT_UUID" ] ||
       [ "$current_fstype" != "$PRESERVE_HOME_SNAPSHOT_FSTYPE" ]; then
        ui_error "UUID ou filesystem da home mudou após o preflight; formatação bloqueada."
        log_error "Preserve_home pré-destrutivo: esperado UUID=$PRESERVE_HOME_SNAPSHOT_UUID/$PRESERVE_HOME_SNAPSHOT_FSTYPE, atual=$current_uuid/$current_fstype."
        return 1
    fi
    log_info "Preserve_home: snapshot reconfirmado imediatamente antes da formatação da root."
}

storage_preserve_home_post_validate() {
    local target_home="${INSTALL_TARGET_HOME:-${INSTALL_TARGET_ROOT:-}/home}"
    local target_user="${TARGET_USER:-usuario}"
    local current_uuid=""
    local current_fstype=""
    local mounted_source=""
    local mount_options=""
    local user_dir="$target_home/$target_user"
    local fstab="${INSTALL_TARGET_ROOT:-}/etc/fstab"

    [ "${INSTALL_STORAGE_MODE:-}" = "preserve_home" ] || return 0
    if [ "${INSTALL_EXECUTION_MODE:-dry-run}" != "real" ]; then
        log_info "Preserve_home dry-run: validação pós-instalação registrada sem exigir montagens reais."
        return 0
    fi
    current_uuid=$(blkid -s UUID -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
    current_fstype=$(blkid -s TYPE -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
    mounted_source=$(findmnt -rn -M "$target_home" -o SOURCE 2>/dev/null || true)
    mount_options=$(findmnt -rn -M "$target_home" -o OPTIONS 2>/dev/null || true)

    if [ "$current_uuid" != "$PRESERVE_HOME_SNAPSHOT_UUID" ] ||
       [ "$current_fstype" != "$PRESERVE_HOME_SNAPSHOT_FSTYPE" ] ||
       [ "$(readlink -f "$mounted_source" 2>/dev/null || true)" != \
         "$(readlink -f "$INSTALL_HOME_PARTITION" 2>/dev/null || true)" ] ||
       [[ ",$mount_options," != *,rw,* ]]; then
        ui_error "A validação final da partição home falhou."
        log_error "Preserve_home pós-destrutivo: UUID=$current_uuid fs=$current_fstype source=$mounted_source opções=$mount_options."
        return 1
    fi
    if [ ! -d "$user_dir" ] ||
       [ "$(stat -c %u "$user_dir" 2>/dev/null || true)" != "$PRESERVE_HOME_SNAPSHOT_USER_UID" ] ||
       [ "$(stat -c %g "$user_dir" 2>/dev/null || true)" != "$PRESERVE_HOME_SNAPSHOT_USER_GID" ] ||
       [ "$(stat -c %a "$user_dir" 2>/dev/null || true)" != "$PRESERVE_HOME_SNAPSHOT_USER_MODE" ]; then
        ui_error "Proprietário ou permissões da home do usuário mudaram."
        log_error "Preserve_home pós-destrutivo: metadados de $user_dir divergiram do snapshot."
        return 1
    fi
    if [ -z "$(find "$target_home" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit 2>/dev/null)" ]; then
        ui_error "O conteúdo preservado da home não está acessível após a instalação."
        log_error "Preserve_home pós-destrutivo: conteúdo da home ausente."
        return 1
    fi
    if ! awk -v expected="UUID=$PRESERVE_HOME_SNAPSHOT_UUID" '
        $1 == expected && $2 == "/home" && $3 == "btrfs" { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$fstab"; then
        ui_error "O fstab não aponta /home para o UUID preservado."
        log_error "Preserve_home pós-destrutivo: linha correta da home ausente em $fstab."
        return 1
    fi
    if [ -n "${PRESERVE_HOME_TEST_WITNESS:-}" ] &&
       [ ! -e "$target_home/$PRESERVE_HOME_TEST_WITNESS" ]; then
        log_error "Preserve_home teste: testemunha não sobreviveu ao fluxo: $PRESERVE_HOME_TEST_WITNESS."
        return 1
    fi
    log_info "Preserve_home pós-instalação validado: UUID, filesystem, montagem rw, conteúdo, usuário e fstab preservados."
}

install_show_storage_plan() {
    local storage_mode_label="Instalação limpa"
    local home_uuid=""

    ui_clear
    ui_title "$VERSION"
    echo "PLANO DE ARMAZENAMENTO"
    echo
    echo "Disco............... ${INSTALL_DISK:-não definido}"

    if [ "$INSTALL_STORAGE_MODE" = "preserve_home" ]; then
        home_uuid=$(blkid -s UUID -o value "$INSTALL_HOME_PARTITION" 2>/dev/null || true)
        storage_mode_label="Reinstalar e preservar /home"
        echo "Layout.............. EduInstall reconhecido"
        echo "Modo................ $storage_mode_label"
        echo "Tabela de partições. Preservar"
        echo
        if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
            printf '%-22s %-10s %s\n' "$INSTALL_EFI_PARTITION" "EFI" "REUTILIZAR"
        fi
        printf '%-22s %-10s %s\n' "$INSTALL_SWAP_PARTITION" "swap" "REUTILIZAR"
        printf '%-22s %-10s %s\n' "$INSTALL_ROOT_PARTITION" "/" "SERÁ FORMATADA"
        printf '%-22s %-10s %s\n' "$INSTALL_HOME_PARTITION" "/home" "PRESERVAR"
        echo "UUID da home........ ${home_uuid:-não identificado}"
    else
        echo "Modo................ $storage_mode_label"
        echo "Tabela de partições. RECRIAR"
        echo "Disco inteiro....... REPARTICIONAR"
    fi

    echo
    echo "AVISO: haverá uma única confirmação antes de qualquer alteração destrutiva."
    ui_pause
}

install_select_storage_mode() {
    local choice

    echo
    echo "Modo de armazenamento"
    echo

    if [ "$EDUINSTALL_LAYOUT_DETECTED" -eq 1 ]; then
        echo "1) Instalação limpa — apagar todo o disco"
        echo "2) Reinstalar sistema — preservar /home"
    else
        echo "1) Instalação limpa — apagar todo o disco"
        echo
        echo "A opção de preservar /home não está disponível porque o disco"
        echo "não possui um layout EduInstall reconhecido."
    fi

    echo
    read -rp "Escolha [1]: " choice
    choice=${choice:-1}

    case "$choice" in
        1)
            INSTALL_STORAGE_MODE="clean"
            INSTALL_REPARTITION_DISK=1
            INSTALL_FORMAT_ROOT=1
            INSTALL_FORMAT_HOME=1
            ;;
        2)
            if [ "$EDUINSTALL_LAYOUT_DETECTED" -ne 1 ]; then
                ui_error "Não é possível usar preserve_home sem um layout EduInstall reconhecido."
                return 1
            fi
            INSTALL_STORAGE_MODE="preserve_home"
            INSTALL_REPARTITION_DISK=0
            INSTALL_FORMAT_ROOT=1
            INSTALL_FORMAT_HOME=0
            ;;
        *)
            ui_error "Opção inválida."
            return 1
            ;;
    esac

    return 0
}
