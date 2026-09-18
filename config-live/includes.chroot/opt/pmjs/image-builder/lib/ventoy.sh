#!/usr/bin/env bash

# Identidade do filesystem que contém pmjs-images. Ela é registrada antes de
# qualquer escrita e conferida novamente durante o build/sync e no cleanup.
VENTOY_DESTINATION=""
VENTOY_MOUNT_ID=""
VENTOY_MOUNT_SOURCE=""
VENTOY_MOUNT_FSTYPE=""
VENTOY_MOUNT_TARGET=""
VENTOY_MOUNTED_BY_BUILDER=0
VENTOY_OWNED_MOUNT_SOURCE=""
VENTOY_OWNED_MOUNT_TARGET=""
VENTOY_OWNED_MOUNT_ID=""
VENTOY_MOUNT_IN_PROGRESS=0
VENTOY_PENDING_SIGNAL=""

ventoy_decode_mount_path() {
    local value=$1
    [[ "${value}" != *[[:cntrl:]]* ]] || return 1
    if [[ "${value}" == *'\x'* ]]; then
        python3 - "${value}" <<'PY'
import os
import re
import sys
value = os.fsdecode(re.sub(rb"\\x([0-9a-fA-F]{2})", lambda m: bytes([int(m[1], 16)]), os.fsencode(sys.argv[1])))
if any(ord(c) < 32 or ord(c) == 127 for c in value):
    raise ValueError("path de mount contém caracteres de controle")
sys.stdout.write(value)
PY
    else
        printf '%s' "${value}"
    fi
}

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
    target_ref="$(ventoy_decode_mount_path "${target_ref}")" || return 1
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

check_ventoy_automount_dependencies() {
    local dependency
    for dependency in findmnt lsblk blkid mount umount realpath basename awk sort find mkdir python3; do
        command -v "${dependency}" >/dev/null 2>&1 || {
            ui_error "Automount Ventoy indisponível: falta ${dependency}."
            return 1
        }
    done
}

ventoy_mount_target_is_safe() {
    local path=$1 canonical
    [[ "${path}" == /*/* && "${path}" != *[[:cntrl:]]* && ! -L "${path}" ]] || return 1
    canonical="$(realpath -m -- "${path}")" || return 1
    [[ "${canonical}" == "${path}" ]] || return 1
    case "${path}" in
        /var/tmp|/var/lib|/var/cache|/var/log|/usr/local|/run/user|\
        /etc/*|/proc/*|/sys/*|/dev/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/boot/*|/root/*|/home/*)
            return 1 ;;
    esac
}

validate_ventoy_automount_config() {
    ventoy_mount_target_is_safe "${VENTOY_MOUNTPOINT:-}" || {
        ui_error "VENTOY_MOUNTPOINT vazio, amplo ou inseguro: ${VENTOY_MOUNTPOINT:-vazio}"
        return 1
    }
    [[ -n "${VENTOY_VOLUME_LABEL:-}" && "${VENTOY_VOLUME_LABEL}" != */* &&
       "${VENTOY_VOLUME_LABEL}" != *[[:cntrl:]]* &&
       "${VENTOY_ALLOWED_FSTYPES:-}" =~ ^[A-Za-z0-9._+-]+(\ [A-Za-z0-9._+-]+)*$ ]] || {
        ui_error "VENTOY_VOLUME_LABEL ou VENTOY_ALLOWED_FSTYPES inválido/ausente"
        return 1
    }
}

ventoy_list_partitions() {
    lsblk -rpn -o NAME,TYPE | awk '$2 == "part" && $1 ~ /^\/dev\// { print $1 }' | sort -u
}

ventoy_device_property() {
    local device=$1 property=$2 value
    value="$(lsblk -dn -o "${property}" -- "${device}" 2>/dev/null | \
        awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }')" || value=""
    if [[ -z "${value}" ]]; then
        case "${property}" in
            LABEL) value="$(blkid -s LABEL -o value -- "${device}" 2>/dev/null)" || value="" ;;
            FSTYPE) value="$(blkid -s TYPE -o value -- "${device}" 2>/dev/null)" || value="" ;;
        esac
    fi
    printf '%s\n' "${value}"
}

ventoy_fstype_allowed() {
    local requested=${1,,} allowed
    [[ "${requested}" =~ ^[a-z0-9._+-]+$ ]] || return 1
    for allowed in ${VENTOY_ALLOWED_FSTYPES}; do
        [[ "${requested}" != "${allowed,,}" ]] || return 0
    done
    return 1
}

