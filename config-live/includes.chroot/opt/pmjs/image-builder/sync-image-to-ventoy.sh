#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${PROJECT_DIR}/lib/logs.sh"
source "${PROJECT_DIR}/lib/ui.sh"
source "${PROJECT_DIR}/lib/archive.sh"
source "${PROJECT_DIR}/lib/metadata.sh"
source "${PROJECT_DIR}/lib/nfs.sh"
source "${PROJECT_DIR}/lib/ventoy.sh"
source "${PROJECT_DIR}/lib/sync_ventoy.sh"

SYNC_IMAGE_NAME=""
SYNC_VENTOY_DIR=""
SYNC_SOURCE_DIR=""
SYNC_STAGING=""
SYNC_FINAL_DIR=""
SYNC_SUCCEEDED=false

usage() {
    cat <<'EOF'
Uso:
  sudo ./sync-image-to-ventoy.sh --image NOME --ventoy-dir DIRETÓRIO

Exemplo:
  sudo ./sync-image-to-ventoy.sh \
    --image pmjs-linux-0.2.0 \
    --ventoy-dir /media/usuario/Ventoy/pmjs-images

O NFS é montado ou reutilizado conforme config/image.conf. A versão no Ventoy
é imutável e só aparece após cópia e validação completas.
EOF
}

parse_sync_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --image|--ventoy-dir)
                (( $# >= 2 )) || { ui_error "Valor ausente para $1"; return 1; }
                [[ -n "$2" ]] || { ui_error "Valor vazio para $1"; return 1; }
                case "$1" in
                    --image)
                        [[ -z "${SYNC_IMAGE_NAME}" ]] || { ui_error "--image foi informado mais de uma vez"; return 1; }
                        SYNC_IMAGE_NAME=$2 ;;
                    --ventoy-dir)
                        [[ -z "${SYNC_VENTOY_DIR}" ]] || { ui_error "--ventoy-dir foi informado mais de uma vez"; return 1; }
                        SYNC_VENTOY_DIR=$2 ;;
                esac
                shift 2 ;;
            --help|-h) usage; return 2 ;;
            *) ui_error "Argumento desconhecido: $1"; return 1 ;;
        esac
    done
    [[ -n "${SYNC_IMAGE_NAME}" ]] || { ui_error "--image é obrigatório"; return 1; }
    [[ -n "${SYNC_VENTOY_DIR}" ]] || { ui_error "--ventoy-dir é obrigatório"; return 1; }
}

check_sync_dependencies() {
    local dependency
    for dependency in realpath findmnt mount umount mount.nfs basename dirname \
        mktemp rsync mv find zstd tar sha256sum python3 sync stat df tail tr \
        awk grep sort wc date mkdir; do
        command -v "${dependency}" >/dev/null 2>&1 || {
            ui_error "Dependência ausente para sincronização: ${dependency}"
            return 1
        }
    done
}

check_sync_root() {
    (( EUID == 0 )) || { ui_error "Execute a sincronização como root."; return 1; }
}

load_sync_config() {
    local config_file="${PROJECT_DIR}/config/image.conf"
    [[ -r "${config_file}" ]] || { ui_error "Configuração não encontrada: ${config_file}"; return 1; }
    source "${config_file}"
}

cleanup() {
    local exit_code=$?
    trap - EXIT ERR INT TERM
    set +e
    if [[ -n "${SYNC_STAGING:-}" ]]; then
        cleanup_ventoy_sync_staging "${SYNC_STAGING}" "${VENTOY_DESTINATION:-}" \
            "${SYNC_IMAGE_NAME:-}" || { [[ ${exit_code} -ne 0 ]] || exit_code=1; }
        SYNC_STAGING=""
    fi
    cleanup_nfs_mount
    if [[ "${SYNC_SUCCEEDED}" != true && ${exit_code} -ne 0 ]]; then
        ui_error "Sincronização interrompida (código ${exit_code})."
    fi
    exit "${exit_code}"
}

