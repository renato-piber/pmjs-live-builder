#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/logs.sh
source "${PROJECT_DIR}/lib/logs.sh"
# shellcheck source=lib/ui.sh
source "${PROJECT_DIR}/lib/ui.sh"
# shellcheck source=lib/checks.sh
source "${PROJECT_DIR}/lib/checks.sh"
# shellcheck source=lib/nfs.sh
source "${PROJECT_DIR}/lib/nfs.sh"
# shellcheck source=lib/ventoy.sh
source "${PROJECT_DIR}/lib/ventoy.sh"
# shellcheck source=lib/archive.sh
source "${PROJECT_DIR}/lib/archive.sh"
# shellcheck source=lib/source_detect.sh
source "${PROJECT_DIR}/lib/source_detect.sh"
# shellcheck source=lib/generalize.sh
source "${PROJECT_DIR}/lib/generalize.sh"
# shellcheck source=lib/homefs.sh
source "${PROJECT_DIR}/lib/homefs.sh"
# shellcheck source=lib/rootfs.sh
source "${PROJECT_DIR}/lib/rootfs.sh"
# shellcheck source=lib/metadata.sh
source "${PROJECT_DIR}/lib/metadata.sh"

readonly START_TIME=${SECONDS}
BUILD_SUCCEEDED=false
ROOTFS_TEMP_FILE=""
HOMEFS_TEMP_FILE=""
CHECKSUM_TEMP_FILE=""
MANIFEST_TEMP_FILE=""
HOMEFS_STAGING=""
GENERALIZATION_STAGING=""
GENERALIZATION_BUILD_DIR=""
BUILD_DIR=""
BUILD_WORKSPACE=""
LOCAL_IMAGE_DIR=""
BUILD_NFS_DIR=""
BUILD_VENTOY_DIR=""
BUILD_DESTINATION_KIND="local"
LOCAL_TEMP_DIR_RESOLVED=""
HOMEFS_STAGING_PARENT=""
ROOTFS_GENERATE_SECONDS=0
ROOTFS_VALIDATE_SECONDS=0
HOMEFS_GENERATE_SECONDS=0
HOMEFS_VALIDATE_SECONDS=0

cleanup() {
    local exit_code=$?

    trap - EXIT ERR INT TERM
    set +e

    if [[ -n "${GENERALIZATION_STAGING:-}" ]]; then
        cleanup_generalization_staging "${GENERALIZATION_STAGING}" \
            "${GENERALIZATION_BUILD_DIR}" || exit_code=1
        GENERALIZATION_STAGING=""
        GENERALIZATION_BUILD_DIR=""
    fi
    if [[ -n "${HOMEFS_STAGING:-}" ]]; then
        cleanup_homefs_staging "${HOMEFS_STAGING}" \
            "${HOMEFS_STAGING_PARENT:-}" || exit_code=1
        HOMEFS_STAGING=""
        HOMEFS_STAGING_PARENT=""
    fi
    # Os archives parciais pertencem ao workspace validado; nunca remover um
    # arquivo apontado isoladamente, nem limpar um NFS que tenha sido trocado.
    if [[ -n "${BUILD_WORKSPACE:-}" ]]; then
        if [[ "${BUILD_DESTINATION_KIND:-}" == ventoy ]] && ! ventoy_mount_unchanged; then
            ui_warn "Staging Ventoy não removido: identidade do mount mudou ou não pôde ser confirmada."
        elif [[ -n "${NFS_ACTIVE_MOUNTPOINT}" ]] && ! nfs_active_mount_unchanged; then
            ui_warn "Staging NFS não removido: identidade do mount mudou ou não pôde ser confirmada."
        else
            cleanup_build_workspace "${BUILD_WORKSPACE}" "${OUTPUT_DIR:-}" || {
                [[ ${exit_code} -ne 0 ]] || exit_code=1
            }
        fi
        BUILD_WORKSPACE=""
    fi
    if [[ -n "${SOURCE_DETECT_DIR:-}" ]]; then
        cleanup_detected_capture_source || exit_code=1
    fi
    cleanup_nfs_mount

    if [[ "${BUILD_SUCCEEDED}" != true && ${exit_code} -ne 0 ]]; then
        ui_error "Build interrompido (código ${exit_code}). Consulte: ${LOG_FILE:-log não inicializado}"
    fi

    exit "${exit_code}"
}

