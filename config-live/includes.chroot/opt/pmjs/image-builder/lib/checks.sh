#!/usr/bin/env bash

check_config_file() {
    local config_file=$1
    [[ -r "${config_file}" ]] || { ui_error "Configuração não encontrada ou ilegível: ${config_file}"; return 1; }
}

validate_config() {
    local variable
    local required=(IMAGE_NAME IMAGE_VERSION OUTPUT_DIR LOG_DIR ROOTFS_FILENAME HOMEFS_FILENAME SOURCE_ROOT HOME_SOURCE HOME_USER IMAGE_COMPRESSION ZSTD_LEVEL MIN_FREE_SPACE_GIB HOMEFS_MAX_SIZE_MIB)
    for variable in "${required[@]}"; do
        [[ -n "${!variable:-}" ]] || { ui_error "Configuração obrigatória ausente: ${variable}"; return 1; }
    done
    [[ "${IMAGE_COMPRESSION}" == zstd ]] || { ui_error "O formato PMJS publicado exige IMAGE_COMPRESSION='zstd'."; return 1; }
    [[ "${ZSTD_LEVEL}" =~ ^[1-9][0-9]*$ && ${ZSTD_LEVEL} -le 19 ]] || { ui_error "ZSTD_LEVEL deve estar entre 1 e 19."; return 1; }
    [[ "${ROOTFS_FILENAME}" == auto ]] || { ui_error "ROOTFS_FILENAME deve ser 'auto'."; return 1; }
    [[ "${HOMEFS_FILENAME}" == auto ]] || { ui_error "HOMEFS_FILENAME deve ser 'auto'."; return 1; }
    [[ "${MIN_FREE_SPACE_GIB}" =~ ^[0-9]+$ ]] || { ui_error "MIN_FREE_SPACE_GIB deve ser um inteiro não negativo."; return 1; }
    [[ "${HOMEFS_MAX_SIZE_MIB}" =~ ^[1-9][0-9]*$ ]] || { ui_error "HOMEFS_MAX_SIZE_MIB deve ser um inteiro positivo."; return 1; }
    [[ "${LOCAL_TEMP_RESERVE_MIB:-64}" =~ ^[0-9]+$ ]] || { ui_error "LOCAL_TEMP_RESERVE_MIB deve ser um inteiro não negativo."; return 1; }
    [[ "${HOME_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { ui_error "HOME_USER contém caracteres inválidos."; return 1; }
    if [[ "${SOURCE_ROOT}" == auto || "${HOME_SOURCE}" == auto ]]; then
        [[ "${SOURCE_ROOT}" == auto && "${HOME_SOURCE}" == auto ]] || { ui_error "SOURCE_ROOT e HOME_SOURCE devem usar 'auto' juntos."; return 1; }
    fi
    [[ "${IMAGE_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { ui_error "IMAGE_NAME contém caracteres inválidos."; return 1; }
    [[ "${IMAGE_VERSION}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { ui_error "IMAGE_VERSION contém caracteres inválidos."; return 1; }
}

load_builder_version() {
    local version_file=$1
    local -n version_ref=$2
    local file_version

    [[ -r "${version_file}" ]] || { ui_error "Arquivo VERSION não encontrado: ${version_file}"; return 1; }
    file_version="$(tr -d '[:space:]' < "${version_file}")"
    [[ "${file_version}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || {
        ui_error "Versão inválida do Image Builder em VERSION: ${file_version:-vazia}"
        return 1
    }
    version_ref=${file_version}
}

resolve_project_path() {
    local project_dir=$1 configured_path=$2
    if [[ "${configured_path}" == /* ]]; then realpath -m -- "${configured_path}"; else realpath -m -- "${project_dir}/${configured_path}"; fi
}

check_root() {
    (( EUID == 0 )) || { ui_error "Execute o build como root."; return 1; }
}

check_dependencies() {
    local command tar_version
    local dependencies=(tar gzip zstd rsync stat du df realpath readlink getent id date mkdir mktemp install chmod find dirname basename mv rm tr tail awk grep lsblk blkid mount umount sha256sum python3 wc uname sort sync)
    for command in "${dependencies[@]}"; do
        command -v "${command}" >/dev/null 2>&1 || { ui_error "Dependência ausente: ${command}"; return 1; }
    done
    tar_version="$(tar --version)"
    [[ "${tar_version}" == *"GNU tar"* ]] || { ui_error "GNU tar é obrigatório para ACLs e atributos estendidos."; return 1; }
}

check_compression_dependency() {
    local compression=$1
    if [[ "${compression}" == zstd ]]; then
        command -v zstd >/dev/null 2>&1 || {
            ui_error "Compressão zstd selecionada, mas o binário 'zstd' não está instalado."
            return 1
        }
    fi
}

source_root_has_linux_layout() {
    local candidate=$1
    [[ -d "${candidate}/etc" && -d "${candidate}/usr" && -d "${candidate}/var" ]]
}

resolve_source_root() {
    local configured_root=$1
    local -n resolved_ref=$2
    local candidate rootfs_subvolume

    [[ "${configured_root}" == /* ]] || {
        ui_error "SOURCE_ROOT deve ser um caminho absoluto: ${configured_root}"
        return 1
    }
    candidate="$(realpath -e -- "${configured_root}")" || {
        ui_error "SOURCE_ROOT inexistente: ${configured_root}"
        return 1
    }
    [[ -d "${candidate}" && -r "${candidate}" ]] || {
        ui_error "Raiz de origem inválida: ${candidate}"
        return 1
    }

    if source_root_has_linux_layout "${candidate}"; then
        resolved_ref="${candidate}"
        return 0
    fi

    rootfs_subvolume="${candidate}/@rootfs"
    if [[ -d "${rootfs_subvolume}" && ! -L "${rootfs_subvolume}" ]] &&
       source_root_has_linux_layout "${rootfs_subvolume}"; then
        resolved_ref="$(realpath -e -- "${rootfs_subvolume}")"
        return 0
    fi

    ui_error "Nenhuma raiz Linux válida encontrada em ${candidate} ou ${rootfs_subvolume}"
    return 1
}

check_source_root() {
    local source_root=$1
    [[ -d "${source_root}" && -r "${source_root}" ]] || {
        ui_error "Raiz de origem inválida: ${source_root}"
        return 1
    }
    source_root_has_linux_layout "${source_root}" || {
        ui_error "Layout Linux incompleto em SOURCE_ROOT: ${source_root}"
        return 1
    }
}

prepare_directories() {
    local output_dir=$1 log_dir=$2
    mkdir -p -- "${output_dir}" "${log_dir}"
    [[ -d "${output_dir}" && -w "${output_dir}" ]] || { ui_error "Diretório de saída não gravável: ${output_dir}"; return 1; }
    [[ -d "${log_dir}" && -w "${log_dir}" ]] || { ui_error "Diretório de logs não gravável: ${log_dir}"; return 1; }
}

prepare_build_directory() {
    local build_dir=$1
    mkdir -p -- "${build_dir}"
    [[ -d "${build_dir}" && -w "${build_dir}" ]] || { ui_error "Diretório do build não gravável: ${build_dir}"; return 1; }
}

check_destination_filesystem() {
    local source_root=$1 destination=$2 source_device destination_device
    source_device="$(stat -c '%d' -- "${source_root}")"
    destination_device="$(stat -c '%d' -- "${destination}")"
    [[ "${source_device}" != "${destination_device}" ]] || { ui_error "O destino (${destination}) está no mesmo filesystem da raiz (${source_root}). Monte OUTPUT_DIR em outro filesystem."; return 1; }
    log_write INFO "Filesystem validado: raiz=${source_device}, destino=${destination_device}"
}

check_local_staging_filesystem() {
    local staging_dir=$1 filesystem

    filesystem="$(stat --file-system --format='%T' -- "${staging_dir}")"
    case "${filesystem}" in
        nfs|nfs4|cifs|smb3|9p|fuse*|exfat|vfat|msdos|ntfs)
            ui_error "O staging local deve usar filesystem Linux; detectado ${filesystem}: ${staging_dir}"
            return 1
            ;;
    esac
    if declare -F log_write >/dev/null; then
        log_write INFO "Staging local validado: ${staging_dir} (${filesystem})"
    fi
}

check_nfs_staging_filesystem() {
    local staging_dir=$1 filesystem mount_target

    [[ "${staging_dir}" == /* ]] || {
        ui_error "NFS_IMAGES_DIR deve ser um caminho absoluto: ${staging_dir}"
        return 1
    }
    [[ -d "${staging_dir}" && ! -L "${staging_dir}" && -w "${staging_dir}" ]] || {
        ui_error "NFS_IMAGES_DIR deve ser um diretório real e gravável: ${staging_dir}"
        return 1
    }
    filesystem="$(findmnt --noheadings --output FSTYPE --target "${staging_dir}" | awk 'NR == 1 { print $1 }')"
    mount_target="$(findmnt --noheadings --output TARGET --target "${staging_dir}" | awk 'NR == 1 { print $1 }')"
    [[ "${filesystem}" == nfs || "${filesystem}" == nfs4 ]] || {
        ui_error "NFS_IMAGES_DIR não está em um filesystem NFS montado: ${staging_dir} (${filesystem:-desconhecido})"
        return 1
    }
    [[ -n "${mount_target}" ]] || {
        ui_error "Não foi possível identificar o mountpoint NFS de ${staging_dir}"
        return 1
    }
    if declare -F log_write >/dev/null; then
        log_write INFO "Staging NFS validado: ${staging_dir} (${filesystem}, mount ${mount_target})"
    fi
}

prepare_local_temporary_directory() {
    local configured_dir=$1
    local -n resolved_ref=$2

    [[ "${configured_dir}" == /* ]] || {
        ui_error "LOCAL_TEMP_DIR deve ser um caminho absoluto: ${configured_dir}"
        return 1
    }
    mkdir -p -- "${configured_dir}"
    resolved_ref="$(realpath -e -- "${configured_dir}")" || {
        ui_error "Não foi possível resolver LOCAL_TEMP_DIR: ${configured_dir}"
        return 1
    }
    [[ -d "${resolved_ref}" && ! -L "${configured_dir}" && -w "${resolved_ref}" ]] || {
        ui_error "LOCAL_TEMP_DIR deve ser um diretório local real e gravável: ${configured_dir}"
        return 1
    }
    check_local_staging_filesystem "${resolved_ref}"
}

prepare_build_workspace() {
    local output_dir=$1 image_directory_name=$2
    local -n workspace_ref=$3 final_ref=$4

    final_ref="${output_dir}/${image_directory_name}"
    [[ ! -e "${final_ref}" && ! -L "${final_ref}" ]] || {
        ui_error "A versão local já existe e não será substituída: ${final_ref}"
        return 1
    }
    workspace_ref="$(mktemp --directory --tmpdir="${output_dir}" \
        ".${image_directory_name}.build.XXXXXX")" || {
        ui_error "Não foi possível criar o staging do build em ${output_dir}"
        return 1
    }
}

cleanup_build_workspace() {
    local workspace=$1 output_dir=$2 resolved_workspace

    [[ -n "${workspace}" && -e "${workspace}" ]] || return 0
    resolved_workspace="$(realpath -m -- "${workspace}")"
    [[ "$(dirname -- "${resolved_workspace}")" == "${output_dir}" &&
       "$(basename -- "${resolved_workspace}")" == .*.build.* &&
       -d "${resolved_workspace}" && ! -L "${resolved_workspace}" ]] || {
        ui_error "Recusa ao limpar staging de build inesperado: ${workspace}"
        return 1
    }
    find -P "${resolved_workspace}" -depth -delete
}

finalize_build_workspace() {
    local workspace=$1 final_dir=$2

    [[ -d "${workspace}" && ! -L "${workspace}" &&
       "$(dirname -- "${workspace}")" == "$(dirname -- "${final_dir}")" &&
       "$(basename -- "${workspace}")" == .*.build.* &&
       ! -e "${final_dir}" && ! -L "${final_dir}" ]] || {
        ui_error "Staging local inseguro ou versão já existente: ${workspace}"
        return 1
    }
    sync --file-system "${workspace}/manifest.json"
    mv -T --no-clobber -- "${workspace}" "${final_dir}"
    [[ ! -e "${workspace}" && -d "${final_dir}" ]] || {
        ui_error "A versão local surgiu durante o build e não foi substituída: ${final_dir}"
        return 1
    }
    sync --file-system "${final_dir}/manifest.json"
}

check_free_space() {
    local destination=$1 minimum_gib=$2 available_bytes minimum_bytes
    available_bytes="$(df --output=avail -B1 -- "${destination}" | tail -n 1 | tr -d '[:space:]')"
    minimum_bytes=$(( minimum_gib * 1024 * 1024 * 1024 ))
    (( available_bytes >= minimum_bytes )) || { ui_error "Espaço insuficiente em ${destination}: mínimo de ${minimum_gib} GiB."; return 1; }
    log_write INFO "Espaço livre validado: ${available_bytes} bytes disponíveis"
}

check_free_space_mib() {
    local destination=$1 minimum_mib=$2 available_bytes minimum_bytes

    available_bytes="$(df --output=avail -B1 -- "${destination}" | tail -n 1 | tr -d '[:space:]')"
    minimum_bytes=$(( minimum_mib * 1024 * 1024 ))
    (( available_bytes >= minimum_bytes )) || {
        ui_error "Espaço local insuficiente em ${destination}: mínimo de ${minimum_mib} MiB para temporários."
        return 1
    }
    log_write INFO "Espaço local para temporários validado: ${available_bytes} bytes disponíveis; mínimo ${minimum_mib} MiB"
}
