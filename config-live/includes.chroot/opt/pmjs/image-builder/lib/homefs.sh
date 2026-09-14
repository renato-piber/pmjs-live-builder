#!/usr/bin/env bash

readonly -a HOMEFS_WHITELIST=(
    .config/autostart
    .config/dconf
    .config/mate
    .config/menus
    .config/caja
    .config/pluma
    .config/vlc
    .local/share/applications
)

readonly -a HOMEFS_XDG_SPECS=(
    'DESKTOP:Desktop'
    'DOCUMENTS:Documentos'
    'DOWNLOAD:Downloads'
    'PICTURES:Imagens'
    'MUSIC:Música'
    'VIDEOS:Vídeos'
    'PUBLICSHARE:Público'
    'TEMPLATES:Modelos'
)

detect_home_identity() {
    local home_source=$1
    local home_user=$2
    local -n uid_ref=$3
    local -n gid_ref=$4

    [[ -d "${home_source}" && -r "${home_source}" ]] || {
        ui_error "HOME_SOURCE inexistente ou ilegível: ${home_source}"
        return 1
    }
    [[ "$(basename -- "${home_source}")" == "${home_user}" ]] || {
        ui_error "HOME_SOURCE deve terminar com HOME_USER (${home_user})"
        return 1
    }
    getent passwd "${home_user}" >/dev/null || {
        ui_error "Usuário não encontrado: ${home_user}"
        return 1
    }
    uid_ref="$(id -u -- "${home_user}")"
    gid_ref="$(id -g -- "${home_user}")"
    [[ "${uid_ref}" =~ ^[0-9]+$ && "${gid_ref}" =~ ^[0-9]+$ ]] || {
        ui_error "UID/GID inválidos para ${home_user}"
        return 1
    }
}

