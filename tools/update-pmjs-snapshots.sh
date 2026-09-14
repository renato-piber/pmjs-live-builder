#!/usr/bin/env bash

set -Eeuo pipefail

readonly LIVE_BUILDER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly SNAPSHOT_ROOT="${LIVE_BUILDER_ROOT}/config-live/includes.chroot/opt/pmjs"

DEPLOY_SOURCE="${LIVE_BUILDER_ROOT}/../pmjs-deploy"
IMAGE_BUILDER_SOURCE="${LIVE_BUILDER_ROOT}/../pmjs-image-builder"
STAGING_ROOT=""
ACTIVE_DESTINATION=""
ACTIVE_BACKUP=""

readonly -a DEPLOY_RUNTIME_FILES=(
    VERSION
    deploy.sh
    config/deploy.conf
    assets/auto-mirror-x11
    lib/chroot_boot.sh
    lib/disks.sh
    lib/extract.sh
    lib/filesystems.sh
    lib/image_contract.sh
    lib/images.sh
    lib/install.sh
    lib/logs.sh
    lib/mounts.sh
    lib/network.sh
    lib/partitions.sh
    lib/postinstall.sh
    lib/smart.sh
    lib/storage.sh
    lib/system_config.sh
    lib/timer.sh
    lib/ui.sh
    lib/utils.sh
    lib/validation.sh
)

readonly -a IMAGE_BUILDER_RUNTIME_FILES=(
    VERSION
    build-image.sh
    publish-image.sh
    sync-image-to-ventoy.sh
    config/image.conf
    lib/archive.sh
    lib/checks.sh
    lib/generalize.sh
    lib/homefs.sh
    lib/logs.sh
    lib/metadata.sh
    lib/nfs.sh
    lib/publish.sh
    lib/rootfs.sh
    lib/source_detect.sh
    lib/sync_ventoy.sh
    lib/ui.sh
    lib/ventoy.sh
)

usage() {
    cat <<'EOF'
Uso:
  ./tools/update-pmjs-snapshots.sh [opcoes]

Opcoes:
  --deploy-source DIR         checkout do PMJS Deploy
  --image-builder-source DIR  checkout do PMJS Image Builder
  --help

Sem opcoes, usa os projetos irmaos ../pmjs-deploy e ../pmjs-image-builder.
Somente os arquivos runtime enumerados no script sao incorporados.
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --deploy-source|--image-builder-source)
                (( $# >= 2 )) || { printf 'Valor ausente para %s\n' "$1" >&2; return 2; }
                case "$1" in
                    --deploy-source) DEPLOY_SOURCE=$2 ;;
                    --image-builder-source) IMAGE_BUILDER_SOURCE=$2 ;;
                esac
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf 'Opcao desconhecida: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done
}

cleanup() {
    local status=$? restore_failed=0
    trap - EXIT INT TERM
    set +e

    if [[ -n "${ACTIVE_BACKUP}" && -d "${ACTIVE_BACKUP}" &&
          -n "${ACTIVE_DESTINATION}" && ! -e "${ACTIVE_DESTINATION}" ]]; then
        if ! mv -- "${ACTIVE_BACKUP}" "${ACTIVE_DESTINATION}"; then
            printf 'Falha ao restaurar snapshot anterior; staging preservado: %s\n' \
                "${STAGING_ROOT}" >&2
            restore_failed=1
        fi
    fi
    if (( restore_failed == 0 )) && [[ -n "${STAGING_ROOT}" && -d "${STAGING_ROOT}" &&
          "$(dirname -- "${STAGING_ROOT}")" == "${SNAPSHOT_ROOT}" &&
          "$(basename -- "${STAGING_ROOT}")" == .snapshot-update.* ]]; then
        find -P "${STAGING_ROOT}" -depth -delete
    fi
    (( restore_failed == 0 )) || status=1
    exit "${status}"
}

resolve_source() {
    local configured=$1
    realpath -e -- "${configured}"
}

