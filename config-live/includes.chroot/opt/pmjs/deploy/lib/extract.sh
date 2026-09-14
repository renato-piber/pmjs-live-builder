#!/bin/bash

EXTRACT_DRY_RUN="${EXTRACT_DRY_RUN:-1}"
EXTRACT_ROOTFS_ARCHIVE=""
EXTRACT_HOMEFS_ARCHIVE=""
EXTRACT_IMAGE_FORMAT=""
EXTRACT_COMPRESSION="gzip"
EXTRACT_SAFE_PATH_ROOTFS_SECONDS=0
EXTRACT_SAFE_PATH_HOMEFS_SECONDS=0
EXTRACT_ROOTFS_SECONDS=0
EXTRACT_HOMEFS_SECONDS=0
EXTRACT_IMAGE_TOTAL_SECONDS=0
INSTALL_EXTRACT_READY=0

extract_is_dry_run() {
    case "${INSTALL_EXECUTION_MODE:-dry-run}" in
        real)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}
extract_log_command() {
    local quoted=""
    local argument=""

    for argument in "$@"; do
        printf -v quoted '%s%q ' "$quoted" "$argument"
    done
    log_info "Comando de extração: ${quoted% }"
}

extract_tar_read_options() {
    local compression="$1"
    local -n options_ref="$2"

    case "$compression" in
        gzip)
            options_ref=(--gzip)
            ;;
        zstd)
            options_ref=(--zstd)
            ;;
        *)
            ui_error "Compressão de imagem não suportada: $compression"
            log_error "Compressão inválida recebida pela extração: $compression"
            return 1
            ;;
    esac
}

extract_build_tar_command() {
    local archive="$1"
    local destination="$2"
    local compression="$3"
    local -n command_ref="$4"
    local -a compression_options=()

    extract_tar_read_options "$compression" compression_options || return 1
    command_ref=(
        tar
        --extract
        "${compression_options[@]}"
        --file "$archive"
        --directory "$destination"
        --numeric-owner
        --acls
        --xattrs
    )
}