detect_home_standard_directories() {
    local home_source=$1
    local -n directories_ref=$2
    local config_file="${home_source}/.config/user-dirs.dirs"
    local spec key fallback line candidate
    local -A used=()

    directories_ref=()
    for spec in "${HOMEFS_XDG_SPECS[@]}"; do
        key=${spec%%:*}
        fallback=${spec#*:}
        candidate=""
        if [[ -r "${config_file}" ]]; then
            line="$(grep -E -m1 "^XDG_${key}_DIR=\"\\\$HOME/[^/\"]+\"$" \
                "${config_file}" || true)"
            [[ -z "${line}" ]] || candidate=${line#*\$HOME/}
            candidate=${candidate%\"}
        fi
        [[ -n "${candidate}" && -d "${home_source}/${candidate}" ]] || candidate=${fallback}
        [[ "${candidate}" != . && "${candidate}" != .. && "${candidate}" != */* ]] || {
            ui_error "Nome XDG inseguro detectado: ${candidate}"
            return 1
        }
        if [[ -z "${used[${candidate}]+x}" ]]; then
            directories_ref+=("${candidate}")
            used[${candidate}]=1
        fi
    done
}

estimate_homefs_staging_size_mib() {
    local home_source=$1
    local -n estimate_ref=$2
    local relative source_path desktop_directory desktop_path item_bytes
    local total_bytes=0
    local -a standard_directories=()

    detect_home_standard_directories "${home_source}" standard_directories || return 1
    for relative in "${HOMEFS_WHITELIST[@]}"; do
        source_path="${home_source}/${relative}"
        [[ -e "${source_path}" || -L "${source_path}" ]] || continue
        item_bytes="$(du -sb -- "${source_path}" | awk '{print $1}')" || return 1
        total_bytes=$(( total_bytes + item_bytes ))
    done

    desktop_directory=${standard_directories[0]}
    source_path="${home_source}/${desktop_directory}"
    if [[ -d "${source_path}" && ! -L "${source_path}" ]]; then
        while IFS= read -r -d '' desktop_path; do
            [[ -f "${desktop_path}" && ! -L "${desktop_path}" ]] || continue
            item_bytes="$(stat -c '%s' -- "${desktop_path}")" || return 1
            total_bytes=$(( total_bytes + item_bytes ))
        done < <(find -P "${source_path}" -mindepth 1 -maxdepth 1 \
            -name '*.desktop' -print0)
    fi

    estimate_ref=$(( (total_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))
}

validate_homefs_source_symlinks() {
    local home_source=$1
    local approved_path=$2
    local link target resolved

    while IFS= read -r -d '' link; do
        target="$(readlink -- "${link}")"
        if [[ "${target}" == /* ]]; then
            resolved="$(realpath -m -- "${target}")"
        else
            resolved="$(realpath -m -- "$(dirname -- "${link}")/${target}")"
        fi
        [[ "${resolved}" == "${home_source}" || "${resolved}" == "${home_source}/"* ]] || {
            ui_error "Symlink aponta para fora da home: ${link} -> ${target}"
            return 1
        }
    done < <(find -P "${approved_path}" -type l -print0)
}

prepare_homefs_staging() {
    local home_source=$1 home_user=$2 home_uid=$3 home_gid=$4
    local -n standard_directories_ref=$5
    local -n staging_ref=$6
    local relative source_path directory desktop_directory desktop_path
    local staging_parent=${7:-}

    if [[ -n "${staging_parent}" ]]; then
        [[ -d "${staging_parent}" && ! -L "${staging_parent}" && -w "${staging_parent}" ]] || {
            ui_error "Diretório local de staging do homefs inválido: ${staging_parent}"
            return 1
        }
        staging_ref="$(mktemp --directory --tmpdir="${staging_parent}" \
            'pmjs-homefs-staging.XXXXXX')" || {
            ui_error "Não foi possível criar staging do homefs em ${staging_parent}"
            return 1
        }
    elif [[ -d /var/tmp && -w /var/tmp ]] &&
       staging_ref="$(mktemp --directory --tmpdir=/var/tmp 'pmjs-homefs-staging.XXXXXX' 2>/dev/null)"; then
        :
    elif [[ -d /tmp && -w /tmp ]] &&
         staging_ref="$(mktemp --directory --tmpdir=/tmp 'pmjs-homefs-staging.XXXXXX')"; then
        :
    else
        ui_error "Não foi possível criar staging local em /var/tmp ou /tmp"
        return 1
    fi
    install -d -m 0755 -o "${home_uid}" -g "${home_gid}" -- "${staging_ref}/${home_user}"

    for relative in "${HOMEFS_WHITELIST[@]}"; do
        source_path="${home_source}/${relative}"
        [[ -e "${source_path}" || -L "${source_path}" ]] || continue
        validate_homefs_source_symlinks "${home_source}" "${source_path}"
        rsync -aAX --numeric-ids \
            --exclude='*.lock' --exclude='*.tmp' --exclude='*~' --exclude='.#*' \
            --relative -- "${home_source}/./${relative}" "${staging_ref}/${home_user}/"
    done

    for directory in "${standard_directories_ref[@]}"; do
        install -d -m 0755 -o "${home_uid}" -g "${home_gid}" -- \
            "${staging_ref}/${home_user}/${directory}"
    done

    desktop_directory=${standard_directories_ref[0]}
    source_path="${home_source}/${desktop_directory}"
    if [[ -d "${source_path}" && ! -L "${source_path}" ]]; then
        while IFS= read -r -d '' desktop_path; do
            [[ -f "${desktop_path}" && ! -L "${desktop_path}" ]] || {
                ui_error "Atalho Desktop não é arquivo regular: ${desktop_path}"
                return 1
            }
            rsync -aAX --numeric-ids -- "${desktop_path}" \
                "${staging_ref}/${home_user}/${desktop_directory}/"
        done < <(find -P "${source_path}" -mindepth 1 -maxdepth 1 \
            -name '*.desktop' -print0)
    elif [[ -e "${source_path}" || -L "${source_path}" ]]; then
        ui_error "Desktop da origem não é um diretório regular: ${source_path}"
        return 1
    fi
}

homefs_path_is_allowed() {
    local relative=$1 home_user=$2
    shift 2
    local directory desktop_directory=${1:-}

    case "${relative}" in
        "${home_user}"|"${home_user}/.config"|"${home_user}/.local"|\
        "${home_user}/.local/share"|\
        "${home_user}/.config/autostart"|"${home_user}/.config/autostart/"*|\
        "${home_user}/.config/dconf"|"${home_user}/.config/dconf/"*|\
        "${home_user}/.config/mate"|"${home_user}/.config/mate/"*|\
        "${home_user}/.config/menus"|"${home_user}/.config/menus/"*|\
        "${home_user}/.config/caja"|"${home_user}/.config/caja/"*|\
        "${home_user}/.config/pluma"|"${home_user}/.config/pluma/"*|\
        "${home_user}/.config/vlc"|"${home_user}/.config/vlc/"*|\
        "${home_user}/.local/share/applications"|\
        "${home_user}/.local/share/applications/"*) return 0 ;;
    esac
    for directory in "$@"; do
        [[ "${relative}" == "${home_user}/${directory}" ]] && return 0
        if [[ "${directory}" == "${desktop_directory}" &&
              "${relative}" == "${home_user}/${directory}/"*.desktop &&
              "${relative#"${home_user}/${directory}/"}" != */* ]]; then
            return 0
        fi
    done
    return 1
}

validate_homefs_staging() {
    local staging_dir=$1 home_user=$2 home_uid=$3 home_gid=$4 max_size_mib=$5
    shift 5
    local path relative owner_uid owner_gid size_bytes max_bytes directory

    [[ -d "${staging_dir}/${home_user}" ]] || {
        ui_error "Raiz do usuário ausente no staging: ${home_user}"
        return 1
    }
    owner_uid="$(stat -c '%u' -- "${staging_dir}/${home_user}")"
    owner_gid="$(stat -c '%g' -- "${staging_dir}/${home_user}")"
    [[ "${owner_uid}" == "${home_uid}" && "${owner_gid}" == "${home_gid}" ]] || {
        ui_error "Owner inesperado na raiz do perfil: ${owner_uid}:${owner_gid}"
        return 1
    }
    for directory in "$@"; do
        [[ -d "${staging_dir}/${home_user}/${directory}" ]] || {
            ui_error "Diretório padrão ausente no staging: ${directory}"
            return 1
        }
        owner_uid="$(stat -c '%u' -- "${staging_dir}/${home_user}/${directory}")"
        owner_gid="$(stat -c '%g' -- "${staging_dir}/${home_user}/${directory}")"
        [[ "${owner_uid}" == "${home_uid}" && "${owner_gid}" == "${home_gid}" ]] || {
            ui_error "Owner inesperado no diretório padrão ${directory}: ${owner_uid}:${owner_gid}"
            return 1
        }
    done
    if find -P "${staging_dir}" \( -type s -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
        ui_error "Socket, device ou FIFO encontrado no staging do homefs"
        return 1
    fi
    if find -P "${staging_dir}" -name $'*\n*' -print -quit | grep -q .; then
        ui_error "Nome com quebra de linha encontrado no staging do homefs"
        return 1
    fi

    while IFS= read -r -d '' path; do
        relative=${path#"${staging_dir}/"}
        homefs_path_is_allowed "${relative}" "${home_user}" "$@" || {
            ui_error "Caminho fora da whitelist no staging: ${relative}"
            return 1
        }
        case "$(basename -- "${relative}")" in
            *.lock|*.tmp|*~|.#*) ui_error "Arquivo temporário/lock no staging: ${relative}"; return 1 ;;
        esac
        owner_uid="$(stat -c '%u' -- "${path}")"
        owner_gid="$(stat -c '%g' -- "${path}")"
        if [[ "${owner_uid}" != "${home_uid}" || "${owner_gid}" != "${home_gid}" ]]; then
            declare -F log_write >/dev/null && \
                log_write WARN "Owner preservado da whitelist: ${relative} (${owner_uid}:${owner_gid})"
        fi
    done < <(find -P "${staging_dir}" -mindepth 1 -print0)

    size_bytes="$(du -sb -- "${staging_dir}" | awk '{print $1}')"
    max_bytes=$(( max_size_mib * 1024 * 1024 ))
    (( size_bytes <= max_bytes )) || {
        ui_error "Staging do homefs excede ${max_size_mib} MiB: ${size_bytes} bytes"
        return 1
    }
}

generate_homefs() {
    local staging_dir=$1 home_user=$2 archive_file=$3
    local compression=${4:-gzip} zstd_level=${5:-3}
    local -a compression_options
    archive_tar_create_options "${compression}" "${zstd_level}" compression_options
    tar --create "${compression_options[@]}" --file "${archive_file}" --numeric-owner --acls --xattrs \
        --directory="${staging_dir}" "${home_user}"
}

validate_homefs_archive() {
    local archive_file=$1 home_user=$2
    shift 2
    local listing entry normalized first_useful="" directory
    local compression=${IMAGE_COMPRESSION:-gzip}
    local -a read_options

    [[ -s "${archive_file}" ]] || { ui_error "homefs vazio: ${archive_file}"; return 1; }
    validate_archive_compression "${archive_file}" "${compression}" || {
        ui_error "Falha ${compression} no homefs: ${archive_file}"
        return 1
    }
    archive_tar_read_options "${compression}" read_options
    listing="$(tar --list "${read_options[@]}" --file "${archive_file}")" || {
        ui_error "Falha ao listar homefs: ${archive_file}"
        return 1
    }
    while IFS= read -r entry; do
        normalized=${entry#./}
        normalized=${normalized%/}
        [[ -n "${normalized}" ]] || continue
        [[ -n "${first_useful}" ]] || first_useful=${normalized}
        [[ "${entry}" != /* && "${normalized}" != .. && "${normalized}" != ../* &&
           "${normalized}" != */../* && "${normalized}" != */.. ]] || {
            ui_error "Caminho inseguro no homefs: ${entry}"
            return 1
        }
        [[ "${normalized}" == "${home_user}" || "${normalized}" == "${home_user}/"* ]] || {
            ui_error "Raiz inválida no homefs: ${entry}"
            return 1
        }
        [[ "${normalized}" != home && "${normalized}" != home/* ]] || {
            ui_error "Prefixo home/ proibido no homefs: ${entry}"
            return 1
        }
        homefs_path_is_allowed "${normalized}" "${home_user}" "$@" || {
            ui_error "Entrada fora da whitelist no homefs: ${entry}"
            return 1
        }
    done <<< "${listing}"
    [[ "${first_useful}" == "${home_user}" ]] || {
        ui_error "Primeira raiz útil do homefs não é ${home_user}/"
        return 1
    }
    for directory in "$@"; do
        grep -Fqx -- "${home_user}/${directory}/" <<< "${listing}" || {
            ui_error "Diretório padrão ausente do homefs: ${directory}"
            return 1
        }
    done
    tar --list "${read_options[@]}" --file "${archive_file}" >/dev/null
}

cleanup_homefs_staging() {
    local staging_dir=$1 expected_parent=${2:-} resolved_staging staging_parent
    [[ -n "${staging_dir}" && -e "${staging_dir}" ]] || return 0
    resolved_staging="$(realpath -m -- "${staging_dir}")"
    staging_parent="$(dirname -- "${resolved_staging}")"
    if [[ -n "${expected_parent}" ]]; then
        expected_parent="$(realpath -m -- "${expected_parent}")"
    fi
    [[ ( ( -n "${expected_parent}" && "${staging_parent}" == "${expected_parent}" ) ||
         ( -z "${expected_parent}" && ( "${staging_parent}" == /var/tmp || "${staging_parent}" == /tmp ) ) ) &&
       "$(basename -- "${resolved_staging}")" == pmjs-homefs-staging.* &&
       ! -L "${resolved_staging}" && -d "${resolved_staging}" ]] || {
        ui_error "Recusa ao limpar staging inesperado do homefs: ${staging_dir}"
        return 1
    }
    find -P "${resolved_staging}" -depth -delete
}