on_error() {
    local exit_code=$1
    local line=$2
    local command=$3

    log_write ERROR "Falha na linha ${line} (código ${exit_code}): ${command}"
    return "${exit_code}"
}

on_signal() {
    local signal=$1
    if [[ "${NFS_MOUNT_IN_PROGRESS}" == 1 ]]; then
        NFS_PENDING_SIGNAL=${signal}
        return 0
    fi
    log_write WARN "Sinal ${signal} recebido; interrompendo o build."
    [[ "${signal}" == INT ]] && exit 130
    exit 143
}

trap cleanup EXIT
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

usage() {
    cat <<'EOF'
Uso:
  sudo ./build-image.sh [--nfs-dir DIRETÓRIO | --ventoy-dir DIRETÓRIO]

Sem uma opção de destino, NFS_ENABLED=1 monta/reutiliza o NFS de config/image.conf.
Com NFS_ENABLED=0 (ou ausente), usa NFS_IMAGES_DIR legado ou OUTPUT_DIR local.
Com --nfs-dir, os archives são gerados diretamente em um staging oculto no
filesystem NFS informado e a imagem só aparece após validação e rename final.
Essa opção tem precedência: o diretório deve existir, estar montado e ser
gravável; o Builder não monta nem desmonta esse destino explícito.

Com --ventoy-dir, os archives são gerados diretamente em um staging oculto
sob o diretório pmjs-images de uma mídia já montada. A identidade do mount é
validada durante o build e o NFS configurado não é acessado. Generalização e
homefs continuam usando apenas LOCAL_TEMP_DIR em filesystem Linux local.
EOF
}

parse_build_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --nfs-dir)
                (( $# >= 2 )) || { ui_error "Valor ausente para --nfs-dir"; return 1; }
                [[ -n "$2" ]] || { ui_error "Valor vazio para --nfs-dir"; return 1; }
                [[ -z "${BUILD_NFS_DIR}" ]] || {
                    ui_error "--nfs-dir foi informado mais de uma vez"
                    return 1
                }
                BUILD_NFS_DIR=$2
                shift 2
                ;;
            --ventoy-dir)
                (( $# >= 2 )) || { ui_error "Valor ausente para --ventoy-dir"; return 1; }
                [[ -n "$2" ]] || { ui_error "Valor vazio para --ventoy-dir"; return 1; }
                [[ -z "${BUILD_VENTOY_DIR}" ]] || {
                    ui_error "--ventoy-dir foi informado mais de uma vez"
                    return 1
                }
                BUILD_VENTOY_DIR=$2
                shift 2
                ;;
            --help|-h)
                usage
                return 2
                ;;
            *)
                ui_error "Argumento desconhecido: $1"
                return 1
                ;;
        esac
    done
    [[ -z "${BUILD_NFS_DIR}" || -z "${BUILD_VENTOY_DIR}" ]] || {
        ui_error "--nfs-dir e --ventoy-dir são mutuamente exclusivos"
        return 1
    }
}

check_active_build_destination() {
    local phase=$1
    if [[ "${BUILD_DESTINATION_KIND}" == ventoy ]] && ! ventoy_mount_unchanged; then
        ui_error "O mount do Ventoy mudou ${phase}; build interrompido"
        return 1
    fi
}

select_build_destination() {
    if [[ -n "${BUILD_VENTOY_DIR}" ]]; then
        check_ventoy_dependencies || { ui_error "Build não iniciado."; return 1; }
        validate_ventoy_destination "${BUILD_VENTOY_DIR}" || {
            ui_error "Build não iniciado."
            return 1
        }
        BUILD_VENTOY_DIR=${VENTOY_DESTINATION}
    elif ! select_build_nfs_destination; then
        ui_error "Build não iniciado."
        return 1
    fi
}

