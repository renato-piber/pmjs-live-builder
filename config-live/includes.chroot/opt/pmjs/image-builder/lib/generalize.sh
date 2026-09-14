#!/usr/bin/env bash

validate_generalization_source() {
    local source_root=$1
    local dbus_machine_id="${source_root%/}/var/lib/dbus/machine-id"
    local link_target
    local resolved_target

    if [[ -L "${dbus_machine_id}" ]]; then
        link_target="$(readlink -- "${dbus_machine_id}")"
        if [[ "${link_target}" == /* ]]; then
            resolved_target="${source_root%/}${link_target}"
        else
            resolved_target="$(realpath -m -- "$(dirname -- "${dbus_machine_id}")/${link_target}")"
        fi
        [[ "${resolved_target}" == "${source_root%/}/etc/machine-id" ]] || {
            ui_error "/var/lib/dbus/machine-id não aponta para /etc/machine-id"
            return 1
        }
    elif [[ -e "${dbus_machine_id}" ]]; then
        [[ -f "${dbus_machine_id}" ]] || {
            ui_error "Tipo inesperado em /var/lib/dbus/machine-id"
            return 1
        }
    fi
}

prepare_generalization_staging() {
    local build_dir=$1
    local -n staging_ref=$2
    local dropin_dir

    staging_ref="$(mktemp --directory --tmpdir="${build_dir}" '.rootfs-generalize.XXXXXX')"
    dropin_dir="${staging_ref}/.pmjs-generalization/etc/systemd/system/ssh.service.d"
    install -d -m 0755 -- "${dropin_dir}"
    printf '%s\n' \
        '[Service]' \
        'ExecStartPre=' \
        'ExecStartPre=/usr/bin/ssh-keygen -A' \
        'ExecStartPre=/usr/sbin/sshd -t' \
        > "${dropin_dir}/10-pmjs-generate-host-keys.conf"
    chmod 0644 -- "${dropin_dir}/10-pmjs-generate-host-keys.conf"
}

validate_generalization_staging() {
    local staging_dir=$1
    local dropin="${staging_dir}/.pmjs-generalization/etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf"
    local expected actual expected_owner

    [[ -f "${dropin}" && ! -L "${dropin}" ]] || {
        ui_error "Drop-in de regeneração SSH ausente ou inválido no overlay"
        return 1
    }
    expected="$(printf '%s\n' \
        '[Service]' \
        'ExecStartPre=' \
        'ExecStartPre=/usr/bin/ssh-keygen -A' \
        'ExecStartPre=/usr/sbin/sshd -t')"
    actual="$(<"${dropin}")"
    [[ "${actual}" == "${expected}" ]] || {
        ui_error "Conteúdo inválido no drop-in de regeneração SSH do overlay"
        return 1
    }
    expected_owner="$(id -u):$(id -g)"
    [[ "$(stat -c '%a:%u:%g' -- "${dropin}")" == "644:${expected_owner}" ]] || {
        ui_error "Permissões ou owner inválidos no drop-in de regeneração SSH"
        return 1
    }
}

cleanup_generalization_staging() {
    local staging_dir=$1
    local build_dir=$2
    local resolved_staging resolved_build

    [[ -n "${staging_dir}" && -e "${staging_dir}" ]] || return 0
    resolved_staging="$(realpath -m -- "${staging_dir}")"
    resolved_build="$(realpath -m -- "${build_dir}")"
    [[ "$(dirname -- "${resolved_staging}")" == "${resolved_build}" &&
       "$(basename -- "${resolved_staging}")" == .rootfs-generalize.* &&
       ! -L "${resolved_staging}" && -d "${resolved_staging}" ]] || {
        ui_error "Recusa ao limpar staging inesperado: ${staging_dir}"
        return 1
    }
    find -P "${resolved_staging}" -depth -delete
}
