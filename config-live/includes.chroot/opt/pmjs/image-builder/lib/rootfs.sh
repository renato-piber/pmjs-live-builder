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
    local quoted_command perf_started perf_context perf_size status

    build_tar_command "${source_root}" "${build_dir}" "${archive_file}" \
        "${generalization_staging}" "${compression}" "${zstd_level}" tar_command
    printf -v quoted_command '%q ' "${tar_command[@]}"
    log_write INFO "Comando tar efetivo: ${quoted_command% }"
    log_write INFO "Executando GNU tar para capturar ${source_root}"
    perf_context="$(perf_archive_context "${archive_file}")"
    perf_operation_start rootfs.create perf_started \
        "source=$(printf '%q' "${source_root}") ${perf_context} access=source_read+archive_write"
    if "${tar_command[@]}" 2> >(while IFS= read -r line; do log_write WARN "tar: ${line}"; done); then
        status=0
    else
        status=$?
    fi
    perf_size="$(stat -c '%s' -- "${archive_file}" 2>/dev/null || true)"
    perf_context="$(perf_archive_context "${archive_file}")"
    perf_operation_end rootfs.create "${perf_started}" "${status}" \
        "${perf_size}" compressed_output "${perf_context} access=source_read+archive_write"
    (( status == 0 )) || return "${status}"
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
    local perf_started perf_context perf_size status
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
    perf_size="$(stat -c '%s' -- "${archive_file}" 2>/dev/null || true)"
    perf_context="$(perf_archive_context "${archive_file}")"
    perf_operation_start "rootfs.integrity.${compression}" perf_started \
        "${perf_context} access=full_read+full_decompression"
    if validate_archive_compression "${archive_file}" "${compression}"; then
        status=0
    else
        status=$?
    fi
    perf_operation_end "rootfs.integrity.${compression}" "${perf_started}" "${status}" \
        "${perf_size}" compressed_input "${perf_context} access=full_read+full_decompression"
    (( status == 0 )) || {
        ui_error "Falha na integridade ${compression}: ${archive_file}"
        return 1
    }

    archive_tar_read_options "${compression}" read_options
    perf_operation_start rootfs.tar_listing.members perf_started \
        "${perf_context} access=full_read+full_decompression"
    if listing="$(tar --list "${read_options[@]}" --file "${archive_file}")"; then
        status=0
    else
        status=$?
    fi
    perf_operation_end rootfs.tar_listing.members "${perf_started}" "${status}" \
        "${perf_size}" compressed_input "${perf_context} access=full_read+full_decompression"
    (( status == 0 )) || {
        ui_error "Falha ao listar o rootfs: ${archive_file}"
        return 1
    }

    perf_operation_start rootfs.members.safety_and_exclusions perf_started \
        "archive_listing=in_memory access=no_archive_read"
    while IFS= read -r entry; do
        if [[ "${entry}" == "${output_pattern}" ||
              "${entry}" == "${output_pattern}/"* ]]; then
            ui_error "O diretório de saída foi encontrado no archive: ${entry}"
            perf_operation_end rootfs.members.safety_and_exclusions "${perf_started}" 1 \
                "" none "archive_listing=in_memory access=no_archive_read"
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
                perf_operation_end rootfs.members.safety_and_exclusions "${perf_started}" 1 \
                    "" none "archive_listing=in_memory access=no_archive_read"
                return 1
                ;;
        esac
    done <<< "${listing}"
    perf_operation_end rootfs.members.safety_and_exclusions "${perf_started}" 0 \
        "" none "archive_listing=in_memory access=no_archive_read"

    perf_operation_start rootfs.members.required perf_started \
        "archive_listing=in_memory access=no_archive_read"
    for required_entry in "${required_entries[@]}"; do
        grep -Fqx -- "${required_entry}" <<< "${listing}" || {
            ui_error "Entrada essencial ausente do rootfs: ${required_entry}"
            perf_operation_end rootfs.members.required "${perf_started}" 1 \
                "" none "archive_listing=in_memory access=no_archive_read"
            return 1
        }
    done
    perf_operation_end rootfs.members.required "${perf_started}" 0 \
        "" none "archive_listing=in_memory access=no_archive_read"

    perf_operation_start rootfs.generalization.entry_count perf_started \
        "archive_listing=in_memory access=no_archive_read"
    generalization_entry_count="$(grep -Fxc -- \
        './etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf' \
        <<< "${listing}")"
    [[ "${generalization_entry_count}" -eq 1 ]] || {
        ui_error "O mecanismo de regeneração SSH deve aparecer exatamente uma vez no rootfs"
        perf_operation_end rootfs.generalization.entry_count "${perf_started}" 1 \
            "" none "archive_listing=in_memory access=no_archive_read"
        return 1
    }
    perf_operation_end rootfs.generalization.entry_count "${perf_started}" 0 \
        "" none "archive_listing=in_memory access=no_archive_read"

    perf_operation_start rootfs.generalization.content perf_started \
        "${perf_context} access=full_read+full_decompression target_member=archive_tail"
    if generalization_content="$(tar --extract --to-stdout "${read_options[@]}" \
        --file "${archive_file}" \
        ./etc/systemd/system/ssh.service.d/10-pmjs-generate-host-keys.conf)"; then
        status=0
    else
        status=$?
    fi
    perf_operation_end rootfs.generalization.content "${perf_started}" "${status}" \
        "${perf_size}" compressed_input \
        "${perf_context} access=full_read+full_decompression target_member=archive_tail"
    (( status == 0 )) || {
        ui_error "Falha ao ler o mecanismo de regeneração SSH do rootfs"
        return 1
    }
    expected_generalization_content="$(printf '%s\n' \
        '[Service]' \
        'ExecStartPre=' \
        'ExecStartPre=/usr/bin/ssh-keygen -A' \
        'ExecStartPre=/usr/sbin/sshd -t')"
    perf_operation_start rootfs.generalization.semantic_validation perf_started \
        "extracted_member=in_memory access=no_archive_read"
    [[ "${generalization_content}" == "${expected_generalization_content}" ]] || {
        ui_error "Regeneração de host keys SSH ausente do rootfs"
        perf_operation_end rootfs.generalization.semantic_validation "${perf_started}" 1 \
            "" none "extracted_member=in_memory access=no_archive_read"
        return 1
    }
    perf_operation_end rootfs.generalization.semantic_validation "${perf_started}" 0 \
        "" none "extracted_member=in_memory access=no_archive_read"

    # A listagem capturada acima ja percorreu o tar ate EOF e teve seu status
    # conferido. Todas as validacoes de nomes usam exatamente essa listagem;
    # repetir tar --list aqui nao acrescentava uma propriedade nova.
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
