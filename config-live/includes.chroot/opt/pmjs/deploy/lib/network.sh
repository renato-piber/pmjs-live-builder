#!/bin/bash

network_find_ping() {
    local ping_bin=""

    ping_bin=$(command -v ping 2>/dev/null || true)
    if [ -n "$ping_bin" ] && [ -x "$ping_bin" ]; then
        printf '%s\n' "$ping_bin"
        return 0
    fi
    if [ -x /bin/ping ]; then
        printf '%s\n' /bin/ping
        return 0
    fi
    if [ -x /usr/bin/ping ]; then
        printf '%s\n' /usr/bin/ping
        return 0
    fi
    return 1
}

network_find_showmount() {
    local showmount_bin=""

    showmount_bin=$(command -v showmount 2>/dev/null || true)
    if [ -n "$showmount_bin" ] && [ -x "$showmount_bin" ]; then
        printf '%s\n' "$showmount_bin"
        return 0
    fi
    if [ -x /usr/sbin/showmount ]; then
        printf '%s\n' /usr/sbin/showmount
        return 0
    fi
    return 1
}

network_server_reachable() {
    local ping_bin=""

    if ! ping_bin=$(network_find_ping); then
        log_info "Diagnóstico por ping ignorado: comando não disponível no ambiente Live."
        return 0
    fi

    log_info "Executando diagnóstico opcional por ping para o servidor NFS $NFS_SERVER."
    if timeout "$NETWORK_TIMEOUT" \
        "$ping_bin" -c 1 "$NFS_SERVER" >/dev/null 2>&1; then
        log_info "Servidor NFS respondeu ao ping: $NFS_SERVER"
        return 0
    fi

    log_warning "Servidor NFS não respondeu ao ping; a validação continuará via showmount e montagem."
    return 0
}

network_validate_nfs_export() {
    local showmount_bin=""
    local exports_output=""
    local showmount_status=0

    if ! showmount_bin=$(network_find_showmount); then
        ui_error "O comando showmount não está disponível. Instale o pacote nfs-common no ambiente Live."
        log_error "Teste NFS não executado: showmount ausente no PATH e em /usr/sbin/showmount."
        return 1
    fi

    log_info "Consultando exports NFS com $showmount_bin -e $NFS_SERVER"
    if exports_output=$(timeout "$NETWORK_TIMEOUT" \
        "$showmount_bin" -e "$NFS_SERVER" 2>&1); then
        :
    else
        showmount_status=$?
        if [ "$showmount_status" -eq 124 ]; then
            ui_error "A consulta dos exports NFS expirou para $NFS_SERVER."
            log_error "Timeout ao executar $showmount_bin -e $NFS_SERVER."
        else
            ui_error "Não foi possível consultar os exports NFS de $NFS_SERVER."
            log_error "showmount falhou com código $showmount_status: ${exports_output:-sem mensagem}"
        fi
        return 1
    fi

    if ! awk -v expected="$NFS_EXPORT" '
        $1 == expected { found=1 }
        END { exit(found ? 0 : 1) }
    ' <<< "$exports_output"; then
        ui_error "O export esperado $NFS_EXPORT não foi publicado por $NFS_SERVER."
        log_error "Export NFS ausente em $NFS_SERVER: esperado $NFS_EXPORT."
        return 1
    fi

    ui_success "Export NFS confirmado: $NFS_SERVER:$NFS_EXPORT"
    log_info "Export NFS esperado encontrado: $NFS_SERVER:$NFS_EXPORT"
}

network_validate_nfs_server() {
    network_server_reachable || true
    network_validate_nfs_export || return 1
}

network_mount_nfs() {
    local mount_status=0

    if [ "${PMJS_ENVIRONMENT:-}" = "development" ]; then
        ui_warning "Ambiente development ativo; a montagem NFS foi pulada por segurança."
        log_warning "Teste e montagem NFS ignorados no ambiente development."
        return 1
    fi

    if ! network_validate_nfs_server; then
        return 1
    fi

    if mountpoint -q "$NFS_MOUNT"; then
        ui_success "O ponto de montagem NFS já está pronto: $NFS_MOUNT"
        log_info "Montagem NFS já existente em $NFS_MOUNT."
        return 0
    fi

    if ! mkdir -p "$NFS_MOUNT"; then
        ui_error "Não foi possível criar o ponto de montagem NFS: $NFS_MOUNT"
        log_error "Falha ao criar diretório de montagem NFS: $NFS_MOUNT"
        return 1
    fi

    if log_run_external timeout "$NETWORK_TIMEOUT" \
        mount -t nfs \
        "$NFS_SERVER:$NFS_EXPORT" \
        "$NFS_MOUNT"; then
        ui_success "Servidor NFS montado com sucesso em $NFS_MOUNT"
        log_info "Montagem NFS concluída: $NFS_SERVER:$NFS_EXPORT em $NFS_MOUNT"
        return 0
    else
        mount_status=$?
    fi

    if [ "$mount_status" -eq 124 ]; then
        ui_error "A montagem de $NFS_SERVER:$NFS_EXPORT expirou."
        log_error "Timeout ao montar NFS em $NFS_MOUNT."
    else
        ui_error "Falha ao montar o servidor NFS $NFS_SERVER:$NFS_EXPORT em $NFS_MOUNT."
        log_error "mount -t nfs retornou código $mount_status para $NFS_SERVER:$NFS_EXPORT."
    fi
    return 1
}

network_unmount_nfs() {
    if mountpoint -q "$NFS_MOUNT"; then
        if ! log_run_external umount "$NFS_MOUNT"; then
            ui_error "Falha ao desmontar o NFS em $NFS_MOUNT."
            log_error "umount retornou erro para $NFS_MOUNT."
            return 1
        fi
    fi
}
