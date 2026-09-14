#!/usr/bin/env bash

SOURCE_DETECT_DIR=""
SOURCE_DETECT_PROBE_MOUNTED=false
SOURCE_DETECT_ROOT_MOUNTED=false
SOURCE_DETECT_HOME_MOUNTED=false

source_detect_list_candidates() {
    local device type removable transport filesystem mountpoints value
    while read -r device type; do
        [[ "${type}" == part || "${type}" == crypt || "${type}" == lvm ]] || continue
        if ! value="$(lsblk --nodeps --noheadings --raw --output RM -- "${device}" 2>/dev/null)"; then
            log_write WARN "Dispositivo ignorado após falha do lsblk: ${device}"
            continue
        fi
        removable="$(source_detect_first_nonempty_line "${value}")"
        if ! value="$(lsblk --inverse --noheadings --raw --output TRAN -- "${device}" 2>/dev/null)"; then
            log_write WARN "Dispositivo ignorado após falha ao consultar transporte: ${device}"
            continue
        fi
        transport="$(source_detect_first_nonempty_line "${value}")"
        if ! value="$(lsblk --nodeps --noheadings --raw --output MOUNTPOINT -- "${device}" 2>/dev/null)"; then
            log_write WARN "Dispositivo ignorado após falha ao consultar montagem: ${device}"
            continue
        fi
        mountpoints="$(source_detect_first_nonempty_line "${value}")"
        [[ "${removable}" == 0 && "${transport}" != usb ]] || continue
        [[ -z "${mountpoints}" || "${mountpoints}" == '-' ]] || continue
        filesystem="$(blkid -o value -s TYPE -- "${device}" 2>/dev/null || true)"
        case "${filesystem}" in
            btrfs|ext2|ext3|ext4|xfs) printf '%s|%s\n' "${device}" "${filesystem}" ;;
        esac
    done < <(lsblk --paths --raw --noheadings --output NAME,TYPE)
}

source_detect_first_nonempty_line() {
    local input=$1 line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -n "${line}" ]]; then
            printf '%s\n' "${line}"
            return 0
        fi
    done <<< "${input}"
    return 0
}

source_detect_mount() {
    local device=$1 filesystem=$2 target=$3
    if [[ "${filesystem}" == btrfs ]]; then
        mount --types btrfs --options ro,nosuid,nodev,subvolid=5 -- "${device}" "${target}"
    else
        mount --types "${filesystem}" --options ro,nosuid,nodev -- "${device}" "${target}"
    fi
}

source_detect_mount_home() {
    local device=$1 subvolume=$2 target=$3
    mount --types btrfs --options "ro,nosuid,nodev,subvol=${subvolume}" -- "${device}" "${target}"
}

source_detect_unmount() { umount -- "$1"; }

source_detect_root_layout() {
    local mount_dir=$1 filesystem=$2
    local -n relative_root_ref=$3
    local -n layout_ref=$4
    if [[ "${filesystem}" == btrfs && -f "${mount_dir}/@rootfs/etc/os-release" &&
          -d "${mount_dir}/@rootfs/usr" && -d "${mount_dir}/@rootfs/var" ]]; then
        relative_root_ref='@rootfs'
        layout_ref='BTRFS + @rootfs'
        return 0
    fi
    if [[ -f "${mount_dir}/etc/os-release" && -d "${mount_dir}/usr" &&
          -d "${mount_dir}/var" ]]; then
        relative_root_ref='.'
        layout_ref='filesystem tradicional'
        return 0
    fi
    return 1
}

source_detect_home_layout() {
    local mount_dir=$1 home_user=$2
    local -n subvolume_ref=$3
    if [[ -d "${mount_dir}/home/${home_user}" ]]; then
        subvolume_ref=home
        return 0
    fi
    if [[ -d "${mount_dir}/@home/${home_user}" ]]; then
        subvolume_ref=@home
        return 0
    fi
    # Em uma partição dedicada a /home, o topo do filesystem pode conter
    # diretamente os diretórios dos usuários, sem um subvolume "home".
    if [[ -d "${mount_dir}/${home_user}" ]]; then
        subvolume_ref=.
        return 0
    fi
    return 1
}

source_detect_create_directory() {
    if [[ -d /var/tmp && -w /var/tmp ]]; then
        mktemp --directory --tmpdir=/var/tmp 'pmjs-source.XXXXXX'
    else
        mktemp --directory --tmpdir=/tmp 'pmjs-source.XXXXXX'
    fi
}

source_detect_probe_mount() {
    source_detect_mount "$1" "$2" "$3"
    SOURCE_DETECT_PROBE_MOUNTED=true
}

source_detect_probe_unmount() {
    source_detect_unmount "$1"
    SOURCE_DETECT_PROBE_MOUNTED=false
}

