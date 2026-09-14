#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/logs.sh
source "${PROJECT_DIR}/lib/logs.sh"
# shellcheck source=lib/ui.sh
source "${PROJECT_DIR}/lib/ui.sh"
# shellcheck source=lib/archive.sh
source "${PROJECT_DIR}/lib/archive.sh"
# shellcheck source=lib/metadata.sh
source "${PROJECT_DIR}/lib/metadata.sh"
# shellcheck source=lib/publish.sh
source "${PROJECT_DIR}/lib/publish.sh"

IMAGE_DIR=""
declare -a PUBLISH_KINDS=()
declare -a PUBLISH_DIRS=()
declare -a PUBLISH_STAGING=()

usage() {
    cat <<'EOF'
Uso:
  ./publish-image.sh --image-dir DIRETÓRIO [DESTINOS]

Destinos (ao menos um):
  --ventoy-dir DIRETÓRIO   Diretório pmjs-images/ já existente na mídia Ventoy montada
  --nfs-dir DIRETÓRIO      Diretório já existente dentro do export NFS montado

A imagem local e todos os caminhos de publicação são obrigatoriamente explícitos.
Versões existentes não são substituídas.
EOF
}

cleanup() {
    local exit_code=$? index
    trap - EXIT INT TERM
    set +e
    for index in "${!PUBLISH_STAGING[@]}"; do
        [[ -n "${PUBLISH_STAGING[index]:-}" ]] || continue
        cleanup_publication_staging "${PUBLISH_STAGING[index]}" "${PUBLISH_DIRS[index]}" || exit_code=1
    done
    exit "${exit_code}"
}

on_signal() {
    local exit_code=$1
    exit "${exit_code}"
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --image-dir|--ventoy-dir|--nfs-dir)
                (( $# >= 2 )) || { ui_error "Valor ausente para $1"; return 1; }
                case "$1" in
                    --image-dir)
                        [[ -z "${IMAGE_DIR}" ]] || { ui_error "--image-dir foi informado mais de uma vez"; return 1; }
                        IMAGE_DIR=$2
                        ;;
                    --ventoy-dir)
                        PUBLISH_KINDS+=(ventoy)
                        PUBLISH_DIRS+=("$2")
                        ;;
                    --nfs-dir)
                        PUBLISH_KINDS+=(nfs)
                        PUBLISH_DIRS+=("$2")
                        ;;
                esac
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                ui_error "Argumento desconhecido: $1"
                return 1
                ;;
        esac
    done
    [[ -n "${IMAGE_DIR}" ]] || { ui_error "--image-dir é obrigatório"; return 1; }
    (( ${#PUBLISH_DIRS[@]} > 0 )) || { ui_error "Informe --ventoy-dir e/ou --nfs-dir"; return 1; }
}

main() {
    local index other resolved command_name

    parse_arguments "$@"
    for command_name in realpath findmnt awk basename dirname mktemp cp mv find sort \
        zstd tar sha256sum python3 sync; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            ui_error "Dependência ausente: ${command_name}"
            return 1
        }
    done
    IMAGE_DIR="$(realpath -e -- "${IMAGE_DIR}")" || {
        ui_error "A imagem local não existe: ${IMAGE_DIR}"
        return 1
    }
    validate_image_directory "${IMAGE_DIR}"

    for index in "${!PUBLISH_DIRS[@]}"; do
        validate_publish_destination "${PUBLISH_KINDS[index]}" "${PUBLISH_DIRS[index]}"
        resolved="$(realpath -e -- "${PUBLISH_DIRS[index]}")"
        PUBLISH_DIRS[index]="${resolved}"
        for other in "${!PUBLISH_DIRS[@]}"; do
            (( other < index )) || break
            [[ "${PUBLISH_DIRS[other]}" != "${resolved}" ]] || {
                ui_error "Destino de publicação repetido: ${resolved}"
                return 1
            }
        done
    done

    trap cleanup EXIT
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM
    for index in "${!PUBLISH_DIRS[@]}"; do
        PUBLISH_STAGING[index]=""
        prepare_image_publication "${IMAGE_DIR}" "${PUBLISH_DIRS[index]}" \
            "PUBLISH_STAGING[index]"
    done
    for index in "${!PUBLISH_STAGING[@]}"; do
        commit_image_publication "${PUBLISH_STAGING[index]}" "${PUBLISH_DIRS[index]}"
        PUBLISH_STAGING[index]=""
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
