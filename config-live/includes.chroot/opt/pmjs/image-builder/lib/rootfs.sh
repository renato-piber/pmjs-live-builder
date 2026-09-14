#!/usr/bin/env bash

build_tar_command() {
    local source_root=$1
    local build_dir=$2
    local archive_file=$3
    local generalization_staging=$4
    local compression=${5:-gzip}
    local zstd_level=${6:-3}
    local output_pattern
    local -n command_ref=$7
    local -a compression_options

    output_pattern="$(realpath -m --relative-to="${source_root}" "${build_dir}")"
    output_pattern="./${output_pattern#./}"

    archive_tar_create_options "${compression}" "${zstd_level}" compression_options
    command_ref=(
        tar
        --create
        "${compression_options[@]}"
        --file "${archive_file}"
        --numeric-owner
        --acls
        --xattrs
        --one-file-system
        --exclude='./proc'
        --exclude='./sys'
        --exclude='./dev'
        --exclude='./run'
        --exclude='./tmp/*'
        --exclude='./var/tmp/*'
        --exclude='./mnt/*'
        --exclude='./media/*'
        --exclude='./home/*'
        --exclude='./lost+found'
        --exclude='./etc/machine-id'
        --exclude='./var/lib/dbus/machine-id'
        --exclude='./etc/ssh/ssh_host_*'
        --exclude='./etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf'
        --exclude='./var/lib/ocsinventory-agent'
        --exclude='./var/lib/ocsinventory-agent/*'
        --exclude='./var/cache/ocsinventory-agent'
        --exclude='./var/cache/ocsinventory-agent/*'
        --exclude='./var/log/ocsinventory-client'
        --exclude='./var/log/ocsinventory-client/*'
        --exclude="${output_pattern}"
        --exclude="${output_pattern}/*"
        '--transform=flags=r;s#^\./\.pmjs-generalization/etc/systemd/system/ssh\.service\.d/10-pmjs-generate-host-keys\.conf$#./etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf#'
        --directory="${source_root}"
        .
        --directory="${generalization_staging}"
        ./.pmjs-generalization/etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf
    )
}

generate_rootfs() {
    local source_root=$1
    local build_dir=$2
    local archive_file=$3
    local generalization_staging=$4
    local compression=${5:-gzip}
    local zstd_level=${6:-3}
    local -a tar_command
    local quoted_command

    build_tar_command "${source_root}" "${build_dir}" "${archive_file}" \
        "${generalization_staging}" "${compression}" "${zstd_level}" tar_command
    printf -v quoted_command '%q ' "${tar_command[@]}"
    log_write INFO "Comando tar efetivo: ${quoted_command% }"
    log_write INFO "Executando GNU tar para capturar ${source_root}"
    "${tar_command[@]}" 2> >(while IFS= read -r line; do log_write WARN "tar: ${line}"; done)
}

validate_rootfs() {
    local archive_file=$1
    local source_root=$2
    local build_dir=$3
    local compression=${4:-gzip}
    local entry
    local output_pattern
    local listing
    local required_entry
    local generalization_entry_count
    local generalization_content expected_generalization_content
    local -a read_options
    local required_entries=(
        ./etc/passwd
        ./etc/group
        ./etc/hostname
        ./etc/ssh/sshd_config
        ./etc/ocsinventory/ocsinventory-agent.cfg
        ./etc/x11vnc.pass
        ./usr/sbin/sshd
        ./etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf
    )

    output_pattern="$(realpath -m --relative-to="${source_root}" "${build_dir}")"
    output_pattern="./${output_pattern#./}"

    [[ -s "${archive_file}" ]] || {
        ui_error "O rootfs gerado está vazio: ${archive_file}"
        return 1
    }
    validate_archive_compression "${archive_file}" "${compression}" || {
        ui_error "Falha na integridade ${compression}: ${archive_file}"
        return 1
    }

    archive_tar_read_options "${compression}" read_options
    listing="$(tar --list "${read_options[@]}" --file "${archive_file}")" || {
        ui_error "Falha ao listar o rootfs: ${archive_file}"
        return 1
    }

    while IFS= read -r entry; do
        if [[ "${entry}" == "${output_pattern}" ||
              "${entry}" == "${output_pattern}/"* ]]; then
            ui_error "O diretório de saída foi encontrado no archive: ${entry}"
            return 1
        fi
        case "${entry}" in
            ./proc|./proc/*|./sys|./sys/*|./dev|./dev/*|./run|./run/*|\
            ./tmp/?*|./var/tmp/?*|./mnt/?*|./media/?*|./home/?*|\
            ./lost+found|./lost+found/*|./etc/machine-id|\
            ./var/lib/dbus/machine-id|\
            ./etc/ssh/ssh_host_*|./var/lib/ocsinventory-agent|\
            ./var/lib/ocsinventory-agent/*|./var/cache/ocsinventory-agent|\
            ./var/cache/ocsinventory-agent/*|./var/log/ocsinventory-client|\
            ./var/log/ocsinventory-client/*)
                ui_error "Conteúdo proibido encontrado no archive: ${entry}"
                return 1
                ;;
        esac
    done <<< "${listing}"

    for required_entry in "${required_entries[@]}"; do
        grep -Fqx -- "${required_entry}" <<< "${listing}" || {
            ui_error "Entrada essencial ausente do rootfs: ${required_entry}"
            return 1
        }
    done

    generalization_entry_count="$(grep -Fxc -- \
        './etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf' \
        <<< "${listing}")"
    [[ "${generalization_entry_count}" -eq 1 ]] || {
        ui_error "O mecanismo de regeneração SSH deve aparecer exatamente uma vez no rootfs"
        return 1
    }

    generalization_content="$(tar --extract --to-stdout "${read_options[@]}" \
        --file "${archive_file}" \
        ./etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf)" || {
        ui_error "Falha ao ler o mecanismo de regeneração SSH do rootfs"
        return 1
    }
    expected_generalization_content="$(printf '%s\n' \
        '[Service]' \
        'ExecStartPre=' \
        'ExecStartPre=/usr/bin/ssh-keygen -A' \
        'ExecStartPre=/usr/sbin/sshd -t')"
    [[ "${generalization_content}" == "${expected_generalization_content}" ]] || {
        ui_error "Regeneração de host keys SSH ausente do rootfs"
        return 1
    }

    tar --list "${read_options[@]}" --file "${archive_file}" >/dev/null
    log_write INFO "Integridade e exclusões do rootfs validadas"
}

format_file_size() {
    local file=$1
    local bytes

    bytes="$(stat -c '%s' -- "${file}")"
    if (( bytes >= 1024 * 1024 * 1024 )); then
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
    elif (( bytes >= 1024 * 1024 )); then
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f MiB", bytes / 1048576 }'
    else
        awk -v bytes="${bytes}" 'BEGIN { printf "%.2f KiB", bytes / 1024 }'
    fi
}