detect_capture_sources() {
    local home_user=$1
    local -n source_root_ref=$2
    local -n home_source_ref=$3
    local record device filesystem relative_root layout home_subvolume
    local root_device root_filesystem root_relative root_layout
    local home_device home_subvolume_selected
    local probe_dir root_mount home_mount
    local -a candidates=() root_matches=() home_matches=() examined_btrfs=()

    log_write INFO "Procurando instalação Linux..."
    SOURCE_DETECT_DIR="$(source_detect_create_directory)"
    probe_dir="${SOURCE_DETECT_DIR}/probe"
    root_mount="${SOURCE_DETECT_DIR}/root"
    home_mount="${SOURCE_DETECT_DIR}/home"
    mkdir -p -- "${probe_dir}" "${root_mount}" "${home_mount}"
    mapfile -t candidates < <(source_detect_list_candidates)

    for record in "${candidates[@]}"; do
        device=${record%%|*}
        filesystem=${record#*|}
        if source_detect_probe_mount "${device}" "${filesystem}" "${probe_dir}"; then
            if source_detect_root_layout "${probe_dir}" "${filesystem}" relative_root layout; then
                root_matches+=("${device}|${filesystem}|${relative_root}|${layout}")
            fi
            source_detect_probe_unmount "${probe_dir}" || {
                ui_error "Falha ao desmontar probe de root: ${probe_dir}"
                return 1
            }
        fi
    done
    (( ${#root_matches[@]} == 1 )) || {
        ui_error "Esperada uma instalação Linux root; encontradas: ${#root_matches[@]}"
        return 1
    }
    IFS='|' read -r root_device root_filesystem root_relative root_layout <<< "${root_matches[0]}"

    source_detect_probe_mount "${root_device}" "${root_filesystem}" "${probe_dir}"
    if [[ "${root_filesystem}" == btrfs ]] &&
       source_detect_home_layout "${probe_dir}" "${home_user}" home_subvolume; then
        home_device=${root_device}
        home_subvolume_selected=${home_subvolume}
    fi
    source_detect_probe_unmount "${probe_dir}"

    if [[ -z "${home_device:-}" ]]; then
        log_write INFO "Procurando HOME do usuário '${home_user}'..."
        for record in "${candidates[@]}"; do
            device=${record%%|*}
            filesystem=${record#*|}
            [[ "${filesystem}" == btrfs ]] || continue
            examined_btrfs+=("${device}")
            if source_detect_probe_mount "${device}" "${filesystem}" "${probe_dir}"; then
                if source_detect_home_layout "${probe_dir}" "${home_user}" home_subvolume; then
                    home_matches+=("${device}|${home_subvolume}")
                fi
                source_detect_probe_unmount "${probe_dir}"
            fi
        done
        if (( ${#home_matches[@]} != 1 )); then
            ui_error "Home do usuário ${home_user} não encontrada de forma unívoca. Partições BTRFS examinadas: ${examined_btrfs[*]:-(nenhuma)}"
            return 1
        fi
        IFS='|' read -r home_device home_subvolume_selected <<< "${home_matches[0]}"
    fi

    source_detect_mount "${root_device}" "${root_filesystem}" "${root_mount}"
    SOURCE_DETECT_ROOT_MOUNTED=true
    [[ "${root_relative}" == . ]] && source_root_ref=${root_mount} || \
        source_root_ref="${root_mount}/${root_relative}"
    if [[ "${home_device}" == "${root_device}" ]]; then
        if [[ "${home_subvolume_selected}" == . ]]; then
            home_source_ref="${root_mount}/${home_user}"
        else
            home_source_ref="${root_mount}/${home_subvolume_selected}/${home_user}"
        fi
    else
        if [[ "${home_subvolume_selected}" == . ]]; then
            source_detect_mount "${home_device}" btrfs "${home_mount}"
        else
            source_detect_mount_home "${home_device}" "${home_subvolume_selected}" "${home_mount}"
        fi
        SOURCE_DETECT_HOME_MOUNTED=true
        home_source_ref="${home_mount}/${home_user}"
    fi

    log_write INFO "Root encontrado: ${root_device}"
    log_write INFO "Layout root: ${root_layout}"
    log_write INFO "SOURCE_ROOT=${source_root_ref}"
    log_write INFO "Home encontrado: ${home_device}"
    log_write INFO "HOME_SOURCE=${home_source_ref}"
}

validate_detected_capture_source() {
    local source_root=$1
    [[ -f "${source_root}/etc/os-release" ]] || {
        ui_error "Sistema Linux inválido: ausente ${source_root}/etc/os-release"
        return 1
    }
    [[ -f "${source_root}/etc/ocsinventory/ocsinventory-agent.cfg" ]] || {
        ui_error "Configuração OCS ausente em ${source_root}"
        return 1
    }
}

cleanup_detected_capture_source() {
    local resolved_dir parent
    [[ -n "${SOURCE_DETECT_DIR:-}" ]] || return 0
    resolved_dir="$(realpath -m -- "${SOURCE_DETECT_DIR}")"
    parent="$(dirname -- "${resolved_dir}")"
    [[ ( "${parent}" == /var/tmp || "${parent}" == /tmp ) &&
       "$(basename -- "${resolved_dir}")" == pmjs-source.* &&
       ! -L "${resolved_dir}" && -d "${resolved_dir}" ]] || {
        ui_error "Recusa ao limpar origem temporária inesperada: ${SOURCE_DETECT_DIR}"
        return 1
    }
    if [[ "${SOURCE_DETECT_PROBE_MOUNTED}" == true ]]; then
        source_detect_unmount "${resolved_dir}/probe" || return 1
        SOURCE_DETECT_PROBE_MOUNTED=false
    fi
    if [[ "${SOURCE_DETECT_HOME_MOUNTED}" == true ]]; then
        source_detect_unmount "${resolved_dir}/home" || return 1
        SOURCE_DETECT_HOME_MOUNTED=false
    fi
    if [[ "${SOURCE_DETECT_ROOT_MOUNTED}" == true ]]; then
        source_detect_unmount "${resolved_dir}/root" || return 1
        SOURCE_DETECT_ROOT_MOUNTED=false
    fi
    find -P "${resolved_dir}" -depth -delete
    SOURCE_DETECT_DIR=""
}
