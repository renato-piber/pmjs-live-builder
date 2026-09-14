#!/usr/bin/env bash

# Identidade do filesystem que contém pmjs-images. Ela é registrada antes de
# qualquer escrita e conferida novamente durante o build/sync e no cleanup.
VENTOY_DESTINATION=""
VENTOY_MOUNT_ID=""
VENTOY_MOUNT_SOURCE=""
VENTOY_MOUNT_FSTYPE=""
VENTOY_MOUNT_TARGET=""

check_ventoy_dependencies() {
    command -v findmnt >/dev/null 2>&1 || {
        ui_error "Suporte Ventoy indisponível: falta findmnt (util-linux)."
        return 1
    }
}

read_ventoy_mount_identity() {
    local path=$1
    local -n id_ref=$2 source_ref=$3 fstype_ref=$4 target_ref=$5

    id_ref="$(findmnt --noheadings --raw --output ID --target "${path}")" || return 1
    source_ref="$(findmnt --noheadings --raw --output SOURCE --target "${path}")" || return 1
    fstype_ref="$(findmnt --noheadings --raw --output FSTYPE --target "${path}")" || return 1
    target_ref="$(findmnt --noheadings --raw --output TARGET --target "${path}")" || return 1
    [[ "${id_ref}" =~ ^[0-9]+$ && -n "${source_ref}" && -n "${fstype_ref}" &&
       -n "${target_ref}" && "${source_ref}" != *$'\n'* &&
       "${fstype_ref}" != *$'\n'* && "${target_ref}" != *$'\n'* ]]
}

validate_ventoy_destination() {
    local configured_dir=$1 resolved

    [[ "${configured_dir}" == /* ]] || {
        ui_error "O diretório Ventoy deve ser um caminho absoluto: ${configured_dir}"
        return 1
    }
    resolved="$(realpath -e -- "${configured_dir}")" || {
        ui_error "O diretório Ventoy não existe: ${configured_dir}"
        return 1
    }
    [[ -d "${resolved}" && ! -L "${configured_dir}" && -w "${resolved}" &&
       "$(basename -- "${resolved}")" == pmjs-images ]] || {
        ui_error "O destino deve ser um diretório real e gravável chamado pmjs-images: ${configured_dir}"
        return 1
    }
    read_ventoy_mount_identity "${resolved}" VENTOY_MOUNT_ID \
        VENTOY_MOUNT_SOURCE VENTOY_MOUNT_FSTYPE VENTOY_MOUNT_TARGET || {
        ui_error "Não foi possível confirmar o filesystem montado do Ventoy: ${resolved}"
        return 1
    }
    [[ "${VENTOY_MOUNT_TARGET}" != / ]] || {
        ui_error "O destino está no filesystem raiz; o Ventoy não parece estar montado"
        return 1
    }
    [[ "${VENTOY_MOUNT_TARGET}" == /* &&
       ( "${resolved}" == "${VENTOY_MOUNT_TARGET}" ||
         "${resolved}" == "${VENTOY_MOUNT_TARGET}/"* ) ]] || {
        ui_error "O destino não pertence ao mountpoint Ventoy confirmado: ${VENTOY_MOUNT_TARGET}"
        return 1
    }
    VENTOY_DESTINATION=${resolved}
    ui_info "Ventoy validado: ${VENTOY_DESTINATION} (${VENTOY_MOUNT_FSTYPE})"
}

ventoy_mount_unchanged() {
    local current_id current_source current_fstype current_target
    [[ -n "${VENTOY_DESTINATION}" &&
       "$(realpath -e -- "${VENTOY_DESTINATION}")" == "${VENTOY_DESTINATION}" ]] || return 1
    read_ventoy_mount_identity "${VENTOY_DESTINATION}" current_id current_source \
        current_fstype current_target || return 1
    [[ "${current_id}" == "${VENTOY_MOUNT_ID}" &&
       "${current_source}" == "${VENTOY_MOUNT_SOURCE}" &&
       "${current_fstype}" == "${VENTOY_MOUNT_FSTYPE}" &&
       "${current_target}" == "${VENTOY_MOUNT_TARGET}" ]]
}
