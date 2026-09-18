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
# Reutiliza a mesma cópia validada/atômica do sincronizador independente.
# shellcheck source=lib/sync_ventoy.sh
source "${PROJECT_DIR}/lib/sync_ventoy.sh"

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
BUILD_ALSO_VENTOY_DIR=""
BUILD_VENTOY_COPY_IMAGE=""
BUILD_VENTOY_COPY_STAGING=""
BUILD_VENTOY_COPY_SUCCEEDED=false
BUILD_VENTOY_COPY_SELECTED_INTERACTIVELY=false
BUILD_DUAL_NFS_DIR=""
BUILD_DUAL_NFS_RECORD=""
BUILD_DESTINATION_KIND="local"
IMAGE_VERSION_SOURCE="config/image.conf"
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

    if [[ -n "${BUILD_VENTOY_COPY_STAGING:-}" ]]; then
        cleanup_ventoy_sync_staging "${BUILD_VENTOY_COPY_STAGING}" \
            "${VENTOY_DESTINATION:-}" "${BUILD_VENTOY_COPY_IMAGE:-}" || {
                [[ ${exit_code} -ne 0 ]] || exit_code=1
            }
        BUILD_VENTOY_COPY_STAGING=""
    fi
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
        elif [[ -n "${BUILD_ALSO_VENTOY_DIR}" ]] && ! dual_build_nfs_unchanged; then
            ui_warn "Staging NFS não removido: identidade do mount do build duplo mudou ou não pôde ser confirmada."
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
    cleanup_ventoy_mount
    cleanup_nfs_mount

    if [[ ${exit_code} -ne 0 && "${BUILD_SUCCEEDED}" == true &&
          -n "${BUILD_ALSO_VENTOY_DIR}" && "${BUILD_VENTOY_COPY_SUCCEEDED}" != true ]]; then
        ui_error "Imagem válida preservada no NFS: ${LOCAL_IMAGE_DIR}"
        ui_error "Cópia para o Ventoy não concluída (código ${exit_code}). Repita somente a sincronização, sem recapturar esta versão."
    elif [[ "${BUILD_SUCCEEDED}" != true && ${exit_code} -ne 0 ]]; then
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
    if [[ "${VENTOY_MOUNT_IN_PROGRESS}" == 1 ]]; then
        VENTOY_PENDING_SIGNAL=${signal}
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
                       [--also-ventoy-dir DIRETÓRIO]

Em terminal interativo, pergunta o sufixo/versão da nova imagem antes de montar
destinos ou capturar arquivos. Aceita '0.3.0' ou 'pmjs-linux-0.3.0' (com o prefixo
IMAGE_NAME configurado); Enter mantém o padrão de config/image.conf.
Sem terminal interativo, mantém nome/versão da configuração, sem ler stdin.
Em terminal e com destino NFS, também oferece a cópia para o Ventoy [S/n].
VENTOY_AUTOMOUNT_ENABLED=1 detecta/monta a mídia configurada automaticamente;
com 0/ausente pede o caminho manual. O lançador da Live usa esse fluxo.
--also-ventoy-dir auto e --ventoy-dir auto habilitam descoberta explicitamente.

Com --also-ventoy-dir, exige build NFS (automático ou --nfs-dir) e depois copia
o bundle final para o pmjs-images informado. NFS e Ventoy são validados e
publicados separadamente; se a cópia falhar, o NFS válido permanece e o comando
retorna erro. Não pode ser combinado com --ventoy-dir.

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