ventoy_device_is_block() { [[ -b "$1" ]]; }
ventoy_mapper_path() { printf '/dev/mapper/%s\n' "$(basename -- "$1")"; }

ventoy_partition_is_candidate() {
    local device=$1 label filesystem transport parent
    [[ "${device}" == /dev/* && "${device}" != /dev/mapper/* ]] || return 1
    ventoy_device_is_block "${device}" || return 1
    label="$(ventoy_device_property "${device}" LABEL)"
    [[ "${label}" == "${VENTOY_VOLUME_LABEL}" ]] || return 1
    filesystem="$(ventoy_device_property "${device}" FSTYPE)"
    ventoy_fstype_allowed "${filesystem}" || return 1
    transport="$(ventoy_device_property "${device}" TRAN)"
    if [[ "${transport,,}" != usb ]]; then
        parent="$(ventoy_device_property "${device}" PKNAME)"
        [[ -n "${parent}" ]] || return 1
        [[ "${parent}" == /dev/* ]] || parent="/dev/${parent}"
        transport="$(ventoy_device_property "${parent}" TRAN)"
    fi
    [[ "${transport,,}" == usb ]]
}

ventoy_devices_are_same() {
    local first=$1 second=$2 first_real second_real
    [[ "${first}" != "${second}" ]] || return 0
    first_real="$(realpath -e -- "${first}" 2>/dev/null)" || return 1
    second_real="$(realpath -e -- "${second}" 2>/dev/null)" || return 1
    [[ "${first_real}" == "${second_real}" ]]
}

ventoy_is_live_boot() {
    local source
    source="$(findmnt --noheadings --raw --output SOURCE --target /run/live/medium)" || return 1
    case "${source}" in /dev/mapper/ventoy|/dev/mapper/ventoy\[*\]) return 0 ;; esac
    return 1
}

ventoy_resolve_mount_device() {
    local partition=$1 mapper
    local -n resolved_device=$2
    mapper="$(ventoy_mapper_path "${partition}")"
    if ! ventoy_device_is_block "${mapper}" && ventoy_is_live_boot; then
        command -v udevadm >/dev/null 2>&1 || {
            ui_error "Mapper Ventoy ausente e udevadm indisponível: ${mapper}"
            return 1
        }
        ui_info "Aguardando mapper Ventoy via udev..."
        udevadm trigger && udevadm settle || {
            ui_error "Não foi possível disponibilizar o mapper Ventoy via udev"
            return 1
        }
        ventoy_device_is_block "${mapper}" || {
            ui_error "Mapper esperado do Ventoy ausente: ${mapper}; a partição física não será montada"
            return 1
        }
    fi
    if ventoy_device_is_block "${mapper}"; then
        [[ "$(ventoy_device_property "${mapper}" LABEL)" == "${VENTOY_VOLUME_LABEL}" ]] &&
            ventoy_fstype_allowed "$(ventoy_device_property "${mapper}" FSTYPE)" || {
                ui_error "Mapper Ventoy possui identidade incompatível: ${mapper}"
                return 1
            }
        resolved_device=${mapper}
    else
        resolved_device=${partition}
    fi
}

ventoy_find_mount_targets() {
    findmnt --noheadings --raw --source "$1" --output TARGET
}

ventoy_read_mount_record() {
    findmnt --noheadings --raw --mountpoint "$1" --output ID,SOURCE,FSTYPE,OPTIONS
}

ventoy_auto_record_matches() {
    local record=$1 device=$2 require_rw=${3:-1} expected_id=${4:-}
    local mount_id source filesystem options extra
    [[ -n "${record}" && "${record}" != *$'\n'* ]] || return 1
    read -r mount_id source filesystem options extra <<< "${record}"
    [[ "${mount_id}" =~ ^[0-9]+$ && -n "${options}" && -z "${extra}" &&
       ( -z "${expected_id}" || "${mount_id}" == "${expected_id}" ) ]] || return 1
    ventoy_devices_are_same "${source}" "${device}" || return 1
    ventoy_fstype_allowed "${filesystem}" || return 1
    if [[ "${require_rw}" == 1 ]]; then
        [[ ",${options}," == *,rw,* && ",${options}," != *,ro,* ]] || return 1
    fi
}

ventoy_find_existing_mount() {
    local partition=$1 mapper search_device encoded_targets encoded_target mount_target record status
    local -n existing_target=$2 existing_device=$3
    local -a devices=("${partition}")
    mapper="$(ventoy_mapper_path "${partition}")"
    if ventoy_device_is_block "${mapper}"; then
        [[ "$(ventoy_device_property "${mapper}" LABEL)" == "${VENTOY_VOLUME_LABEL}" ]] &&
            ventoy_fstype_allowed "$(ventoy_device_property "${mapper}" FSTYPE)" || {
                ui_error "Mapper Ventoy possui identidade incompatível: ${mapper}"
                return 2
            }
        devices+=("${mapper}")
    fi
    existing_target=""
    for search_device in "${devices[@]}"; do
        if encoded_targets="$(ventoy_find_mount_targets "${search_device}")"; then :;
        else
            status=$?
            [[ ${status} -eq 1 && -z "${encoded_targets}" ]] && continue
            ui_error "findmnt falhou durante a descoberta de mounts Ventoy"
            return 2
        fi
        while IFS= read -r encoded_target; do
            [[ -n "${encoded_target}" ]] || continue
            mount_target="$(ventoy_decode_mount_path "${encoded_target}")" || return 2
            [[ "${mount_target}" != "${existing_target}" ]] || continue
            record="$(ventoy_read_mount_record "${mount_target}")" || return 2
            ventoy_mount_target_is_safe "${mount_target}" &&
                ventoy_auto_record_matches "${record}" "${search_device}" 1 || {
                    ui_error "Mount Ventoy inseguro, incorreto ou somente leitura: ${mount_target}; não será remontado"
                    return 2
                }
            [[ -z "${existing_target}" ]] || {
                ui_error "Mais de um mount Ventoy encontrado; descoberta ambígua"
                return 2
            }
            existing_target=${mount_target}
            existing_device=${search_device}
        done <<< "${encoded_targets}"
    done
    [[ -n "${existing_target}" ]]
}

ventoy_prepare_images_directory() {
    local target=$1 device=$2 record confirmed_id
    record="$(ventoy_read_mount_record "${target}")" || return 1
    ventoy_auto_record_matches "${record}" "${device}" 1 || {
        ui_error "findmnt não confirmou o Ventoy gravável; nenhuma imagem será escrita"
        return 1
    }
    confirmed_id=${record%% *}
    if [[ "${VENTOY_MOUNTED_BY_BUILDER}" == 1 && "${target}" == "${VENTOY_OWNED_MOUNT_TARGET}" &&
          "${confirmed_id}" != "${VENTOY_OWNED_MOUNT_ID}" ]]; then
        ui_error "O mount Ventoy mudou após mount; nenhuma imagem será escrita"
        return 1
    fi
    [[ ! -L "${target}/pmjs-images" ]] || {
        ui_error "pmjs-images na mídia Ventoy é symlink; operação recusada"
        return 1
    }
    if [[ ! -e "${target}/pmjs-images" ]]; then
        # Criar só após a confirmação; mount falho nunca leva a mkdir local.
        mkdir -- "${target}/pmjs-images" || return 1
    fi
    validate_ventoy_destination "${target}/pmjs-images" || return 1
    [[ "${VENTOY_MOUNT_ID}" == "${confirmed_id}" && "${VENTOY_MOUNT_TARGET}" == "${target}" ]] &&
        ventoy_devices_are_same "${VENTOY_MOUNT_SOURCE}" "${device}" || {
            ui_error "Identidade do Ventoy mudou ao preparar pmjs-images"
            return 1
        }
    record="$(ventoy_read_mount_record "${target}")" || return 1
    ventoy_auto_record_matches "${record}" "${device}" 1 "${confirmed_id}" || return 1
}

prepare_ventoy_automount() {
    local partition device target listed record status filesystem mount_status=0
    local -a candidates=()
    check_ventoy_automount_dependencies || return 1
    validate_ventoy_automount_config || return 1
    ui_info "Verificando mídia Ventoy..."
    listed="$(ventoy_list_partitions)" || { ui_error "Não foi possível listar partições USB"; return 1; }
    while IFS= read -r partition; do
        [[ -n "${partition}" ]] || continue
        ventoy_partition_is_candidate "${partition}" && candidates+=("${partition}")
    done <<< "${listed}"
    if (( ${#candidates[@]} != 1 )); then
        ui_error "É necessária exatamente uma partição USB ${VENTOY_VOLUME_LABEL} compatível; encontradas ${#candidates[@]}"
        return 1
    fi
    partition=${candidates[0]}
    if ventoy_find_existing_mount "${partition}" target device; then
        ui_info "Ventoy já montado; reutilizando ${target}"
        ventoy_prepare_images_directory "${target}" "${device}"
        return $?
    else
        status=$?
        [[ ${status} -eq 1 ]] || return 1
    fi
    ventoy_resolve_mount_device "${partition}" device || return 1
    # udev pode ter provocado um automount; nunca criar uma segunda montagem.
    if ventoy_find_existing_mount "${partition}" target device; then
        ui_info "Ventoy já montado; reutilizando ${target}"
        ventoy_prepare_images_directory "${target}" "${device}"
        return $?
    else
        status=$?
        [[ ${status} -eq 1 ]] || return 1
    fi
    target=${VENTOY_MOUNTPOINT}
    mkdir -p -- "${target}" || return 1
    validate_ventoy_automount_config || return 1
    if record="$(ventoy_read_mount_record "${target}")"; then
        ui_error "Mountpoint Ventoy ocupado; montagem recusada: ${target}"
        return 1
    else
        status=$?
        [[ ${status} -eq 1 && -z "${record}" ]] || { ui_error "findmnt não confirmou mountpoint livre"; return 1; }
    fi
    listed="$(find -P "${target}" -mindepth 1 -maxdepth 1 -print -quit)" || return 1
    [[ -z "${listed}" ]] || { ui_error "Mountpoint Ventoy contém arquivos locais; montagem recusada"; return 1; }
    filesystem="$(ventoy_device_property "${device}" FSTYPE)"
    ventoy_fstype_allowed "${filesystem}" || return 1
    ui_info "Montando ${device} em ${target} para escrita"
    VENTOY_MOUNT_IN_PROGRESS=1
    mount -t "${filesystem}" -o rw,nosuid,nodev -- "${device}" "${target}" || mount_status=$?
    if [[ ${mount_status} -eq 0 ]]; then
        VENTOY_MOUNTED_BY_BUILDER=1
        VENTOY_OWNED_MOUNT_SOURCE=${device}
        VENTOY_OWNED_MOUNT_TARGET=${target}
        VENTOY_OWNED_MOUNT_ID=""
        if record="$(ventoy_read_mount_record "${target}")" &&
           ventoy_auto_record_matches "${record}" "${device}" 0; then
            VENTOY_OWNED_MOUNT_ID=${record%% *}
        fi
    fi
    VENTOY_MOUNT_IN_PROGRESS=0
    if [[ -n "${VENTOY_PENDING_SIGNAL}" ]]; then on_signal "${VENTOY_PENDING_SIGNAL}"; fi
    [[ ${mount_status} -eq 0 ]] || { ui_error "Não foi possível montar o Ventoy; build/cópia não iniciado"; return 1; }
    [[ -n "${VENTOY_OWNED_MOUNT_ID}" ]] || {
        ui_error "findmnt não confirmou a montagem Ventoy; nenhuma imagem será escrita"
        return 1
    }
    ventoy_prepare_images_directory "${target}" "${device}" || return 1
    ui_success "Ventoy montado e validado: ${VENTOY_DESTINATION}"
}

cleanup_ventoy_mount() {
    local record
    [[ "${VENTOY_MOUNTED_BY_BUILDER}" == 1 ]] || return 0
    if [[ -z "${VENTOY_OWNED_MOUNT_ID}" ]] ||
       ! record="$(ventoy_read_mount_record "${VENTOY_OWNED_MOUNT_TARGET}")" ||
       ! ventoy_auto_record_matches "${record}" "${VENTOY_OWNED_MOUNT_SOURCE}" 0 "${VENTOY_OWNED_MOUNT_ID}"; then
        ui_warn "Ventoy não desmontado: identidade do mount mudou ou não pôde ser confirmada."
    elif umount -- "${VENTOY_OWNED_MOUNT_TARGET}"; then
        VENTOY_MOUNTED_BY_BUILDER=0
        ui_info "Ventoy desmontado: ${VENTOY_OWNED_MOUNT_TARGET}"
    else
        ui_warn "Não foi possível desmontar o Ventoy; o resultado principal foi preservado."
    fi
    return 0
}