copy_runtime_snapshot() {
    local source_root=$1 project_name=$2 files_name=$3
    local -n runtime_files=$files_name
    local destination="${STAGING_ROOT}/${project_name}" relative version commit state

    [[ -d "${source_root}" && ! -L "${source_root}" ]] || {
        printf 'Checkout invalido para %s: %s\n' "${project_name}" "${source_root}" >&2
        return 1
    }
    for relative in "${runtime_files[@]}"; do
        [[ -f "${source_root}/${relative}" && ! -L "${source_root}/${relative}" ]] || {
            printf 'Arquivo runtime ausente ou inseguro em %s: %s\n' \
                "${project_name}" "${relative}" >&2
            return 1
        }
    done

    mkdir -p -- "${destination}"
    (cd -- "${source_root}" && cp -a --parents -- "${runtime_files[@]}" "${destination}/")

    version="$(tr -d '[:space:]' < "${source_root}/VERSION")"
    [[ -n "${version}" ]] || { printf 'VERSION vazio em %s\n' "${source_root}" >&2; return 1; }
    commit=unavailable
    state=unversioned
    if git -C "${source_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        commit="$(git -C "${source_root}" rev-parse HEAD)"
        state=clean
        if [[ -n "$(git -C "${source_root}" status --porcelain -- \
            "${runtime_files[@]}")" ]]; then
            state=dirty
        fi
    fi
    printf 'project=%s\nversion=%s\nsource_commit=%s\nsource_state=%s\n' \
        "${project_name}" "${version}" "${commit}" "${state}" \
        > "${destination}/SNAPSHOT"
}

validate_runtime_snapshot() {
    local directory=$1 entrypoint=$2 expected_count=$3 actual_count forbidden

    [[ -x "${directory}/${entrypoint}" && -s "${directory}/VERSION" &&
       -s "${directory}/SNAPSHOT" ]] || {
        printf 'Snapshot incompleto: %s\n' "${directory}" >&2
        return 1
    }
    actual_count="$(find "${directory}" -type f | wc -l)"
    (( actual_count == expected_count + 1 )) || {
        printf 'Quantidade inesperada de arquivos em %s: %s\n' "${directory}" "${actual_count}" >&2
        return 1
    }
    forbidden="$(find "${directory}" \
        \( -name .git -o -name logs -o -name cache -o -name output -o \
           -name work -o -name tests -o -name '*.partial' -o \
           -name 'rootfs.tar.*' -o -name 'homefs.tar.*' -o \
           -name 'pmjs-linux-*' \) -print -quit)"
    [[ -z "${forbidden}" ]] || {
        printf 'Artefato proibido no snapshot: %s\n' "${forbidden}" >&2
        return 1
    }
}

replace_snapshot() {
    local project_name=$1
    local new_directory="${STAGING_ROOT}/${project_name}"
    local destination="${SNAPSHOT_ROOT}/${project_name}"
    local backup="${STAGING_ROOT}/.previous-${project_name}"

    [[ ! -L "${destination}" ]] || {
        printf 'Destino de snapshot e symlink; atualizacao recusada: %s\n' "${destination}" >&2
        return 1
    }
    ACTIVE_DESTINATION=${destination}
    ACTIVE_BACKUP=""
    if [[ -e "${destination}" ]]; then
        [[ -d "${destination}" ]] || {
            printf 'Destino de snapshot nao e diretorio: %s\n' "${destination}" >&2
            return 1
        }
        mv -- "${destination}" "${backup}"
        ACTIVE_BACKUP=${backup}
    fi
    if ! mv -- "${new_directory}" "${destination}"; then
        if [[ -n "${ACTIVE_BACKUP}" ]] &&
           mv -- "${ACTIVE_BACKUP}" "${destination}"; then
            ACTIVE_BACKUP=""
            ACTIVE_DESTINATION=""
        fi
        return 1
    fi
    ACTIVE_BACKUP=""
    ACTIVE_DESTINATION=""
    if [[ -d "${backup}" ]]; then
        find -P "${backup}" -depth -delete
    fi
}

main() {
    parse_arguments "$@"
    DEPLOY_SOURCE="$(resolve_source "${DEPLOY_SOURCE}")"
    IMAGE_BUILDER_SOURCE="$(resolve_source "${IMAGE_BUILDER_SOURCE}")"
    mkdir -p -- "${SNAPSHOT_ROOT}"
    STAGING_ROOT="$(mktemp --directory --tmpdir="${SNAPSHOT_ROOT}" '.snapshot-update.XXXXXX')"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    copy_runtime_snapshot "${DEPLOY_SOURCE}" deploy DEPLOY_RUNTIME_FILES
    copy_runtime_snapshot "${IMAGE_BUILDER_SOURCE}" image-builder IMAGE_BUILDER_RUNTIME_FILES
    validate_runtime_snapshot "${STAGING_ROOT}/deploy" deploy.sh "${#DEPLOY_RUNTIME_FILES[@]}"
    validate_runtime_snapshot "${STAGING_ROOT}/image-builder" build-image.sh \
        "${#IMAGE_BUILDER_RUNTIME_FILES[@]}"

    replace_snapshot deploy
    replace_snapshot image-builder
    printf 'Snapshots atualizados:\n  %s\n  %s\n' \
        "${SNAPSHOT_ROOT}/deploy" "${SNAPSHOT_ROOT}/image-builder"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
