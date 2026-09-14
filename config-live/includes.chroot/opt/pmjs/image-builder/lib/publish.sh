#!/usr/bin/env bash

validate_publish_destination() {
    local kind=$1 configured_dir=$2
    local resolved_dir filesystem mount_target

    [[ "${configured_dir}" == /* ]] || {
        ui_error "O destino ${kind} deve ser um caminho absoluto: ${configured_dir}"
        return 1
    }
    resolved_dir="$(realpath -e -- "${configured_dir}")" || {
        ui_error "O destino ${kind} não existe: ${configured_dir}"
        return 1
    }
    [[ -d "${resolved_dir}" && ! -L "${configured_dir}" && -w "${resolved_dir}" ]] || {
        ui_error "O destino ${kind} deve ser um diretório real e gravável: ${configured_dir}"
        return 1
    }

    filesystem="$(findmnt --noheadings --output FSTYPE --target "${resolved_dir}" | awk 'NR == 1 { print $1 }')"
    mount_target="$(findmnt --noheadings --output TARGET --target "${resolved_dir}" | awk 'NR == 1 { print $1 }')"
    [[ -n "${filesystem}" && -n "${mount_target}" ]] || {
        ui_error "Não foi possível identificar o filesystem do destino ${kind}: ${resolved_dir}"
        return 1
    }

    case "${kind}" in
        ventoy)
            [[ "$(basename -- "${resolved_dir}")" == pmjs-images ]] || {
                ui_error "O destino Ventoy deve apontar explicitamente para um diretório pmjs-images/"
                return 1
            }
            [[ "${mount_target}" != / ]] || {
                ui_error "O destino Ventoy está no filesystem raiz, não em uma mídia montada"
                return 1
            }
            ;;
        nfs)
            [[ "${filesystem}" == nfs || "${filesystem}" == nfs4 ]] || {
                ui_error "O destino NFS não está em um filesystem NFS montado: ${resolved_dir} (${filesystem})"
                return 1
            }
            ;;
        *)
            ui_error "Tipo de destino de publicação desconhecido: ${kind}"
            return 1
            ;;
    esac
}

prepare_image_publication() {
    local source_dir=$1 destination_base=$2
    local -n staging_ref=$3
    local image_name destination_final filename

    image_name="$(basename -- "${source_dir}")"
    destination_final="${destination_base}/${image_name}"
    [[ ! -e "${destination_final}" && ! -L "${destination_final}" ]] || {
        ui_error "A versão já existe e não será substituída: ${destination_final}"
        return 1
    }

    staging_ref="$(mktemp --directory --tmpdir="${destination_base}" \
        ".${image_name}.partial.XXXXXX")" || {
        ui_error "Não foi possível criar staging no destino: ${destination_base}"
        return 1
    }
    for filename in rootfs.tar.zst homefs.tar.zst SHA256SUMS manifest.json; do
        cp -- "${source_dir}/${filename}" "${staging_ref}/${filename}"
    done
    validate_image_directory "${staging_ref}" || {
        ui_error "A cópia no destino falhou na validação: ${destination_base}"
        return 1
    }
    sync --file-system "${staging_ref}/manifest.json"
}

commit_image_publication() {
    local staging_dir=$1 destination_base=$2
    local staging_name image_name destination_final

    staging_name="$(basename -- "${staging_dir}")"
    image_name=${staging_name#.}
    image_name=${image_name%.partial.*}
    destination_final="${destination_base}/${image_name}"
    [[ "$(dirname -- "${staging_dir}")" == "${destination_base}" &&
       "${staging_name}" == .*.partial.* && ! -e "${destination_final}" &&
       ! -L "${destination_final}" ]] || {
        ui_error "Staging de publicação inseguro ou versão já existente: ${staging_dir}"
        return 1
    }
    mv -T --no-clobber -- "${staging_dir}" "${destination_final}"
    [[ ! -e "${staging_dir}" && -d "${destination_final}" ]] || {
        ui_error "A versão surgiu durante a publicação e não foi substituída: ${destination_final}"
        return 1
    }
    sync --file-system "${destination_final}/manifest.json"
    declare -F log_write >/dev/null && \
        log_write SUCCESS "Imagem publicada atomicamente: ${destination_final}"
    printf '%s\n' "${destination_final}"
}

cleanup_publication_staging() {
    local staging_dir=$1 destination_base=$2
    local resolved_staging

    [[ -n "${staging_dir}" && -e "${staging_dir}" ]] || return 0
    resolved_staging="$(realpath -m -- "${staging_dir}")"
    [[ "$(dirname -- "${resolved_staging}")" == "${destination_base}" &&
       "$(basename -- "${resolved_staging}")" == .*.partial.* &&
       -d "${resolved_staging}" && ! -L "${resolved_staging}" ]] || {
        ui_error "Recusa ao limpar staging de publicação inesperado: ${staging_dir}"
        return 1
    }
    find -P "${resolved_staging}" -depth -delete
}