extract_append_stderr_to_log() {
    local operation="$1"
    local error_file="$2"

    if [ ! -s "$error_file" ]; then
        return 0
    fi
    if [ -n "${LOG_FILE:-}" ] && [ -w "$LOG_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            printf '%s [ERROR] %s: %s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$operation" \
                "$line"
        done < "$error_file" >> "$LOG_FILE"
    else
        log_error "$operation produziu erro; LOG_FILE não está disponível para registrar os detalhes."
    fi
}

extract_resolve_archives() {
    local image_dir="${INSTALL_IMAGE_DIR:-}"
    local image_name="${INSTALL_IMAGE:-}"

    if [ -z "$image_dir" ] && [ -n "$image_name" ] && [ -n "${IMAGES_BASE:-}" ]; then
        image_dir="$IMAGES_BASE/$image_name"
    fi

    if [ -z "$image_dir" ]; then
        ui_error "Não foi possível identificar o diretório da imagem para extração."
        log_error "Diretório da imagem não definido para extração."
        return 1
    fi

    if [ ! -d "$image_dir" ]; then
        ui_error "O diretório da imagem não existe: $image_dir"
        log_error "Diretório da imagem inválido: $image_dir"
        return 1
    fi

    if [ ! -r "$image_dir" ]; then
        ui_error "O diretório da imagem não é legível: $image_dir"
        log_error "Diretório da imagem sem permissão de leitura: $image_dir"
        return 1
    fi

    INSTALL_IMAGE_DIR=$(realpath -e -- "$image_dir") || return 1
    if [ "$IMAGE_CONTRACT_READY" -ne 1 ] ||
       [ "$IMAGE_CONTRACT_DIR" != "$INSTALL_IMAGE_DIR" ]; then
        image_contract_load "$INSTALL_IMAGE_DIR" "${INSTALL_STORAGE_MODE:-clean}" 1 || {
            ui_error "Imagem inválida: ${IMAGE_CONTRACT_ERROR:-falha no contrato da imagem}"
            return 1
        }
    fi

    EXTRACT_ROOTFS_ARCHIVE="$IMAGE_CONTRACT_ROOTFS_ARCHIVE"
    EXTRACT_HOMEFS_ARCHIVE="$IMAGE_CONTRACT_HOMEFS_ARCHIVE"
    EXTRACT_IMAGE_FORMAT="$IMAGE_CONTRACT_FORMAT"
    EXTRACT_COMPRESSION="$IMAGE_CONTRACT_COMPRESSION"
    log_info "Extração usará imagem $EXTRACT_IMAGE_FORMAT com compressão $EXTRACT_COMPRESSION."

    return 0
}

extract_archive_has_safe_paths() {
    local archive="$1"
    local archive_label="${2:-archive}"
    local compression="${3:-$EXTRACT_COMPRESSION}"
    local entry=""
    local component=""
    local -a parts=()
    local listing_file=""
    local error_file=""
    local unsafe_entry=""
    local -a compression_options=()

    listing_file=$(mktemp /tmp/pmjs-tar-list.XXXXXX) || return 2
    error_file=$(mktemp /tmp/pmjs-tar-list-error.XXXXXX) || {
        rm -f "$listing_file"
        return 2
    }

    extract_tar_read_options "$compression" compression_options || {
        rm -f "$listing_file" "$error_file"
        return 2
    }
    if ! LC_ALL=C tar --list "${compression_options[@]}" --file "$archive" \
        > "$listing_file" 2> "$error_file"; then
        log_error "Falha ao ler a estrutura tar/$compression de $archive_label: $archive"
        extract_append_stderr_to_log "Inspeção de $archive_label" "$error_file"
        rm -f "$listing_file" "$error_file"
        return 2
    fi
    rm -f "$error_file"

    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -n "$entry" ] || continue

        case "$entry" in
            ""|"./")
                continue
                ;;
            /*)
                unsafe_entry="$entry"
                break
                ;;
        esac

        if [ "$entry" = "." ]; then
            continue
        fi

        IFS='/' read -r -a parts <<< "$entry"
        for component in "${parts[@]}"; do
            if [ "$component" = ".." ]; then
                unsafe_entry="$entry"
                break 2
            fi
        done
    done < "$listing_file"
    rm -f "$listing_file"

    if [ -n "$unsafe_entry" ]; then
        log_error "Caminho inseguro encontrado em $archive_label: $unsafe_entry"
        return 1
    fi
    return 0
}

extract_check_archive() {
    local archive="$1"
    local archive_label="$2"
    local compression="${3:-$EXTRACT_COMPRESSION}"
    local inspection_start=0
    local inspection_end=0
    local safe_paths_status=0
    # local archive_size=""
    # local free_space_kb=""
    # local free_space_bytes=""

    if [ -z "$archive" ]; then
        ui_error "O caminho do archive não foi definido: $archive_label"
        log_error "Arquivo de imagem ausente: $archive_label"
        return 1
    fi

    if [ ! -e "$archive" ]; then
        ui_error "O archive não existe: $archive"
        log_error "Arquivo de imagem ausente: $archive"
        return 1
    fi

    if [ ! -f "$archive" ]; then
        ui_error "O caminho não é um arquivo regular: $archive"
        log_error "Arquivo inválido para extração: $archive"
        return 1
    fi

    if [ ! -r "$archive" ]; then
        ui_error "O archive não é legível: $archive"
        log_error "Arquivo sem permissão de leitura: $archive"
        return 1
    fi

    if [ ! -s "$archive" ]; then
        ui_error "O archive está vazio: $archive"
        log_error "Arquivo vazio detectado: $archive"
        return 1
    fi

    inspection_start=$(date +%s)
    log_info "Iniciando inspeção de caminhos seguros do $archive_label: $archive"
    if extract_archive_has_safe_paths "$archive" "$archive_label" "$compression"; then
        safe_paths_status=0
    else
        safe_paths_status=$?
    fi
    inspection_end=$(date +%s)
    case "$archive_label" in
        rootfs)
            EXTRACT_SAFE_PATH_ROOTFS_SECONDS=$((inspection_end - inspection_start))
            ;;
        homefs)
            EXTRACT_SAFE_PATH_HOMEFS_SECONDS=$((inspection_end - inspection_start))
            ;;
    esac
    log_info "Inspeção de caminhos seguros do $archive_label concluída em $((inspection_end - inspection_start)) segundo(s)."

    case "$safe_paths_status" in
        0)
            ;;
        1)
            ui_error "O archive $archive_label contém caminho absoluto ou componente '..'."
            log_error "Archive com caminho inseguro rejeitado: $archive"
            return 1
            ;;
        *)
            ui_error "Não foi possível ler ou validar o archive $archive_label."
            log_error "Archive $archive_label ilegível, corrompido ou inválido para tar/$compression: $archive"
            return 1
            ;;
    esac

    # archive_size=$(stat -c%s "$archive" 2>/dev/null || true)
    # if [ -n "$archive_size" ] && [ "$archive_size" -gt 0 ]; then
    #     free_space_kb=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}' || true)
    #     if [ -n "$free_space_kb" ]; then
    #         free_space_bytes=$((free_space_kb * 1024))
    #         if [ "$free_space_bytes" -lt "$archive_size" ]; then
    #             ui_error "Espaço insuficiente para o archive: $archive"
    #             log_error "Espaço insuficiente para $archive"
    #             return 1
    #         fi
    #     fi
    # fi

    log_info "Archive validado com sucesso: $archive"
    return 0
}

extract_validate() {
    local target_root="${INSTALL_TARGET_ROOT:-$INSTALL_TARGET_MOUNT}"
    local target_home="${INSTALL_TARGET_HOME:-$target_root/home}"
    local target_efi="${INSTALL_TARGET_EFI:-$target_root/boot/efi}"
    local source_root=""
    local source_home=""
    local source_efi=""

    if ! extract_is_dry_run; then
        if [ "${INSTALL_MOUNTS_READY:-0}" -ne 1 ]; then
            ui_error "As partições ainda não estão prontas para extração."
            log_error "INSTALL_MOUNTS_READY não está habilitado."
            return 1
        fi
    fi

    if [ -z "$target_root" ] || [ -z "$target_home" ]; then
        ui_error "Os pontos de montagem de destino não foram definidos."
        log_error "Pontos de montagem ausentes para extração."
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ] && [ -z "$target_efi" ]; then
        ui_error "O ponto de montagem EFI não foi definido."
        log_error "Ponto de montagem EFI ausente para extração UEFI."
        return 1
    fi

    case "$target_root" in
        /|/home|/boot|/boot/efi|/dev|/proc|/sys|/run|/mnt|/tmp|/var|/etc|/usr|/lib|/bin|/sbin|/root)
            ui_error "O destino raiz não é seguro: $target_root"
            log_error "Destino raiz crítico rejeitado: $target_root"
            return 1
            ;;
    esac

    case "$target_home" in
        /|/home|/boot|/boot/efi|/dev|/proc|/sys|/run|/mnt|/tmp|/var|/etc|/usr|/lib|/bin|/sbin|/root)
            ui_error "O destino home não é seguro: $target_home"
            log_error "Destino home crítico rejeitado: $target_home"
            return 1
            ;;
    esac

    if [[ "$target_root" != "$INSTALL_TARGET_MOUNT" && "$target_root" != "$INSTALL_TARGET_MOUNT"/* ]]; then
        ui_error "O destino raiz não está sob o mountpoint configurado: $target_root"
        log_error "Destino raiz fora de INSTALL_TARGET_MOUNT: $target_root"
        return 1
    fi

    if [[ "$target_home" != "$INSTALL_TARGET_MOUNT" && "$target_home" != "$INSTALL_TARGET_MOUNT"/* ]]; then
        ui_error "O destino home não está sob o mountpoint configurado: $target_home"
        log_error "Destino home fora de INSTALL_TARGET_MOUNT: $target_home"
        return 1
    fi

    if ! extract_is_dry_run; then
        if ! mountpoint -q "$target_root"; then
            ui_error "O destino raiz não está montado: $target_root"
            return 1
        fi

        if ! mountpoint -q "$target_home"; then
            ui_error "O destino home não está montado: $target_home"
            return 1
        fi

        if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ] && ! mountpoint -q "$target_efi"; then
            ui_error "O destino EFI não está montado: $target_efi"
            return 1
        fi

        # Consultas findmnt e comparação dos dispositivos ficam aqui.
    fi

    source_root=$(findmnt -rn -M "$target_root" -o SOURCE 2>/dev/null || true)
    source_home=$(findmnt -rn -M "$target_home" -o SOURCE 2>/dev/null || true)
    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
        source_efi=$(findmnt -rn -M "$target_efi" -o SOURCE 2>/dev/null || true)
    fi

    if [ -n "$source_root" ] && [ "$(mounts_resolve_path "$source_root" 2>/dev/null || true)" != "$(mounts_resolve_path "$INSTALL_ROOT_PARTITION" 2>/dev/null || true)" ]; then
        ui_error "A montagem raiz não corresponde ao dispositivo esperado."
        log_error "Montagem raiz inesperada: $source_root"
        return 1
    fi

    if [ -n "$source_home" ] && [ "$(mounts_resolve_path "$source_home" 2>/dev/null || true)" != "$(mounts_resolve_path "$INSTALL_HOME_PARTITION" 2>/dev/null || true)" ]; then
        ui_error "A montagem home não corresponde ao dispositivo esperado."
        log_error "Montagem home inesperada: $source_home"
        return 1
    fi

    if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ] && [ -n "$source_efi" ] && [ "$(mounts_resolve_path "$source_efi" 2>/dev/null || true)" != "$(mounts_resolve_path "$INSTALL_EFI_PARTITION" 2>/dev/null || true)" ]; then
        ui_error "A montagem EFI não corresponde ao dispositivo esperado."
        log_error "Montagem EFI inesperada: $source_efi"
        return 1
    fi

    if ! extract_resolve_archives; then
        return 1
    fi

    if [ -z "$EXTRACT_ROOTFS_ARCHIVE" ]; then
        ui_error "O archive rootfs não foi identificado."
        log_error "Archive rootfs ausente." 
        return 1
    fi

    if ! extract_check_archive "$EXTRACT_ROOTFS_ARCHIVE" "rootfs"; then
        return 1
    fi

    case "${INSTALL_STORAGE_MODE:-}" in
        clean)
            if [ -z "$EXTRACT_HOMEFS_ARCHIVE" ]; then
                ui_error "O archive homefs não foi identificado."
                log_error "Archive homefs ausente no modo clean."
                return 1
            fi

            if ! extract_check_archive "$EXTRACT_HOMEFS_ARCHIVE" "homefs"; then
                return 1
            fi
            ;;
        preserve_home)
            log_info "Modo preserve_home: homefs será ignorado sem extração."
            ;;
        *)
            ui_error "Modo de armazenamento inválido para extração: ${INSTALL_STORAGE_MODE:-não definido}"
            log_error "Modo inválido para extração."
            return 1
            ;;
    esac

    return 0
}

extract_rootfs() {
    local dest="${INSTALL_TARGET_ROOT:-$INSTALL_TARGET_MOUNT}"
    local error_file=""
    local extraction_start=0
    local extraction_end=0
    local extraction_status=0
    local -a tar_command=()

    extract_build_tar_command "$EXTRACT_ROOTFS_ARCHIVE" "$dest" \
        "$EXTRACT_COMPRESSION" tar_command || return 1

    if extract_is_dry_run; then
        extract_log_command "${tar_command[@]}"
        return 0
    fi

    extract_log_command "${tar_command[@]}"

    error_file=$(mktemp /tmp/pmjs-rootfs-extract-error.XXXXXX) || return 1
    extraction_start=$(date +%s)
    log_info "Iniciando extração do rootfs."
    if "${tar_command[@]}" >/dev/null 2>"$error_file"; then
        extraction_status=0
    else
        extraction_status=$?
    fi
    extraction_end=$(date +%s)
    EXTRACT_ROOTFS_SECONDS=$((extraction_end - extraction_start))
    log_info "Extração do rootfs finalizada em $((extraction_end - extraction_start)) segundo(s), código $extraction_status."
    if [ "$extraction_status" -ne 0 ]; then
        ui_error "Falha ao extrair rootfs. Verifique o log para detalhes."
        log_error "Falha na extração do rootfs: $EXTRACT_ROOTFS_ARCHIVE"
        extract_append_stderr_to_log "Extração do rootfs" "$error_file"
        rm -f "$error_file"
        return 1
    fi
    rm -f "$error_file"
    return 0
}

extract_homefs() {
    local dest="${INSTALL_TARGET_HOME:-$INSTALL_TARGET_ROOT/home}"
    local error_file=""
    local extraction_start=0
    local extraction_end=0
    local extraction_status=0
    local -a tar_command=()

    extract_build_tar_command "$EXTRACT_HOMEFS_ARCHIVE" "$dest" \
        "$EXTRACT_COMPRESSION" tar_command || return 1

    if extract_is_dry_run; then
        extract_log_command "${tar_command[@]}"
        return 0
    fi

    extract_log_command "${tar_command[@]}"
    error_file=$(mktemp /tmp/pmjs-homefs-extract-error.XXXXXX) || return 1
    extraction_start=$(date +%s)
    log_info "Iniciando extração do homefs."
    if "${tar_command[@]}" >/dev/null 2>"$error_file"; then
        extraction_status=0
    else
        extraction_status=$?
    fi
    extraction_end=$(date +%s)
    EXTRACT_HOMEFS_SECONDS=$((extraction_end - extraction_start))
    log_info "Extração do homefs finalizada em $((extraction_end - extraction_start)) segundo(s), código $extraction_status."
    if [ "$extraction_status" -ne 0 ]; then
        ui_error "Falha ao extrair homefs. Verifique o log para detalhes."
        log_error "Falha na extração do homefs: $EXTRACT_HOMEFS_ARCHIVE"
        extract_append_stderr_to_log "Extração do homefs" "$error_file"
        rm -f "$error_file"
        return 1
    fi
    rm -f "$error_file"

    return 0
}

extract_sync_final() {
    local sync_start=0
    local sync_end=0
    local sync_status=0

    sync_start=$(date +%s)
    log_info "Iniciando sync final após a extração."
    if log_run_external sync; then
        sync_status=0
    else
        sync_status=$?
    fi
    sync_end=$(date +%s)
    log_info "Sync final concluído em $((sync_end - sync_start)) segundo(s), código $sync_status."
    if [ "$sync_status" -ne 0 ]; then
        ui_error "Falha ao sincronizar os dados extraídos com o disco."
        log_error "sync final da extração retornou código $sync_status."
        return 1
    fi
}

extract_verify() {
    local target_root="${INSTALL_TARGET_ROOT:-$INSTALL_TARGET_MOUNT}"
    local target_home="${INSTALL_TARGET_HOME:-$target_root/home}"

    if [ ! -e "$target_root/etc" ] || [ ! -e "$target_root/usr" ] || [ ! -e "$target_root/var" ]; then
        ui_error "A extração do rootfs não criou os diretórios esperados em $target_root"
        log_error "Verificação do rootfs falhou"
        return 1
    fi

    if [ -e "$target_root/bin/sh" ] || [ -e "$target_root/usr/bin/sh" ]; then
        log_info "Shell encontrado após a extração do rootfs"
    else
        ui_error "O rootfs não forneceu um shell válido em $target_root"
        log_error "Verificação do rootfs falhou"
        return 1
    fi

    case "${INSTALL_STORAGE_MODE:-}" in
        clean)
            if [ ! -d "$target_home" ] || [ -z "$(find "$target_home" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
                ui_error "A extração do homefs não gerou conteúdo válido em $target_home"
                log_error "Verificação do homefs falhou"
                return 1
            fi
            ;;
        preserve_home)
            log_info "Modo preserve_home: a home existente não foi alterada."
            ;;
    esac

    return 0
}

extract_apply_internal() {
    INSTALL_EXTRACT_READY=0

    if ! extract_validate; then
        return 1
    fi

    if extract_is_dry_run; then
        ui_warning "Dry-run de extração ativo: nenhum archive será extraído."
        log_info "Dry-run ativo para extração; somente o plano será registrado."
        INSTALL_EXTRACT_READY=0
        return 0
    fi

    if ! extract_rootfs; then
        return 1
    fi

    case "${INSTALL_STORAGE_MODE:-}" in
        clean)
            if ! extract_homefs; then
                return 1
            fi
            ;;
        preserve_home)
            log_info "Preserve_home ativo: homefs foi ignorado pela Sprint 6.2."
            ;;
    esac

    if ! extract_sync_final; then
        return 1
    fi

    if ! extract_verify; then
        return 1
    fi

    INSTALL_EXTRACT_READY=1
    ui_success "Extração concluída para $INSTALL_TARGET_ROOT e $INSTALL_TARGET_HOME"
    log_info "Extração concluída para $INSTALL_DISK"

    return 0
}

extract_apply() {
    local images_started=0
    local images_finished=0
    local status=0

    EXTRACT_SAFE_PATH_ROOTFS_SECONDS=0
    EXTRACT_SAFE_PATH_HOMEFS_SECONDS=0
    EXTRACT_ROOTFS_SECONDS=0
    EXTRACT_HOMEFS_SECONDS=0
    images_started=$(date +%s)
    if extract_apply_internal; then
        status=0
    else
        status=$?
    fi
    images_finished=$(date +%s)
    EXTRACT_IMAGE_TOTAL_SECONDS=$((images_finished - images_started + ${IMAGE_CONTRACT_SHA256_TOTAL_SECONDS:-0}))
    log_info "Tempo total acumulado da etapa de imagens: $EXTRACT_IMAGE_TOTAL_SECONDS segundo(s), código $status."
    log_info "Métricas de imagens: sha256=${IMAGE_CONTRACT_SHA256_TOTAL_SECONDS:-0}s; safe-path-rootfs=${EXTRACT_SAFE_PATH_ROOTFS_SECONDS}s; safe-path-homefs=${EXTRACT_SAFE_PATH_HOMEFS_SECONDS}s; extract-rootfs=${EXTRACT_ROOTFS_SECONDS}s; extract-homefs=${EXTRACT_HOMEFS_SECONDS}s."
    return "$status"
}
