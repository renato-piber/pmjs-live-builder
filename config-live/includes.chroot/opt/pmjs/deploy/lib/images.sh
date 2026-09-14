#!/bin/bash

IMAGES_BASE=""
IMAGES_SOURCE=""
IMAGES=()
SELECTED_IMAGE=""

images_candidate_is_valid() {
    local image_dir="$1"

    [ -d "$image_dir" ] || return 1
    if [ -e "$image_dir/manifest.json" ]; then
        (image_contract_probe_schema1 "$image_dir")
        return $?
    fi
    [ -f "$image_dir/rootfs.tar.gz" ] && [ ! -L "$image_dir/rootfs.tar.gz" ] && \
        [ -r "$image_dir/rootfs.tar.gz" ] && [ -s "$image_dir/rootfs.tar.gz" ]
}

images_directory_has_images() {
    local directory="$1"
    local images=()

    [ -d "$directory" ] || return 1

    shopt -s nullglob
    images=(
        "$directory"/pmjs-linux*
    )
    shopt -u nullglob

    local item

    for item in "${images[@]}"; do
        if images_candidate_is_valid "$item"; then
            return 0
        fi
    done

    return 1
}

images_find_offline() {
    local offline_dir="${1:-${OFFLINE_IMAGES_DIR:-$LOCAL_IMAGES_DIR}}"

    if [ -z "$offline_dir" ]; then
        return 1
    fi
    if images_directory_has_images "$offline_dir"; then
        IMAGES_BASE="$offline_dir"
        IMAGES_SOURCE="offline"
        return 0
    fi
    return 1
}

images_find_online() {
    if ! network_mount_nfs; then
        return 1
    fi

    if images_directory_has_images "$NFS_MOUNT"; then
        IMAGES_BASE="$NFS_MOUNT"
        IMAGES_SOURCE="online"
        return 0
    fi

    return 1
}

images_find_local() {
    local local_dir="${1:-$LOCAL_IMAGES_DIR}"

    if [ -z "$local_dir" ]; then
        return 1
    fi

    if images_directory_has_images "$local_dir"; then
        IMAGES_BASE="$local_dir"
        IMAGES_SOURCE="local"
        return 0
    fi

    return 1
} 

images_select_source() {
    local local_path

    ui_clear
    ui_title "$VERSION"

    echo "Etapa 1 de 5 - Origem das imagens"
    echo

    if [ "$PMJS_ENVIRONMENT" = "development" ]; then
        ui_info "Ambiente de desenvolvimento ativo: usando pasta local."
        echo
        read -rp "Caminho da pasta local de imagens [${LOCAL_IMAGES_DIR}]: " local_path
        local_path=${local_path:-$LOCAL_IMAGES_DIR}

        if images_find_local "$local_path"; then
            ui_success "Imagens encontradas na pasta local."
            log_info "Fonte de imagens selecionada: local em $IMAGES_BASE"
            return 0
        fi

        ui_error "Nenhuma imagem encontrada na pasta local especificada."
        return 1
    fi

    ui_info "Ambiente de produção ativo: tentando servidor NFS..."

    if images_find_online; then
        ui_success "Imagens encontradas no servidor."
        log_info "Fonte de imagens selecionada: NFS em $IMAGES_BASE"
        return 0
    fi

    ui_warning "Servidor NFS indisponível ou sem imagens."
    ui_info "Tentando usar o diretório offline configurado como fallback..."

    if images_find_offline "${OFFLINE_IMAGES_DIR:-$LOCAL_IMAGES_DIR}"; then
        ui_success "Imagens encontradas no diretório offline."
        log_info "Fonte de imagens selecionada: offline em $IMAGES_BASE"
        return 0
    fi

    ui_error "Nenhuma fonte de imagens disponível."
    log_error "Não foram encontradas imagens online nem offline."
    return 1
}

images_list() {
    local paths=()
    local path

    shopt -s nullglob
    paths=(
        "$IMAGES_BASE"/pmjs-linux*
    )
    shopt -u nullglob

    for path in "${paths[@]}"; do
        images_candidate_is_valid "$path" || continue
        basename "$path"
    done |
        sort -Vr
}


images_load() {
    mapfile -t IMAGES < <(images_list)
}

images_choose() {
    local option
    local count

    images_load

    count=${#IMAGES[@]}

    if [ "$count" -eq 0 ]; then
        ui_error "Nenhuma imagem disponível."
        return 1
    fi

    echo
    echo "Imagens disponíveis:"
    echo

    for i in "${!IMAGES[@]}"; do
        printf '%2d) %s\n' "$((i + 1))" "${IMAGES[$i]}"
    done

    echo
    read -rp "Escolha a imagem desejada: " option

    if ! [[ "$option" =~ ^[0-9]+$ ]]; then
        ui_error "Digite apenas o número da imagem."
        return 1
    fi

    if [ "$option" -lt 1 ] || [ "$option" -gt "$count" ]; then
        ui_error "Opção de imagem inválida."
        return 1
    fi

    SELECTED_IMAGE="${IMAGES[$((option - 1))]}"
    INSTALL_IMAGE="$SELECTED_IMAGE"
    INSTALL_IMAGE_DIR="$IMAGES_BASE/$INSTALL_IMAGE"

    ui_success "Imagem selecionada: $INSTALL_IMAGE"
    log_info "Imagem selecionada: $INSTALL_IMAGE"
}