on_signal() {
    local signal=$1
    if [[ "${NFS_MOUNT_IN_PROGRESS}" == 1 ]]; then
        NFS_PENDING_SIGNAL=${signal}
        return 0
    fi
    [[ "${signal}" == INT ]] && exit 130
    exit 143
}

main() {
    local parse_status=0 image_bytes rootfs_bytes homefs_bytes

    if parse_sync_arguments "$@"; then
        :
    else
        parse_status=$?
        [[ ${parse_status} -eq 2 ]] && return 0
        return "${parse_status}"
    fi
    check_sync_root || return 1
    check_sync_dependencies || return 1
    load_sync_config || return 1
    validate_sync_image_name "${SYNC_IMAGE_NAME}" "${IMAGE_NAME}" || return 1

    if [[ "${LOG_DIR}" == /* ]]; then
        LOG_DIR="$(realpath -m -- "${LOG_DIR}")"
    else
        LOG_DIR="$(realpath -m -- "${PROJECT_DIR}/${LOG_DIR}")"
    fi
    mkdir -p -- "${LOG_DIR}" || return 1
    init_log "${LOG_DIR}" || return 1
    trap cleanup EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM

    prepare_nfs_automount || { ui_error "Sincronização não iniciada."; return 1; }
    SYNC_SOURCE_DIR="${NFS_MOUNTPOINT}/${SYNC_IMAGE_NAME}"
    [[ "$(realpath -e -- "${SYNC_SOURCE_DIR}")" == "${SYNC_SOURCE_DIR}" &&
       "$(dirname -- "${SYNC_SOURCE_DIR}")" == "${NFS_MOUNTPOINT}" ]] || {
        ui_error "Imagem não encontrada como versão final no NFS: ${SYNC_SOURCE_DIR}"
        return 1
    }
    ui_info "Validando imagem no servidor NFS..."
    validate_image_directory "${SYNC_SOURCE_DIR}" || {
        ui_error "Imagem inválida no servidor NFS: ${SYNC_IMAGE_NAME}"
        return 1
    }
    nfs_active_mount_unchanged || { ui_error "O mount NFS mudou durante a validação"; return 1; }

    validate_ventoy_sync_destination "${SYNC_VENTOY_DIR}" || return 1
    image_bundle_size_bytes "${SYNC_SOURCE_DIR}" image_bytes || return 1
    check_ventoy_free_space "${VENTOY_DESTINATION}" "${image_bytes}" \
        "${VENTOY_FREE_SPACE_MARGIN_MIB:-64}" || return 1
    prepare_ventoy_sync_staging "${VENTOY_DESTINATION}" "${SYNC_IMAGE_NAME}" \
        SYNC_STAGING || return 1
    copy_image_to_ventoy_staging "${SYNC_SOURCE_DIR}" "${SYNC_STAGING}" || return 1
    nfs_active_mount_unchanged || { ui_error "O mount NFS mudou durante a cópia"; return 1; }
    validate_copied_ventoy_bundle "${SYNC_STAGING}" || return 1
    commit_ventoy_sync "${SYNC_STAGING}" "${VENTOY_DESTINATION}" \
        "${SYNC_IMAGE_NAME}" || return 1
    SYNC_STAGING=""
    SYNC_FINAL_DIR="${VENTOY_DESTINATION}/${SYNC_IMAGE_NAME}"
    rootfs_bytes="$(stat -c '%s' -- "${SYNC_FINAL_DIR}/rootfs.tar.zst")" || return 1
    homefs_bytes="$(stat -c '%s' -- "${SYNC_FINAL_DIR}/homefs.tar.zst")" || return 1
    SYNC_SUCCEEDED=true

    ui_success "Imagem copiada para o Ventoy"
    printf '\nImagem: %s\nDestino: %s\nRootfs: %s\nHomefs: %s\nSHA256: OK\n' \
        "${SYNC_IMAGE_NAME}" "${SYNC_FINAL_DIR}" \
        "$(format_sync_size "${rootfs_bytes}")" "$(format_sync_size "${homefs_bytes}")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