build_rootfs_artifact() {
    local source_root=$1
    local build_dir=$2
    local rootfs_file=$3 compression=${4:-gzip} zstd_level=${5:-3}
    local local_staging_parent=${6:-$build_dir} phase_start

    validate_generalization_source "${source_root}" || return 1
    GENERALIZATION_BUILD_DIR="${local_staging_parent}"
    prepare_generalization_staging "${local_staging_parent}" GENERALIZATION_STAGING || return 1
    validate_generalization_staging "${GENERALIZATION_STAGING}" || return 1
    log_write INFO "Staging de generalização: ${GENERALIZATION_STAGING}"

    ROOTFS_TEMP_FILE="${rootfs_file}.partial"
    phase_start=${SECONDS}
    generate_rootfs "${source_root}" "${build_dir}" "${ROOTFS_TEMP_FILE}" \
        "${GENERALIZATION_STAGING}" "${compression}" "${zstd_level}" || return 1
    ROOTFS_GENERATE_SECONDS=$(( SECONDS - phase_start ))
    phase_start=${SECONDS}
    validate_rootfs "${ROOTFS_TEMP_FILE}" "${source_root}" "${build_dir}" \
        "${compression}" || return 1
    ROOTFS_VALIDATE_SECONDS=$(( SECONDS - phase_start ))
    mv -f -- "${ROOTFS_TEMP_FILE}" "${rootfs_file}" || return 1
    ROOTFS_TEMP_FILE=""

    cleanup_generalization_staging "${GENERALIZATION_STAGING}" \
        "${local_staging_parent}" || return 1
    GENERALIZATION_STAGING=""
    GENERALIZATION_BUILD_DIR=""
}

build_homefs_artifact() {
    local home_source=$1 home_user=$2 home_uid=$3 home_gid=$4
    local max_size_mib=$5 build_dir=$6 homefs_file=$7
    local compression=${8:-gzip} zstd_level=${9:-3} local_staging_parent=${10:-}
    local phase_start
    local -a standard_directories

    detect_home_standard_directories "${home_source}" standard_directories || return 1
    prepare_homefs_staging "${home_source}" "${home_user}" "${home_uid}" "${home_gid}" \
        standard_directories HOMEFS_STAGING "${local_staging_parent}" || return 1
    HOMEFS_STAGING_PARENT="$(dirname -- "${HOMEFS_STAGING}")"
    log_write INFO "Staging do homefs: ${HOMEFS_STAGING}"
    log_write INFO "Filesystem do staging do homefs: $(stat --file-system --format='%T' -- "${HOMEFS_STAGING}")"
    log_write INFO "Archive final do homefs: ${homefs_file}"
    validate_homefs_staging "${HOMEFS_STAGING}" "${home_user}" "${home_uid}" "${home_gid}" \
        "${max_size_mib}" "${standard_directories[@]}" || return 1

    HOMEFS_TEMP_FILE="${homefs_file}.partial"
    phase_start=${SECONDS}
    generate_homefs "${HOMEFS_STAGING}" "${home_user}" "${HOMEFS_TEMP_FILE}" \
        "${compression}" "${zstd_level}" || return 1
    HOMEFS_GENERATE_SECONDS=$(( SECONDS - phase_start ))
    phase_start=${SECONDS}
    validate_homefs_archive "${HOMEFS_TEMP_FILE}" "${home_user}" \
        "${standard_directories[@]}" || return 1
    HOMEFS_VALIDATE_SECONDS=$(( SECONDS - phase_start ))
    mv -f -- "${HOMEFS_TEMP_FILE}" "${homefs_file}" || return 1
    HOMEFS_TEMP_FILE=""

    cleanup_homefs_staging "${HOMEFS_STAGING}" "${HOMEFS_STAGING_PARENT}" || return 1
    HOMEFS_STAGING=""
    HOMEFS_STAGING_PARENT=""
}

