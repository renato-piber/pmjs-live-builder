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
        log_info "Pós-instalação dry-run: configurar TAG OCS '${INSTALL_OCS_TAG:-}', limpar Singleton do Chrome e verificar firmwares Wi-Fi."
        ui_warning "Dry-run da pós-instalação: nenhuma alteração foi executada."
        return 0
    fi

    log_info "Iniciando pós-instalação no target $INSTALL_TARGET_ROOT"
    postinstall_configure_ocs_tag || return 1
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
