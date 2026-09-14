#!/bin/bash

INSTALL_WIFI_FIRMWARE="${INSTALL_WIFI_FIRMWARE:-0}"

POSTINSTALL_WIFI_PACKAGES=(
    firmware-iwlwifi
    firmware-realtek
    firmware-atheros
    firmware-brcm80211
    firmware-mediatek
)

postinstall_is_dry_run() {
    [ "${INSTALL_EXECUTION_MODE:-dry-run}" != "real" ]
}

postinstall_validate_target() {
    local target_root="${INSTALL_TARGET_ROOT:-}"

    if [ -z "$target_root" ] || [ "$target_root" = "/" ]; then
        ui_error "O target da pós-instalação é inválido: ${target_root:-não definido}"
        log_error "Pós-instalação bloqueada por INSTALL_TARGET_ROOT inválido."
        return 1
    fi
}

postinstall_path_is_within() {
    local path="$1"
    local boundary="$2"
    local resolved_path=""
    local resolved_boundary=""

    resolved_path=$(readlink -f "$path" 2>/dev/null) || return 1
    resolved_boundary=$(readlink -f "$boundary" 2>/dev/null) || return 1
    [ "$resolved_path" = "$resolved_boundary" ] ||
        [[ "$resolved_path" == "$resolved_boundary"/* ]]
}

postinstall_configure_ocs_tag() {
    local target_root="${INSTALL_TARGET_ROOT:-}"
    local tag="${INSTALL_OCS_TAG:-}"
    local config_relative="${OCS_CONFIG:-/etc/ocsinventory/ocsinventory-agent.cfg}"
    local config=""
    local temporary=""
    local line=""
    local replaced=0

    if [ -z "${tag//[[:space:]]/}" ] || [[ "$tag" == *$'\n'* ]] || [[ "$tag" == *$'\r'* ]]; then
        ui_error "A TAG do OCS está vazia ou contém quebra de linha."
        log_error "TAG OCS inválida durante a pós-instalação."
        return 1
    fi
    if [[ "$config_relative" != /* ]] || [[ "$config_relative" == *"/../"* ]] ||
       [[ "$config_relative" == "/.." ]] || [[ "$config_relative" == *"/.." ]]; then
        ui_error "O caminho configurado para o OCS é inválido: $config_relative"
        log_error "OCS_CONFIG rejeitado na pós-instalação: $config_relative"
        return 1
    fi

    config="$target_root$config_relative"
    if [ ! -e "$config" ]; then
        ui_warning "Configuração do OCS não encontrada; TAG não aplicada: $config_relative"
        log_warning "Pós-instalação ignorou TAG OCS porque o arquivo não existe no target: $config"
        return 0
    fi
    if [ ! -f "$config" ] || [ -L "$config" ] || [ ! -r "$config" ] || [ ! -w "$config" ]; then
        ui_error "A configuração do OCS não é um arquivo regular gravável: $config_relative"
        log_error "Arquivo OCS inseguro ou sem acesso no target: $config"
        return 1
    fi
    if ! postinstall_path_is_within "$config" "$target_root"; then
        ui_error "A configuração do OCS aponta para fora do target."
        log_error "Caminho OCS escapou de INSTALL_TARGET_ROOT: $config"
        return 1
    fi

    temporary=$(mktemp "$(dirname "$config")/.pmjs-ocs.XXXXXX") || {
        log_error "Não foi possível criar arquivo temporário para a TAG OCS."
        return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*tag[[:space:]]*= ]]; then
            if [ "$replaced" -eq 0 ]; then
                printf 'tag=%s\n' "$tag" >> "$temporary" || {
                    rm -f "$temporary"
                    return 1
                }
                replaced=1
            fi
        else
            printf '%s\n' "$line" >> "$temporary" || {
                rm -f "$temporary"
                return 1
            }
        fi
    done < "$config"

    if [ "$replaced" -eq 0 ]; then
        printf 'tag=%s\n' "$tag" >> "$temporary" || {
            rm -f "$temporary"
            return 1
        }
        log_info "Linha ativa tag= não existia; nova TAG adicionada ao arquivo OCS."
    else
        log_info "Linha ativa da TAG OCS substituída no sistema instalado."
    fi

    if ! chmod --reference="$config" "$temporary" ||
       ! chown --reference="$config" "$temporary" ||
       ! mv -f "$temporary" "$config"; then
        rm -f "$temporary"
        ui_error "Falha ao gravar a TAG no arquivo do OCS."
        log_error "Falha na substituição atômica de $config"
        return 1
    fi
    if ! awk -v expected="$tag" '
        /^[[:space:]]*tag[[:space:]]*=/ {
            value=$0
            sub(/^[[:space:]]*tag[[:space:]]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            if (value == expected) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$config"; then
        ui_error "A validação da TAG OCS gravada falhou."
        log_error "TAG OCS esperada não foi confirmada em $config"
        return 1
    fi

    ui_success "TAG do OCS Inventory configurada: $tag"
    log_info "TAG OCS validada com sucesso em $config_relative: $tag"
}

postinstall_target_user_home() {
    local target_root="${INSTALL_TARGET_ROOT:-}"
    local target_user="${TARGET_USER:-}"
    local passwd_file="$target_root/etc/passwd"
    local home=""

    [ -n "$target_user" ] || return 1
    if [ -r "$passwd_file" ]; then
        home=$(awk -F: -v user="$target_user" '$1 == user {print $6; exit}' "$passwd_file")
    fi
    if [ -z "$home" ]; then
        home="/home/$target_user"
    fi
    [[ "$home" == /* ]] || return 1
    case "$home" in
        /|/..|*/../*|*/..)
            return 1
            ;;
    esac
    printf '%s\n' "$home"
}

postinstall_configure_classroom_projection() {
    local target_root="${INSTALL_TARGET_ROOT:-}"
    local target_user="${TARGET_USER:-}"
    local passwd_file="$target_root/etc/passwd"
    local source_script="${PROJECT_ROOT:-}/assets/auto-mirror-x11"
    local user_home=""
    local user_record=""
    local target_home=""
    local config_dir=""
    local autostart_dir=""
    local state_dir=""
    local log_dir=""
    local log_file=""
    local shared_dir="$target_root/usr/local/lib/pmjs-deploy"
    local shared_script="$shared_dir/auto-mirror-x11"
    local desktop_file=""
    local temporary=""
    local user_uid=""
    local user_gid=""
    local actual_uid=""
    local actual_gid=""
    local actual_mode=""
    local content='[Desktop Entry]
Type=Application
Name=Espelhamento Automático de Sala de Aula
Comment=Detecta e espelha automaticamente duas telas conectadas em uma sessão X11
TryExec=/usr/local/lib/pmjs-deploy/auto-mirror-x11
Exec=/usr/local/lib/pmjs-deploy/auto-mirror-x11
Terminal=false
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
'

    if [ "${INSTALL_CLASSROOM:-0}" -eq 0 ]; then
        log_info "Configuração de projeção ignorada: máquina não destinada à Sala de Aula."
        return 0
    fi

    if [ ! -f "$source_script" ] || [ ! -r "$source_script" ]; then
        ui_error "O recurso do espelhamento automático não está disponível."
        log_error "Script fonte da projeção ausente ou ilegível: $source_script"
        return 1
    fi
    if [ ! -r "$passwd_file" ]; then
        ui_error "Não foi possível validar o usuário da configuração de Sala de Aula."
        log_error "Arquivo passwd ausente ou ilegível no target: $passwd_file"
        return 1
    fi

    if [ -n "$target_user" ]; then
        user_record=$(awk -F: -v user="$target_user" '$1 == user {print; exit}' "$passwd_file")
    fi
    if [ -z "$user_record" ]; then
        user_record=$(awk -F: '$3 == 1000 {print; count++} END {if (count != 1) exit 1}' \
            "$passwd_file") || {
            ui_error "O usuário configurado não existe e o fallback UID 1000 não é único."
            log_error "Não foi possível resolver TARGET_USER='${target_user:-não definido}' nem um único usuário UID 1000."
            return 1
        }
        target_user=${user_record%%:*}
        log_warning "TARGET_USER não foi localizado; fallback UID 1000 validado para o usuário $target_user."
    fi
    user_uid=$(printf '%s\n' "$user_record" | awk -F: '{print $3}')
    user_gid=$(printf '%s\n' "$user_record" | awk -F: '{print $4}')
    user_home=$(printf '%s\n' "$user_record" | awk -F: '{print $6}')
    if ! [[ "$user_uid" =~ ^[0-9]+$ ]] ||
       ! [[ "$user_gid" =~ ^[0-9]+$ ]] ||
       ! [[ "$user_home" == /* ]]; then
        ui_error "Os dados da conta de Sala de Aula são inválidos."
        log_error "Conta inválida para projeção: usuário=$target_user uid=$user_uid gid=$user_gid home=$user_home."
        return 1
    fi
    case "$user_home" in
        /|/..|*/../*|*/..)
            ui_error "A home da conta de Sala de Aula é insegura."
            log_error "Home rejeitada para projeção: $user_home"
            return 1
            ;;
    esac

    target_home="$target_root$user_home"
    config_dir="$target_home/.config"
    autostart_dir="$config_dir/autostart"
    state_dir="$target_home/.local/state"
    log_dir="$state_dir/pmjs-deploy"
    log_file="$log_dir/projecao.log"
    desktop_file="$autostart_dir/projecao.desktop"

    if [ ! -d "$target_home" ] || [ -L "$target_home" ] ||
       ! postinstall_path_is_within "$target_home" "$target_root"; then
        ui_error "A home do usuário para projeção é inválida ou está fora do target."
        log_error "Home insegura para projeção: $target_home"
        return 1
    fi

    for directory in "$config_dir" "$autostart_dir" "$target_home/.local" \
        "$state_dir" "$log_dir"; do
        if { [ -e "$directory" ] || [ -L "$directory" ]; } &&
           { [ ! -d "$directory" ] || [ -L "$directory" ]; }; then
            ui_error "Um diretório da projeção é inseguro: ${directory#"$target_root"}"
            log_error "Diretório rejeitado para projeção: $directory"
            return 1
        fi
    done
    if ! mkdir -p -- "$autostart_dir" "$log_dir" "$shared_dir" ||
       ! postinstall_path_is_within "$autostart_dir" "$target_home" ||
       ! postinstall_path_is_within "$log_dir" "$target_home" ||
       ! postinstall_path_is_within "$shared_dir" "$target_root"; then
        ui_error "Falha ao criar ou confinar os diretórios da projeção."
        log_error "Diretórios da projeção não puderam ser preparados com segurança."
        return 1
    fi
    if ! chmod 0755 "$config_dir" "$autostart_dir" "$target_home/.local" \
        "$state_dir" "$log_dir" "$shared_dir" ||
       ! chown "$user_uid:$user_gid" "$config_dir" "$autostart_dir" \
        "$target_home/.local" "$state_dir" "$log_dir" ||
       ! chown 0:0 "$shared_dir"; then
        ui_error "Falha ao ajustar diretórios da configuração de Sala de Aula."
        log_error "Falha de propriedade/permissão nos diretórios de projeção."
        return 1
    fi
    if [ -L "$desktop_file" ] || [ -L "$shared_script" ] || [ -L "$log_file" ]; then
        ui_error "Um artefato existente da projeção é um link simbólico inseguro."
        log_error "Link simbólico rejeitado entre os artefatos da projeção."
        return 1
    fi

    temporary=$(mktemp "$shared_dir/.pmjs-auto-mirror.XXXXXX") || return 1
    if ! cp -- "$source_script" "$temporary" ||
       ! chmod 0755 "$temporary" ||
       ! chown 0:0 "$temporary" ||
       ! mv -f -- "$temporary" "$shared_script"; then
        rm -f -- "$temporary"
        ui_error "Falha ao instalar o script de espelhamento automático."
        log_error "Falha na instalação atômica de $shared_script"
        return 1
    fi
    temporary=$(mktemp "$autostart_dir/.pmjs-projecao.XXXXXX") || {
        log_error "Falha ao criar arquivo temporário para projeção."
        return 1
    }
    if ! printf '%s' "$content" > "$temporary" ||
       ! chmod 0644 "$temporary" ||
       ! chown "$user_uid:$user_gid" "$temporary" ||
       ! mv -f "$temporary" "$desktop_file"; then
        rm -f "$temporary"
        ui_error "Falha ao instalar o autostart de projeção."
        log_error "Falha na gravação atômica de $desktop_file"
        return 1
    fi

    if ! touch -- "$log_file" ||
       ! chmod 0644 "$log_file" ||
       ! chown "$user_uid:$user_gid" "$log_file"; then
        ui_error "Falha ao preparar o log da projeção."
        log_error "Não foi possível preparar $log_file para $user_uid:$user_gid."
        return 1
    fi

    actual_uid=$(stat -c %u "$desktop_file" 2>/dev/null || true)
    actual_gid=$(stat -c %g "$desktop_file" 2>/dev/null || true)
    actual_mode=$(stat -c %a "$desktop_file" 2>/dev/null || true)
    if [ ! -f "$desktop_file" ] ||
       ! grep -Fxq "[Desktop Entry]" "$desktop_file" ||
       ! grep -Fxq "Exec=/usr/local/lib/pmjs-deploy/auto-mirror-x11" "$desktop_file" ||
       [ "$actual_uid" != "$user_uid" ] ||
       [ "$actual_gid" != "$user_gid" ] ||
       [ "$actual_mode" != "644" ]; then
        ui_error "A validação do arquivo de projeção falhou."
        log_error "Autostart inválido em $desktop_file (uid=$actual_uid gid=$actual_gid modo=$actual_mode)."
        return 1
    fi
    if [ ! -f "$shared_script" ] ||
       [ "$(stat -c %u "$shared_script" 2>/dev/null || true)" != "0" ] ||
       [ "$(stat -c %g "$shared_script" 2>/dev/null || true)" != "0" ] ||
       [ "$(stat -c %a "$shared_script" 2>/dev/null || true)" != "755" ] ||
       [ "$(stat -c %u "$log_file" 2>/dev/null || true)" != "$user_uid" ] ||
       [ "$(stat -c %g "$log_file" 2>/dev/null || true)" != "$user_gid" ] ||
       [ "$(stat -c %a "$log_file" 2>/dev/null || true)" != "644" ]; then
        ui_error "A validação final dos artefatos da projeção falhou."
        log_error "Script compartilhado ou log com propriedade/permissão inválida."
        return 1
    fi

    if [ ! -x "$target_root/usr/bin/xrandr" ] &&
       [ ! -x "$target_root/bin/xrandr" ]; then
        ui_warning "A projeção foi configurada, mas xrandr não foi encontrado no sistema instalado."
        log_warning "Dependência runtime ausente para projeção: xrandr."
    fi

    ui_success "Configuração de Sala de Aula instalada para $target_user."
    log_info "Projeção automática instalada: script=/usr/local/lib/pmjs-deploy/auto-mirror-x11 (root:root 0755); autostart=$user_home/.config/autostart/projecao.desktop; log=$user_home/.local/state/pmjs-deploy/projecao.log; usuário=$target_user ($user_uid:$user_gid)."
}

postinstall_cleanup_chrome_singletons() {
    local target_root="${INSTALL_TARGET_ROOT:-}"
    local user_home=""
    local target_home=""
    local chrome_dir=""
    local singleton=""
    local found=0
    local removed=0

    user_home=$(postinstall_target_user_home) || {
        ui_error "Não foi possível determinar a home do usuário alvo."
        log_error "Limpeza do Chrome bloqueada: home de TARGET_USER inválida."
        return 1
    }
    target_home="$target_root$user_home"
    chrome_dir="$target_home/.config/google-chrome"

    if [ ! -d "$chrome_dir" ] || [ -L "$chrome_dir" ]; then
        log_info "Perfil do Google Chrome ausente; nenhum Singleton para remover em $user_home."
        return 0
    fi
    if ! postinstall_path_is_within "$target_home" "$target_root" ||
       ! postinstall_path_is_within "$chrome_dir" "$target_home"; then
        ui_error "O perfil do Chrome aponta para fora da home do sistema instalado."
        log_error "Limpeza do Chrome bloqueada por caminho fora do target: $chrome_dir"
        return 1
    fi

    while IFS= read -r -d '' singleton; do
        found=$((found + 1))
        if rm -f -- "$singleton" && [ ! -e "$singleton" ] && [ ! -L "$singleton" ]; then
            removed=$((removed + 1))
        else
            log_error "Falha ao remover Singleton do Chrome: $singleton"
            ui_error "Não foi possível remover um arquivo Singleton do Chrome."
            return 1
        fi
    done < <(
        find "$chrome_dir" -xdev \
            \( -type f -o -type l -o -type s \) \
            -name 'Singleton*' -print0
    )

    ui_success "Limpeza do Chrome concluída: $removed de $found Singleton removidos."
    log_info "Chrome: $found arquivos Singleton encontrados; $removed removidos em $user_home."
}

postinstall_package_installed() {
    local status_file="$INSTALL_TARGET_ROOT/var/lib/dpkg/status"
    local package="$1"

    [ -r "$status_file" ] || return 1
    awk -v wanted="$package" '
        BEGIN { RS=""; FS="\n" }
        {
            package_ok=0
            status_ok=0
            for (i=1; i<=NF; i++) {
                if ($i == "Package: " wanted) package_ok=1
                if ($i == "Status: install ok installed") status_ok=1
            }
            if (package_ok && status_ok) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$status_file"
}

postinstall_optional_chroot_apt() {
    local timeout_seconds="${POSTINSTALL_APT_TIMEOUT:-120}"
    local status=0

    log_info "Firmware Wi-Fi: antes do timeout de ${timeout_seconds}s para: $*."
    chroot_boot_log_command timeout "$timeout_seconds" chroot "$INSTALL_TARGET_ROOT" \
        /usr/bin/env HOME=/root LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
    log_run_external timeout "$timeout_seconds" chroot "$INSTALL_TARGET_ROOT" /usr/bin/env \
        HOME=/root LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$@" || status=$?
    log_info "Firmware Wi-Fi: timeout/chroot finalizado para '$*' com código $status."
    return "$status"
}

postinstall_install_wifi_firmware() {
    local package=""
    local -a missing_packages=()

    log_info "Firmware Wi-Fi: entrada em postinstall_install_wifi_firmware."
    if [ ! -x "$INSTALL_TARGET_ROOT/usr/bin/apt-get" ] &&
       [ ! -x "$INSTALL_TARGET_ROOT/bin/apt-get" ]; then
        log_info "Firmware Wi-Fi: apt-get ausente; nenhum subprocesso será iniciado."
        ui_warning "apt-get não está disponível no sistema instalado; firmwares Wi-Fi ignorados."
        log_warning "Pós-instalação não instalou firmware Wi-Fi: apt-get ausente no target."
        return 0
    fi

    for package in "${POSTINSTALL_WIFI_PACKAGES[@]}"; do
        if postinstall_package_installed "$package"; then
            log_info "Firmware Wi-Fi já instalado: $package"
        else
            missing_packages+=("$package")
        fi
    done
    if [ "${#missing_packages[@]}" -eq 0 ]; then
        ui_success "Todos os firmwares Wi-Fi solicitados já estão instalados."
        return 0
    fi

    log_info "Firmwares Wi-Fi pendentes: ${missing_packages[*]}"
    log_info "Firmware Wi-Fi: antes de apt-get update."
    if ! postinstall_optional_chroot_apt apt-get update; then
        log_info "Firmware Wi-Fi: apt-get update retornou falha."
        ui_warning "apt-get update indisponível; tentando instalar com os índices locais."
        log_warning "Atualização dos repositórios falhou ou expirou; instalação continuará sem ser bloqueada."
    else
        log_info "apt-get update concluído no sistema instalado."
    fi
    log_info "Firmware Wi-Fi: depois de apt-get update."

    log_info "Firmware Wi-Fi: antes de apt-get install."
    if ! postinstall_optional_chroot_apt apt-get install -y --no-install-recommends \
        "${missing_packages[@]}"; then
        log_info "Firmware Wi-Fi: apt-get install e seu timeout terminaram; preparando aviso ao operador."
        ui_warning "Não foi possível instalar todos os firmwares Wi-Fi; instalação principal continuará."
        log_warning "Instalação opcional de firmware Wi-Fi falhou ou expirou: ${missing_packages[*]}"
        return 0
    fi
    log_info "Firmware Wi-Fi: depois de apt-get install, código de sucesso."

    log_info "Pacotes de firmware Wi-Fi instalados com sucesso: ${missing_packages[*]}"
    log_info "Firmware Wi-Fi: update-initramfs não será executado aqui; a etapa obrigatória de boot será executada imediatamente depois."
    ui_success "Firmwares Wi-Fi instalados; o initramfs será atualizado na etapa de boot."
}

postinstall_run() {
    postinstall_validate_target || return 1

    if postinstall_is_dry_run; then
        log_info "Pós-instalação dry-run: configurar TAG OCS '${INSTALL_OCS_TAG:-}', instalar projeção de Sala de Aula quando aplicável, limpar Singleton do Chrome e verificar firmwares Wi-Fi."
        ui_warning "Dry-run da pós-instalação: nenhuma alteração foi executada."
        return 0
    fi

    log_info "Iniciando pós-instalação no target $INSTALL_TARGET_ROOT"
    postinstall_configure_ocs_tag || return 1
    postinstall_configure_classroom_projection || return 1
    postinstall_cleanup_chrome_singletons || return 1
    if [ "$INSTALL_WIFI_FIRMWARE" = "0" ]; then
        log_warning "Pós-instalação: rotina opcional de firmware Wi-Fi ignorada para diagnóstico (INSTALL_WIFI_FIRMWARE=0)."
    else
        log_info "Pós-instalação: chamando rotina opcional de firmware Wi-Fi (INSTALL_WIFI_FIRMWARE=$INSTALL_WIFI_FIRMWARE)."
        postinstall_install_wifi_firmware
        log_info "Pós-instalação: rotina opcional de firmware Wi-Fi retornou completamente."
    fi
    log_info "Pós-instalação concluída."
}