select_build_image_version() {
    local entered_version
    IMAGE_VERSION_SOURCE="config/image.conf"
    # Preserve execuções automatizadas e stdin redirecionado: nunca consumir
    # dados de um pipe, nem abrir /dev/tty para forçar uma pergunta.
    [[ -t 0 ]] || return 0

    ui_info "Nome da nova imagem: ${IMAGE_NAME}-<versão/sufixo>"
    while true; do
        if ! read -r -p "Versão/sufixo ou nome completo [${IMAGE_NAME}-${IMAGE_VERSION}]: " entered_version; then
            ui_error "Seleção da imagem cancelada; build não iniciado."
            return 1
        fi
        [[ -n "${entered_version}" ]] || break
        # O prefixo continua sendo IMAGE_NAME; não confundir a versão do
        # artefato com a versão do programa em VERSION.
        entered_version=${entered_version#"${IMAGE_NAME}-"}
        if [[ ! "${entered_version}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
            ui_error "Versão/sufixo inválido: use letras, números, ponto, hífen ou underscore; comece com letra ou número."
            continue
        fi
        IMAGE_VERSION=${entered_version}
        IMAGE_VERSION_SOURCE="seleção interativa"
        break
    done
    ui_info "Imagem selecionada: ${IMAGE_NAME}-${IMAGE_VERSION}"
}

select_interactive_ventoy_copy() {
    local answer requested_dir
    [[ -t 0 ]] || return 0
    # Opções explícitas vencem a pergunta. Build local/direto no Ventoy não
    # deve começar a acessar o servidor só por estar em um terminal.
    [[ -z "${BUILD_VENTOY_DIR}" && -z "${BUILD_ALSO_VENTOY_DIR}" ]] || return 0
    [[ -n "${BUILD_NFS_DIR}" || "${NFS_ENABLED:-0}" == 1 ||
       ( "${NFS_ENABLED:-0}" == 0 && -n "${NFS_IMAGES_DIR:-}" ) ]] || return 0

    while true; do
        if ! read -r -p "Copiar também para o Ventoy após publicar no NFS? [S/n]: " answer; then
            ui_error "Seleção dos destinos cancelada; build não iniciado."
            return 1
        fi
        case "${answer}" in
            ''|s|S|sim|Sim|SIM|y|Y|yes|Yes|YES) break ;;
            n|N|nao|não|Nao|Não|NAO|NÃO|no|No|NO)
                ui_info "Destino selecionado: somente NFS"
                return 0 ;;
            *) ui_error "Responda S para NFS + Ventoy ou N para somente NFS." ;;
        esac
    done
    case "${VENTOY_AUTOMOUNT_ENABLED:-0}" in
        1)
            BUILD_ALSO_VENTOY_DIR=auto
            ui_info "Destinos selecionados: NFS + Ventoy automático (config/image.conf)"
            return 0 ;;
        0) : ;;
        *) ui_error "VENTOY_AUTOMOUNT_ENABLED deve ser 0 ou 1"; return 1 ;;
    esac
    check_ventoy_dependencies || return 1
    ui_info "Informe a pasta pmjs-images da mídia Ventoy já montada; nenhum caminho será presumido."
    while true; do
        if ! read -r -p "Diretório pmjs-images do Ventoy: " requested_dir; then
            ui_error "Seleção dos destinos cancelada; build não iniciado."
            return 1
        fi
        if [[ -z "${requested_dir}" ]]; then
            ui_error "O caminho do Ventoy é obrigatório; Ctrl+D cancela o build."
            continue
        fi
        # Somente leitura neste estágio; nada de mkdir ou mounts reais antes
        # de o operador concluir as escolhas. O preflight reconfirma depois.
        if ! validate_ventoy_sync_destination "${requested_dir}"; then
            continue
        fi
        BUILD_ALSO_VENTOY_DIR=${VENTOY_DESTINATION}
        BUILD_VENTOY_COPY_SELECTED_INTERACTIVELY=true
        ui_info "Destinos selecionados: NFS + Ventoy (${BUILD_ALSO_VENTOY_DIR})"
        return 0
    done
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
            --also-ventoy-dir)
                (( $# >= 2 )) || { ui_error "Valor ausente para --also-ventoy-dir"; return 1; }
                [[ -n "$2" ]] || { ui_error "Valor vazio para --also-ventoy-dir"; return 1; }
                [[ -z "${BUILD_ALSO_VENTOY_DIR}" ]] || {
                    ui_error "--also-ventoy-dir foi informado mais de uma vez"
                    return 1
                }
                BUILD_ALSO_VENTOY_DIR=$2
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
    [[ -z "${BUILD_ALSO_VENTOY_DIR}" || -z "${BUILD_VENTOY_DIR}" ]] || {
        ui_error "--also-ventoy-dir não pode ser combinado com --ventoy-dir; use build NFS como destino principal"
        return 1
    }
}

read_dual_build_nfs_identity() {
    local record mount_id source filesystem target extra
    [[ -n "${BUILD_DUAL_NFS_DIR}" &&
       "$(realpath -e -- "${BUILD_DUAL_NFS_DIR}")" == "${BUILD_DUAL_NFS_DIR}" ]] || return 1
    record="$(findmnt --noheadings --raw --target "${BUILD_DUAL_NFS_DIR}" \
        --output ID,SOURCE,FSTYPE,TARGET)" || return 1
    [[ -n "${record}" && "${record}" != *$'\n'* ]] || return 1
    read -r mount_id source filesystem target extra <<< "${record}"
    [[ "${mount_id}" =~ ^[0-9]+$ && -n "${source}" && -z "${extra}" &&
       ( "${filesystem}" == nfs || "${filesystem}" == nfs4 ) &&
       "${target}" == /* &&
       ( "${BUILD_DUAL_NFS_DIR}" == "${target}" ||
         "${BUILD_DUAL_NFS_DIR}" == "${target}/"* ) ]] || return 1
    printf '%s\n' "${record}"
}

dual_build_nfs_unchanged() {
    local current_record
    [[ -n "${BUILD_DUAL_NFS_RECORD}" ]] || return 1
    current_record="$(read_dual_build_nfs_identity)" || return 1
    [[ "${current_record}" == "${BUILD_DUAL_NFS_RECORD}" ]]
}

prepare_build_ventoy_copy() {
    [[ -n "${BUILD_ALSO_VENTOY_DIR}" ]] || return 0
    [[ -n "${BUILD_NFS_DIR}" && -z "${BUILD_VENTOY_DIR}" ]] || {
        ui_error "--also-ventoy-dir exige NFS como destino principal; build não iniciado"
        return 1
    }
    BUILD_DUAL_NFS_DIR="$(realpath -e -- "${BUILD_NFS_DIR}")" || return 1
    BUILD_DUAL_NFS_RECORD="$(read_dual_build_nfs_identity)" || {
        ui_error "findmnt não confirmou o destino NFS do build duplo; build não iniciado"
        return 1
    }
    BUILD_VENTOY_COPY_IMAGE="${IMAGE_NAME}-${IMAGE_VERSION}"
    validate_sync_image_name "${BUILD_VENTOY_COPY_IMAGE}" "${IMAGE_NAME}" || return 1
    check_ventoy_dependencies || return 1
    if [[ "${BUILD_ALSO_VENTOY_DIR}" == auto ]]; then
        prepare_ventoy_automount || return 1
    elif [[ "${BUILD_VENTOY_COPY_SELECTED_INTERACTIVELY}" == true ]]; then
        # Manter a identidade confirmada durante a pergunta, sem substituí-la
        # por outra mídia que apareceu no mesmo caminho durante o mount NFS.
        [[ "${BUILD_ALSO_VENTOY_DIR}" == "${VENTOY_DESTINATION}" &&
           -d "${VENTOY_DESTINATION}" && -w "${VENTOY_DESTINATION}" ]] &&
            ventoy_mount_unchanged || {
                ui_error "O mount do Ventoy mudou após a seleção interativa; build não iniciado"
                return 1
            }
    else
        validate_ventoy_sync_destination "${BUILD_ALSO_VENTOY_DIR}" || return 1
    fi
    [[ "${VENTOY_MOUNT_ID}" != "${BUILD_DUAL_NFS_RECORD%% *}" &&
       "${VENTOY_MOUNT_FSTYPE}" != nfs && "${VENTOY_MOUNT_FSTYPE}" != nfs4 ]] || {
        ui_error "O destino offline deve estar em uma mídia separada do NFS"
        return 1
    }
    [[ ! -e "${VENTOY_DESTINATION}/${BUILD_VENTOY_COPY_IMAGE}" &&
       ! -L "${VENTOY_DESTINATION}/${BUILD_VENTOY_COPY_IMAGE}" ]] || {
        ui_error "A versão já existe no Ventoy e não será substituída; build não iniciado"
        return 1
    }
    # O tamanho real só é conhecido depois do build; conferir a margem agora
    # e imagem + margem novamente antes de criar o staging da cópia.
    check_ventoy_free_space "${VENTOY_DESTINATION}" 0 \
        "${VENTOY_FREE_SPACE_MARGIN_MIB:-64}" || return 1
    BUILD_ALSO_VENTOY_DIR=${VENTOY_DESTINATION}
}

copy_built_image_to_ventoy() {
    local image_bytes resolved_source
    [[ -n "${BUILD_ALSO_VENTOY_DIR}" ]] || return 0
    resolved_source="$(realpath -e -- "${LOCAL_IMAGE_DIR}")" || return 1
    [[ "${BUILD_SUCCEEDED}" == true && "${BUILD_DESTINATION_KIND}" == nfs &&
       "${resolved_source}" == "${BUILD_DUAL_NFS_DIR}/${BUILD_VENTOY_COPY_IMAGE}" &&
       "${LOCAL_IMAGE_DIR}" == "${resolved_source}" && ! -L "${LOCAL_IMAGE_DIR}" ]] || {
        ui_error "Cópia recusada: é necessário um bundle final publicado pelo build NFS"
        return 1
    }
    dual_build_nfs_unchanged || { ui_error "O mount NFS mudou antes da cópia"; return 1; }
    ui_info "Validando bundle final no NFS antes da cópia offline..."
    validate_image_directory "${LOCAL_IMAGE_DIR}" || return 1
    dual_build_nfs_unchanged || { ui_error "O mount NFS mudou durante a validação"; return 1; }
    image_bundle_size_bytes "${LOCAL_IMAGE_DIR}" image_bytes || return 1
    check_ventoy_free_space "${VENTOY_DESTINATION}" "${image_bytes}" \
        "${VENTOY_FREE_SPACE_MARGIN_MIB:-64}" || return 1
    prepare_ventoy_sync_staging "${VENTOY_DESTINATION}" "${BUILD_VENTOY_COPY_IMAGE}" \
        BUILD_VENTOY_COPY_STAGING || return 1
    copy_image_to_ventoy_staging "${LOCAL_IMAGE_DIR}" "${BUILD_VENTOY_COPY_STAGING}" || return 1
    dual_build_nfs_unchanged || { ui_error "O mount NFS mudou durante a cópia"; return 1; }
    validate_copied_ventoy_bundle "${BUILD_VENTOY_COPY_STAGING}" || return 1
    dual_build_nfs_unchanged || { ui_error "O mount NFS mudou antes do commit offline"; return 1; }
    commit_ventoy_sync "${BUILD_VENTOY_COPY_STAGING}" "${VENTOY_DESTINATION}" \
        "${BUILD_VENTOY_COPY_IMAGE}" || return 1
    BUILD_VENTOY_COPY_STAGING=""
    BUILD_VENTOY_COPY_SUCCEEDED=true
    ui_success "Imagem copiada para o Ventoy"
    printf 'NFS: %s\nVentoy: %s/%s\nSHA256: OK nos dois destinos\n' \
        "${LOCAL_IMAGE_DIR}" "${VENTOY_DESTINATION}" "${BUILD_VENTOY_COPY_IMAGE}"
}

check_active_build_destination() {
    local phase=$1
    if [[ "${BUILD_DESTINATION_KIND}" == ventoy ]] && ! ventoy_mount_unchanged; then
        ui_error "O mount do Ventoy mudou ${phase}; build interrompido"
        return 1
    fi
    if [[ -n "${BUILD_ALSO_VENTOY_DIR}" ]] && ! dual_build_nfs_unchanged; then
        ui_error "O mount NFS mudou ${phase}; build duplo interrompido"
        return 1
    fi
}

select_build_destination() {
    if [[ -n "${BUILD_VENTOY_DIR}" ]]; then
        check_ventoy_dependencies || { ui_error "Build não iniciado."; return 1; }
        if [[ "${BUILD_VENTOY_DIR}" == auto ]]; then
            prepare_ventoy_automount || { ui_error "Build não iniciado."; return 1; }
        elif ! validate_ventoy_destination "${BUILD_VENTOY_DIR}"; then
            ui_error "Build não iniciado."
            return 1
        fi
        BUILD_VENTOY_DIR=${VENTOY_DESTINATION}
    elif ! select_build_nfs_destination; then
        ui_error "Build não iniciado."
        return 1
    fi
    prepare_build_ventoy_copy || { ui_error "Build não iniciado."; return 1; }
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
    select_build_image_version || return 1
    validate_config
    select_interactive_ventoy_copy || return 1
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
    log_write INFO "Versões independentes: builder=${builder_version} (VERSION), imagem=${IMAGE_VERSION} (${IMAGE_VERSION_SOURCE})"

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
    BUILD_SUCCEEDED=true

    log_write SUCCESS "Imagem ${BUILD_DESTINATION_KIND} publicada após validação completa: ${LOCAL_IMAGE_DIR}"
    copy_built_image_to_ventoy || return 1
    elapsed="$(( SECONDS - START_TIME ))"
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