build_metadata_artifacts() {
    local build_dir=$1 rootfs_file=$2 homefs_file=$3 checksum_file=$4 manifest_file=$5
    local image_name=$6 image_version=$7 builder_version=$8 compression=$9 source_root=${10}

    CHECKSUM_TEMP_FILE="${checksum_file}.partial"
    MANIFEST_TEMP_FILE="${manifest_file}.partial"
    generate_checksums "${build_dir}" "${rootfs_file}" "${homefs_file}" \
        "${CHECKSUM_TEMP_FILE}" || return 1
    validate_checksums "${build_dir}" "${CHECKSUM_TEMP_FILE}" || return 1
    generate_manifest "${MANIFEST_TEMP_FILE}" "${image_name}" "${image_version}" \
        "${builder_version}" "${compression}" "${rootfs_file}" "${homefs_file}" \
        "${source_root}" || return 1
    validate_manifest "${MANIFEST_TEMP_FILE}" "${rootfs_file}" "${homefs_file}" \
        "${compression}" || return 1
    mv -f -- "${CHECKSUM_TEMP_FILE}" "${checksum_file}" || return 1
    CHECKSUM_TEMP_FILE=""
    mv -f -- "${MANIFEST_TEMP_FILE}" "${manifest_file}" || return 1
    MANIFEST_TEMP_FILE=""
}

