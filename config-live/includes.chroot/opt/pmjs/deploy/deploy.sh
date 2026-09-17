#!/bin/bash

set -Eeuo pipefail

PROJECT_ROOT=$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)

VERSION=$(<"$PROJECT_ROOT/VERSION")

# shellcheck source=/dev/null
source "$PROJECT_ROOT/config/deploy.conf"

source "$PROJECT_ROOT/lib/ui.sh"
source "$PROJECT_ROOT/lib/logs.sh"
source "$PROJECT_ROOT/lib/timer.sh"

source "$PROJECT_ROOT/lib/network.sh"
source "$PROJECT_ROOT/lib/image_contract.sh"
source "$PROJECT_ROOT/lib/images.sh"
source "$PROJECT_ROOT/lib/disks.sh"
source "$PROJECT_ROOT/lib/smart.sh"

source "$PROJECT_ROOT/lib/validation.sh"

source "$PROJECT_ROOT/lib/storage.sh"
source "$PROJECT_ROOT/lib/partitions.sh"
source "$PROJECT_ROOT/lib/filesystems.sh"
source "$PROJECT_ROOT/lib/mounts.sh"
source "$PROJECT_ROOT/lib/extract.sh"
source "$PROJECT_ROOT/lib/system_config.sh"
source "$PROJECT_ROOT/lib/chroot_boot.sh"
source "$PROJECT_ROOT/lib/postinstall.sh"

source "$PROJECT_ROOT/lib/install.sh"

on_error() {
    local exit_code=$?
    local line_number=$1

    timer_live_stop "cleanup do tratador de erro" || true
    storage_preserve_home_preflight_cleanup || true
    images_cleanup_offline_mount || true
    ui_error "Falha inesperada na linha $line_number."
    log_error "Falha inesperada na linha $line_number. Código: $exit_code"

    exit "$exit_code"
}

on_signal() {
    local signal="$1"
    local exit_code=143

    [ "$signal" = "INT" ] && exit_code=130
    timer_live_stop "cleanup por sinal $signal" || true
    storage_preserve_home_preflight_cleanup || true
    images_cleanup_offline_mount || true
    log_warning "PMJS Deploy interrompido por $signal."
    trap - ERR INT TERM
    exit "$exit_code"
}

trap 'on_error $LINENO' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        ui_error "Execute o PMJS Deploy como root."
        exit 1
    fi
}

show_images() {
    ui_clear
    ui_title "$VERSION"

    if ! images_select_source; then
        ui_pause
        return
    fi

    echo
    echo "Fonte: $IMAGES_SOURCE"
    echo "Caminho: $IMAGES_BASE"
    echo
    echo "Imagens disponíveis:"
    echo

    images_list | nl -w2 -s') '

    ui_pause
}

show_system_info() {
    ui_clear
    ui_title "$VERSION"

    echo "Hostname: $(hostname)"
    echo "Kernel:   $(uname -r)"
    echo "Boot:     $([ -d /sys/firmware/efi ] && echo UEFI || echo Legacy)"
    echo
    lsblk -o NAME,TYPE,SIZE,MODEL,FSTYPE,MOUNTPOINT

    ui_pause
}

main_menu() {
    while true; do
        ui_clear
        ui_title "$VERSION"

        echo "1) Instalar imagem Linux"
        echo "2) Informações do sistema"
        echo "3) Testar servidor NFS"
        echo "4) Verificar discos disponíveis"
        echo "0) Sair"

        read -rp "Escolha uma opção: " option

        case "$option" in
            1)
                log_info "main_menu: iniciando fluxo de instalação."
                install_start
                timer_live_stop "cleanup defensivo ao retornar ao menu" || true
                if ! images_cleanup_offline_mount; then
                    ui_warning "A mídia offline não pôde ser desmontada; consulte o log."
                fi
                log_info "main_menu: fluxo de instalação retornou; retomando menu principal."
                ;;
            2)
                show_system_info
                ;;
            3)
                ui_clear
                ui_title "$VERSION"

                if network_mount_nfs; then
                    ui_success "Servidor NFS acessível."
                    log_info "Teste do servidor NFS concluído com sucesso."
                else
                    ui_warning "Não foi possível completar o teste do servidor NFS."
                    log_warning "Falha no teste do servidor NFS."
                fi

                ui_pause
                ;;

            4)
                ui_clear
                ui_title "$VERSION"

                if disks_select; then
                    disks_show_details "$SELECTED_DISK"
                fi

                ui_pause
                ;;

            0)
                if ! images_cleanup_offline_mount; then
                    ui_warning "A mídia offline não pôde ser desmontada; consulte o log."
                fi
                exit 0
                ;;
            *)
                ui_warning "Opção inválida."
                sleep 1
                ;;
        esac
    done
}

require_root
log_init "$PROJECT_ROOT"
log_info "PMJS Deploy $VERSION iniciado em ambiente $PMJS_ENVIRONMENT."

main_menu
