#!/usr/bin/env bash

validate_sync_image_name() {
    local requested=$1 configured_name=$2
    [[ "${requested}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ &&
       "${requested}" == "${configured_name}-"?* &&
       "${requested}" != *'.build.'* && "${requested}" != *'.partial.'* &&
       "${requested}" != *'.sync.'* ]] || {
        ui_error "Nome de imagem inválido ou incompatível com IMAGE_NAME: ${requested}"
        return 1
    }
}

validate_ventoy_sync_destination() {
    validate_ventoy_destination "$1"
}

image_bundle_size_bytes() {
    local image_dir=$1
    local -n size_ref=$2
    local filename bytes
    size_ref=0
    for filename in rootfs.tar.zst homefs.tar.zst SHA256SUMS manifest.json; do
        bytes="$(stat -c '%s' -- "${image_dir}/${filename}")" || return 1
        size_ref=$(( size_ref + bytes ))
    done
}

check_ventoy_free_space() {
    local destination=$1 image_bytes=$2 margin_mib=$3
    local available_bytes required_bytes
    [[ "${margin_mib}" =~ ^[0-9]+$ ]] || {
        ui_error "VENTOY_FREE_SPACE_MARGIN_MIB deve ser inteiro não negativo"
        return 1
    }
    available_bytes="$(df --output=avail -B1 -- "${destination}" | tail -n 1 | tr -d '[:space:]')"
    [[ "${available_bytes}" =~ ^[0-9]+$ ]] || {
        ui_error "Não foi possível medir o espaço livre no Ventoy"
        return 1
    }
    required_bytes=$(( image_bytes + margin_mib * 1024 * 1024 ))
    (( available_bytes >= required_bytes )) || {
        ui_error "Espaço insuficiente no Ventoy: necessários ${required_bytes} bytes (imagem + margem), disponíveis ${available_bytes}."
        return 1
    }
    log_write INFO "Espaço no Ventoy validado: ${available_bytes} bytes; necessários ${required_bytes}"
}

prepare_ventoy_sync_staging() {
    local destination=$1 image_name=$2
    local -n staging_ref=$3
    local final_dir="${destination}/${image_name}"

    ventoy_mount_unchanged || {
        ui_error "O mount do Ventoy mudou antes da cópia"
        return 1
    }
    [[ ! -e "${final_dir}" && ! -L "${final_dir}" ]] || {
        ui_error "A versão já existe no Ventoy e não será substituída: ${final_dir}"
        return 1
    }
    staging_ref="$(mktemp --directory --tmpdir="${destination}" \
        ".${image_name}.sync.XXXXXX")" || {
        ui_error "Não foi possível criar staging no Ventoy: ${destination}"
        return 1
    }
}

copy_image_to_ventoy_staging() {
    local source_dir=$1 staging_dir=$2
    ui_info "Copiando imagem para o staging do Ventoy..."
    rsync --whole-file --human-readable --info=progress2 -- \
        "${source_dir}/rootfs.tar.zst" "${source_dir}/homefs.tar.zst" \
        "${source_dir}/SHA256SUMS" "${source_dir}/manifest.json" \
        "${staging_dir}/"
}

validate_copied_ventoy_bundle() {
    local staging_dir=$1
    ventoy_mount_unchanged || {
        ui_error "O mount do Ventoy mudou durante a cópia"
        return 1
    }
    ui_info "Recalculando SHA256 no Ventoy..."
    validate_image_directory "${staging_dir}" || {
        ui_error "A cópia no Ventoy falhou na validação completa"
        return 1
    }
    ui_success "SHA256 validado no Ventoy"
    sync --file-system "${staging_dir}/manifest.json"
}

commit_ventoy_sync() {
    local staging_dir=$1 destination=$2 image_name=$3
    local resolved_staging staging_name final_dir
    resolved_staging="$(realpath -e -- "${staging_dir}")" || return 1
    staging_name="$(basename -- "${resolved_staging}")"
    final_dir="${destination}/${image_name}"
    ventoy_mount_unchanged || {
        ui_error "O mount do Ventoy mudou antes da publicação final"
        return 1
    }
    [[ "$(dirname -- "${resolved_staging}")" == "${destination}" &&
       "${staging_name}" == ".${image_name}.sync."* &&
       "${staging_name#".${image_name}.sync."}" =~ ^[A-Za-z0-9]+$ &&
       -d "${resolved_staging}" && ! -L "${resolved_staging}" &&
       ! -e "${final_dir}" && ! -L "${final_dir}" ]] || {
        ui_error "Staging Ventoy inseguro ou versão já existente: ${staging_dir}"
        return 1
    }
    mv -T --no-clobber -- "${resolved_staging}" "${final_dir}"
    [[ ! -e "${resolved_staging}" && -d "${final_dir}" ]] || {
        ui_error "A versão surgiu durante a publicação e não foi substituída: ${final_dir}"
        return 1
    }
    sync --file-system "${final_dir}/manifest.json"
}

cleanup_ventoy_sync_staging() {
    local staging_dir=$1 destination=$2 image_name=$3
    local resolved_staging staging_name
    [[ -n "${staging_dir}" && -e "${staging_dir}" ]] || return 0
    ventoy_mount_unchanged || {
        ui_warn "Staging não removido: o mount do Ventoy mudou ou não pôde ser confirmado."
        return 0
    }
    resolved_staging="$(realpath -m -- "${staging_dir}")"
    staging_name="$(basename -- "${resolved_staging}")"
    [[ "$(dirname -- "${resolved_staging}")" == "${destination}" &&
       "${staging_name}" == ".${image_name}.sync."* &&
       "${staging_name#".${image_name}.sync."}" =~ ^[A-Za-z0-9]+$ &&
       -d "${resolved_staging}" && ! -L "${resolved_staging}" ]] || {
        ui_error "Recusa ao limpar staging Ventoy inesperado: ${staging_dir}"
        return 1
    }
    find -P "${resolved_staging}" -depth -delete
}

format_sync_size() {
    local bytes=$1
    if (( bytes >= 1024 * 1024 * 1024 )); then
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
    elif (( bytes >= 1024 * 1024 )); then
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f MiB", bytes / 1048576 }'
    else
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f KiB", bytes / 1024 }'
    fi
}