main() {
    local config_file="${PROJECT_DIR}/config/image.conf"
    local version_file="${PROJECT_DIR}/VERSION"
    local elapsed rootfs_size homefs_size home_uid home_gid resolved_source_root
    local extension preparation_seconds metadata_seconds metadata_start builder_version
    local image_directory_name local_required_mib home_staging_estimate_mib parse_status=0

    ui_header

    if parse_build_arguments "$@"; then
        :
    else
        parse_status=$?
        [[ ${parse_status} -eq 2 ]] && return 0
        return "${parse_status}"
    fi

    check_root
    check_dependencies
    check_config_file "${config_file}"
    # shellcheck source=config/image.conf
    source "${config_file}"
    validate_config
    check_compression_dependency "${IMAGE_COMPRESSION}"
    load_builder_version "${version_file}" builder_version
    extension="$(archive_extension "${IMAGE_COMPRESSION}")"
    ROOTFS_FILENAME="rootfs.${extension}"
    HOMEFS_FILENAME="homefs.${extension}"

    LOG_DIR="$(resolve_project_path "${PROJECT_DIR}" "${LOG_DIR}")"
    LOCAL_TEMP_DIR="${LOCAL_TEMP_DIR:-/var/tmp/pmjs-image-builder/staging}"
    LOCAL_TEMP_DIR="$(resolve_project_path "${PROJECT_DIR}" "${LOCAL_TEMP_DIR}")"

    mkdir -p -- "${LOG_DIR}"
    [[ -d "${LOG_DIR}" && -w "${LOG_DIR}" ]] || {
        ui_error "Diretório de logs não gravável: ${LOG_DIR}"
        return 1
    }

    init_log "${LOG_DIR}"
    log_write INFO "Iniciando build ${IMAGE_NAME}-${IMAGE_VERSION}"
    log_write INFO "Configuração carregada de ${config_file}"
    log_write INFO "Versões independentes: builder=${builder_version} (VERSION), imagem=${IMAGE_VERSION} (config/image.conf)"

    select_build_destination || return 1

    if [[ "${SOURCE_ROOT}" == auto ]]; then
        [[ "${HOME_SOURCE}" == auto ]] || {
            ui_error "HOME_SOURCE também deve ser 'auto' quando SOURCE_ROOT='auto'"
            return 1
        }
        detect_capture_sources "${HOME_USER}" SOURCE_ROOT HOME_SOURCE
    fi
    resolve_source_root "${SOURCE_ROOT}" resolved_source_root
    if [[ "${resolved_source_root}" != "$(realpath -e -- "${SOURCE_ROOT}")" ]]; then
        log_write INFO "Subvolume @rootfs detectado automaticamente: ${resolved_source_root}"
    fi
    SOURCE_ROOT="${resolved_source_root}"
    readonly SOURCE_ROOT
    readonly HOME_SOURCE
    log_write INFO "Raiz efetiva da captura: ${SOURCE_ROOT}"
    check_source_root "${SOURCE_ROOT}"
    validate_detected_capture_source "${SOURCE_ROOT}"
    image_directory_name="${IMAGE_NAME}-${IMAGE_VERSION}"
    if [[ -n "${BUILD_VENTOY_DIR}" ]]; then
        OUTPUT_DIR=${BUILD_VENTOY_DIR}
        BUILD_DESTINATION_KIND=ventoy
        check_active_build_destination "antes da preparação" || return 1
        check_free_space "${OUTPUT_DIR}" "${MIN_FREE_SPACE_GIB}" || return 1
    elif [[ -n "${BUILD_NFS_DIR}" ]]; then
        [[ "${BUILD_NFS_DIR}" == /* ]] || {
            ui_error "O destino NFS deve ser um caminho absoluto: ${BUILD_NFS_DIR}"
            return 1
        }
        OUTPUT_DIR="$(realpath -e -- "${BUILD_NFS_DIR}")" || {
            ui_error "Diretório NFS inexistente: ${BUILD_NFS_DIR}"
            return 1
        }
        BUILD_DESTINATION_KIND=nfs
        check_nfs_staging_filesystem "${OUTPUT_DIR}" || return 1
        check_free_space "${OUTPUT_DIR}" "${MIN_FREE_SPACE_GIB}" || return 1
    else
        OUTPUT_DIR="$(resolve_project_path "${PROJECT_DIR}" "${OUTPUT_DIR}")"
        prepare_directories "${OUTPUT_DIR}" "${LOG_DIR}" || return 1
        check_local_staging_filesystem "${OUTPUT_DIR}" || return 1
        check_free_space "${OUTPUT_DIR}" "${MIN_FREE_SPACE_GIB}" || return 1
    fi

    prepare_local_temporary_directory "${LOCAL_TEMP_DIR}" LOCAL_TEMP_DIR_RESOLVED || return 1
    estimate_homefs_staging_size_mib "${HOME_SOURCE}" home_staging_estimate_mib || return 1
    (( home_staging_estimate_mib <= HOMEFS_MAX_SIZE_MIB )) || {
        ui_error "Conteúdo selecionado da home excede HOMEFS_MAX_SIZE_MIB: ${home_staging_estimate_mib} MiB"
        return 1
    }
    local_required_mib=$(( home_staging_estimate_mib + ${LOCAL_TEMP_RESERVE_MIB:-64} ))
    check_free_space_mib "${LOCAL_TEMP_DIR_RESOLVED}" "${local_required_mib}" || return 1
    readonly OUTPUT_DIR LOG_DIR LOCAL_TEMP_DIR_RESOLVED

    check_active_build_destination "antes da criação do staging" || return 1
    prepare_build_workspace "${OUTPUT_DIR}" "${image_directory_name}" \
        BUILD_WORKSPACE LOCAL_IMAGE_DIR || return 1
    BUILD_DIR="${BUILD_WORKSPACE}"
    readonly ROOTFS_FILE="${BUILD_DIR}/${ROOTFS_FILENAME}"
    readonly HOMEFS_FILE="${BUILD_DIR}/${HOMEFS_FILENAME}"
    readonly CHECKSUM_FILE="${BUILD_DIR}/SHA256SUMS"
    readonly MANIFEST_FILE="${BUILD_DIR}/manifest.json"

    log_write INFO "Staging do build: ${BUILD_DIR}"
    log_write INFO "Destino do build: ${BUILD_DESTINATION_KIND}"
    log_write INFO "Imagem final após commit: ${LOCAL_IMAGE_DIR}"
    log_write INFO "Temporários locais: ${LOCAL_TEMP_DIR_RESOLVED} (${local_required_mib} MiB mínimos)"
    ui_info "Gerando ${ROOTFS_FILE}"
    log_write INFO "A captura é feita com o sistema ativo e pode refletir alterações concorrentes."
    log_write INFO "Identidades da máquina-modelo serão removidas do rootfs."
    if [[ "${IMAGE_COMPRESSION}" == zstd ]]; then
        log_write INFO "Compressão: zstd; nível: ${ZSTD_LEVEL}"
    else
        log_write INFO "Compressão: gzip; nível padrão do GNU tar"
    fi
    preparation_seconds=$(( SECONDS - START_TIME ))

    build_rootfs_artifact "${SOURCE_ROOT}" "${OUTPUT_DIR}" "${ROOTFS_FILE}" \
        "${IMAGE_COMPRESSION}" "${ZSTD_LEVEL}" "${LOCAL_TEMP_DIR_RESOLVED}" || return 1
    check_active_build_destination "durante a geração do rootfs" || return 1

    detect_home_identity "${HOME_SOURCE}" "${HOME_USER}" home_uid home_gid || return 1
    ui_info "Gerando ${HOMEFS_FILE}"
    build_homefs_artifact "${HOME_SOURCE}" "${HOME_USER}" "${home_uid}" "${home_gid}" \
        "${HOMEFS_MAX_SIZE_MIB}" "${BUILD_DIR}" "${HOMEFS_FILE}" \
        "${IMAGE_COMPRESSION}" "${ZSTD_LEVEL}" "${LOCAL_TEMP_DIR_RESOLVED}" || return 1
    check_active_build_destination "durante a geração do homefs" || return 1

    metadata_start=${SECONDS}
    build_metadata_artifacts "${BUILD_DIR}" "${ROOTFS_FILE}" "${HOMEFS_FILE}" \
        "${CHECKSUM_FILE}" "${MANIFEST_FILE}" "${IMAGE_NAME}" "${IMAGE_VERSION}" \
        "${builder_version}" "${IMAGE_COMPRESSION}" "${SOURCE_ROOT}" || return 1
    metadata_seconds=$(( SECONDS - metadata_start ))

    validate_image_directory "${BUILD_DIR}" || return 1
    check_active_build_destination "antes da publicação final" || return 1

    cleanup_detected_capture_source || return 1

    rootfs_size="$(format_file_size "${ROOTFS_FILE}")"
    homefs_size="$(format_file_size "${HOMEFS_FILE}")"
    check_active_build_destination "imediatamente antes do commit" || return 1
    finalize_build_workspace "${BUILD_WORKSPACE}" "${LOCAL_IMAGE_DIR}" || return 1
    check_active_build_destination "durante a publicação final" || return 1
    BUILD_WORKSPACE=""
    elapsed="$(( SECONDS - START_TIME ))"
    BUILD_SUCCEEDED=true

    log_write SUCCESS "Imagem ${BUILD_DESTINATION_KIND} publicada após validação completa: ${LOCAL_IMAGE_DIR}"
    log_write INFO "Tamanho rootfs: ${rootfs_size}; tamanho homefs: ${homefs_size}"
    log_write INFO "Tempos: preparação=${preparation_seconds}s; rootfs_geração=${ROOTFS_GENERATE_SECONDS}s; rootfs_validação=${ROOTFS_VALIDATE_SECONDS}s; homefs_geração=${HOMEFS_GENERATE_SECONDS}s; homefs_validação=${HOMEFS_VALIDATE_SECONDS}s; metadata=${metadata_seconds}s; total=${elapsed}s"
    ui_success "Build concluído"
    printf 'Rootfs: %s (%s)\nHomefs: %s (%s)\nTempos do build:\n  Preparação: %ss\n  Rootfs: %ss (geração %ss, validação %ss)\n  Homefs: %ss (geração %ss, validação %ss)\n  Metadata: %ss\n  Total: %ss\nLog: %s\n' \
        "${LOCAL_IMAGE_DIR}/${ROOTFS_FILENAME}" "${rootfs_size}" \
        "${LOCAL_IMAGE_DIR}/${HOMEFS_FILENAME}" "${homefs_size}" \
        "${preparation_seconds}" "$(( ROOTFS_GENERATE_SECONDS + ROOTFS_VALIDATE_SECONDS ))" \
        "${ROOTFS_GENERATE_SECONDS}" "${ROOTFS_VALIDATE_SECONDS}" \
        "$(( HOMEFS_GENERATE_SECONDS + HOMEFS_VALIDATE_SECONDS ))" \
        "${HOMEFS_GENERATE_SECONDS}" "${HOMEFS_VALIDATE_SECONDS}" \
        "${metadata_seconds}" "${elapsed}" "${LOG_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
