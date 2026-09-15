#!/bin/bash

IMAGES_BASE=""
IMAGES_SOURCE=""
IMAGES=()
SELECTED_IMAGE=""
PMJS_OFFLINE_MOUNT_OWNED=0
PMJS_OFFLINE_MOUNT_SOURCE=""
PMJS_OFFLINE_MOUNT_TARGET=""
PMJS_OFFLINE_MOUNT_ID=""
PMJS_OFFLINE_UDEV_TRIGGERED=0

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

images_offline_mountpoint_is_safe() {
    local mountpoint="$1"
    local resolved=""

    [ -n "$mountpoint" ] || return 1
    [[ "$mountpoint" = /mnt/* ]] || return 1
    [[ "$mountpoint" != *[[:space:]]* ]] || return 1
    resolved=$(realpath -m -- "$mountpoint") || return 1
    [ "$resolved" = "$mountpoint" ] || return 1
    [ ! -L "$mountpoint" ] || return 1
}

images_offline_validate_config() {
    local fstype

    images_offline_mountpoint_is_safe "${OFFLINE_MOUNTPOINT:-}" || {
        ui_error "OFFLINE_MOUNTPOINT vazio, não canônico ou inseguro: ${OFFLINE_MOUNTPOINT:-vazio}"
        log_error "Descoberta offline recusou OFFLINE_MOUNTPOINT inseguro: ${OFFLINE_MOUNTPOINT:-vazio}."
        return 1
    }
    [[ "${OFFLINE_IMAGES_SUBDIR:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
        [ "${OFFLINE_IMAGES_SUBDIR}" != "." ] &&
        [ "${OFFLINE_IMAGES_SUBDIR}" != ".." ] || {
        ui_error "OFFLINE_IMAGES_SUBDIR inválido: ${OFFLINE_IMAGES_SUBDIR:-vazio}"
        return 1
    }
    [ -n "${OFFLINE_VOLUME_LABEL:-}" ] &&
        [[ "${OFFLINE_VOLUME_LABEL}" != */* ]] &&
        [[ "${OFFLINE_VOLUME_LABEL}" != *[[:cntrl:]]* ]] || {
        ui_error "OFFLINE_VOLUME_LABEL inválido."
        return 1
    }
    [[ "${OFFLINE_ALLOWED_FSTYPES:-}" =~ ^[A-Za-z0-9._+-]+(\ [A-Za-z0-9._+-]+)*$ ]] || {
        ui_error "OFFLINE_ALLOWED_FSTYPES está vazio ou possui sintaxe inválida."
        return 1
    }
    for fstype in ${OFFLINE_ALLOWED_FSTYPES}; do
        [[ "$fstype" =~ ^[A-Za-z0-9._+-]+$ ]] || {
            ui_error "Filesystem inválido em OFFLINE_ALLOWED_FSTYPES: $fstype"
            return 1
        }
    done
}

images_offline_check_dependencies() {
    local dependency

    for dependency in lsblk blkid findmnt mount umount realpath basename awk sort find; do
        command -v "$dependency" >/dev/null 2>&1 || {
            ui_error "Dependência ausente para descoberta offline: $dependency"
            log_error "Descoberta Ventoy requer o comando $dependency."
            return 1
        }
    done
}

images_offline_list_partitions() {
    lsblk -rpn -o NAME,TYPE 2>/dev/null |
        awk '$2 == "part" && $1 ~ /^\/dev\// { print $1 }' |
        sort -u
}

images_offline_device_property() {
    local device="$1"
    local property="$2"
    local value=""

    value=$(lsblk -dn -o "$property" -- "$device" 2>/dev/null |
        awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }')
    if [ -z "$value" ]; then
        case "$property" in
            LABEL) value=$(blkid -s LABEL -o value -- "$device" 2>/dev/null || true) ;;
            FSTYPE) value=$(blkid -s TYPE -o value -- "$device" 2>/dev/null || true) ;;
        esac
    fi
    printf '%s\n' "$value"
}

images_offline_fstype_is_allowed() {
    local fstype="${1,,}"
    local allowed

    [[ "$fstype" =~ ^[a-z0-9._+-]+$ ]] || return 1
    for allowed in ${OFFLINE_ALLOWED_FSTYPES}; do
        [ "${allowed,,}" = "$fstype" ] && return 0
    done
    return 1
}

images_offline_candidate_is_ventoy() {
    local device="$1"
    local label fstype transport parent

    case "$device" in
        /dev/mapper/*) return 1 ;;
    esac
    label=$(images_offline_device_property "$device" LABEL)
    [ "$label" = "$OFFLINE_VOLUME_LABEL" ] || return 1
    fstype=$(images_offline_device_property "$device" FSTYPE)
    images_offline_fstype_is_allowed "$fstype" || return 1

    transport=$(images_offline_device_property "$device" TRAN)
    if [ "${transport,,}" != usb ]; then
        parent=$(images_offline_device_property "$device" PKNAME)
        [ -n "$parent" ] || return 1
        [[ "$parent" = /dev/* ]] || parent="/dev/$parent"
        transport=$(images_offline_device_property "$parent" TRAN)
    fi
    [ "${transport,,}" = usb ]
}

images_offline_mapper_path() {
    printf '/dev/mapper/%s\n' "$(basename -- "$1")"
}

images_offline_mapper_exists() {
    [ -b "$1" ]
}

images_offline_is_ventoy_boot() {
    local live_source=""

    live_source=$(findmnt -rn -o SOURCE --target /run/live/medium 2>/dev/null |
        awk 'NF { print; exit }')
    case "$live_source" in
        /dev/mapper/ventoy|/dev/mapper/ventoy\[*\]) return 0 ;;
    esac
    return 1
}

images_offline_run_udev_trigger() {
    udevadm trigger
}

images_offline_run_udev_settle() {
    udevadm settle
}

images_offline_run_udev() {
    command -v udevadm >/dev/null 2>&1 || {
        ui_error "O mapper do Ventoy ainda não existe e udevadm não está disponível."
        return 1
    }
    log_info "Mapper da partição Ventoy ausente; acionando udev uma única vez."
    images_offline_run_udev_trigger || {
        ui_error "udevadm trigger falhou durante a descoberta do Ventoy."
        return 1
    }
    images_offline_run_udev_settle || {
        ui_error "udevadm settle falhou durante a descoberta do Ventoy."
        return 1
    }
    PMJS_OFFLINE_UDEV_TRIGGERED=1
}

images_offline_resolve_mount_device() {
    local partition="$1"
    local output_variable="$2"
    local mapper=""

    mapper=$(images_offline_mapper_path "$partition")
    if images_offline_mapper_exists "$mapper"; then
        printf -v "$output_variable" '%s' "$mapper"
        return 0
    fi
    if images_offline_is_ventoy_boot; then
        if [ "$PMJS_OFFLINE_UDEV_TRIGGERED" -ne 1 ]; then
            images_offline_run_udev || return 1
        fi
        if ! images_offline_mapper_exists "$mapper"; then
            ui_error "O mapper esperado do Ventoy não apareceu após udevadm settle: $mapper"
            log_error "Partição Ventoy $partition descoberta, mas mapper $mapper permanece ausente."
            return 1
        fi
        printf -v "$output_variable" '%s' "$mapper"
        return 0
    fi
    printf -v "$output_variable" '%s' "$partition"
}

images_offline_findmnt_targets() {
    findmnt -rn -S "$1" -o TARGET 2>/dev/null || true
}

images_offline_findmnt_record() {
    findmnt -rn -o ID,SOURCE,TARGET,FSTYPE,OPTIONS --mountpoint "$1" 2>/dev/null |
        awk 'NF { print; exit }'
}

images_offline_devices_are_same() {
    local first="$1"
    local second="$2"
    local first_resolved second_resolved

    [ "$first" = "$second" ] && return 0
    first_resolved=$(realpath -e -- "$first" 2>/dev/null || true)
    second_resolved=$(realpath -e -- "$second" 2>/dev/null || true)
    [ -n "$first_resolved" ] && [ "$first_resolved" = "$second_resolved" ]
}

images_offline_parse_mount_record() {
    local record="$1"

    PMJS_OFFLINE_CONFIRMED_ID=""
    PMJS_OFFLINE_CONFIRMED_SOURCE=""
    PMJS_OFFLINE_CONFIRMED_TARGET=""
    PMJS_OFFLINE_CONFIRMED_FSTYPE=""
    PMJS_OFFLINE_CONFIRMED_OPTIONS=""
    read -r PMJS_OFFLINE_CONFIRMED_ID PMJS_OFFLINE_CONFIRMED_SOURCE \
        PMJS_OFFLINE_CONFIRMED_TARGET PMJS_OFFLINE_CONFIRMED_FSTYPE \
        PMJS_OFFLINE_CONFIRMED_OPTIONS <<< "$record"
    [ -n "$PMJS_OFFLINE_CONFIRMED_ID" ] &&
        [ -n "$PMJS_OFFLINE_CONFIRMED_SOURCE" ] &&
        [ -n "$PMJS_OFFLINE_CONFIRMED_TARGET" ]
}

images_offline_validate_mount_record() {
    local expected_source="$1"
    local expected_target="$2"
    local require_read_only="${3:-0}"
    local record=""

    record=$(images_offline_findmnt_record "$expected_target")
    images_offline_parse_mount_record "$record" || return 1
    [ "$PMJS_OFFLINE_CONFIRMED_TARGET" = "$expected_target" ] || return 1
    images_offline_devices_are_same "$PMJS_OFFLINE_CONFIRMED_SOURCE" \
        "$expected_source" || return 1
    images_offline_fstype_is_allowed "$PMJS_OFFLINE_CONFIRMED_FSTYPE" || return 1
    if [ "$require_read_only" -eq 1 ]; then
        case ",$PMJS_OFFLINE_CONFIRMED_OPTIONS," in
            *,ro,*) ;;
            *) return 1 ;;
        esac
    fi
}

images_offline_find_existing_mount() {
    local partition="$1"
    local output_variable="$2"
    local mapper target base
    local saw_mount=0
    local -a devices targets

    mapper=$(images_offline_mapper_path "$partition")
    devices=("$partition" "$mapper")
    for device in "${devices[@]}"; do
        mapfile -t targets < <(images_offline_findmnt_targets "$device")
        for target in "${targets[@]}"; do
            [ -n "$target" ] || continue
            saw_mount=1
            if images_offline_validate_mount_record "$device" "$target" 0; then
                base="$target/$OFFLINE_IMAGES_SUBDIR"
                if images_directory_has_images "$base"; then
                    printf -v "$output_variable" '%s' "$base"
                    return 0
                fi
            fi
        done
    done
    [ "$saw_mount" -eq 0 ] || return 2
    return 1
}

images_offline_run_mount() {
    mount -o ro -- "$1" "$2"
}

images_offline_run_umount() {
    umount -- "$1"
}

images_offline_mount_device() {
    local device="$1"
    local mountpoint="$OFFLINE_MOUNTPOINT"
    local current_record=""

    mkdir -p -- "$mountpoint" || {
        ui_error "Não foi possível criar o mountpoint offline: $mountpoint"
        return 1
    }
    images_offline_mountpoint_is_safe "$mountpoint" || {
        ui_error "Mountpoint offline tornou-se inseguro: $mountpoint"
        return 1
    }
    current_record=$(images_offline_findmnt_record "$mountpoint")
    [ -z "$current_record" ] || {
        ui_error "O mountpoint offline está ocupado e não será reutilizado: $mountpoint"
        log_error "Montagem offline recusada; mountpoint ocupado: $current_record"
        return 1
    }
    if [ -n "$(find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        ui_error "O mountpoint offline contém arquivos locais e não será encoberto: $mountpoint"
        log_error "Montagem offline recusada sobre diretório local não vazio."
        return 1
    fi

    log_info "Montando mídia offline somente leitura: $device em $mountpoint"
    if ! images_offline_run_mount "$device" "$mountpoint"; then
        ui_error "Não foi possível montar a mídia Ventoy somente leitura: $device"
        log_error "mount -o ro falhou para $device em $mountpoint."
        return 1
    fi
    # Estado provisório para que um sinal entre mount e findmnt ainda possa
    # executar cleanup, sempre sujeito à confirmação de origem e destino.
    PMJS_OFFLINE_MOUNT_OWNED=1
    PMJS_OFFLINE_MOUNT_SOURCE="$device"
    PMJS_OFFLINE_MOUNT_TARGET="$mountpoint"
    PMJS_OFFLINE_MOUNT_ID=""
    if ! images_offline_validate_mount_record "$device" "$mountpoint" 1; then
        images_cleanup_offline_mount || true
        ui_error "findmnt não confirmou a montagem offline esperada e somente leitura."
        log_error "Montagem offline não confirmada para $device em $mountpoint; Deploy não continuará."
        return 1
    fi

    PMJS_OFFLINE_MOUNT_OWNED=1
    PMJS_OFFLINE_MOUNT_SOURCE="$PMJS_OFFLINE_CONFIRMED_SOURCE"
    PMJS_OFFLINE_MOUNT_TARGET="$PMJS_OFFLINE_CONFIRMED_TARGET"
    PMJS_OFFLINE_MOUNT_ID="$PMJS_OFFLINE_CONFIRMED_ID"
    ui_success "Mídia offline montada somente leitura em $mountpoint"
}

images_cleanup_offline_mount() {
    local record=""

    [ "$PMJS_OFFLINE_MOUNT_OWNED" -eq 1 ] || return 0
    record=$(images_offline_findmnt_record "$PMJS_OFFLINE_MOUNT_TARGET")
    if ! images_offline_parse_mount_record "$record" ||
       [ "$PMJS_OFFLINE_CONFIRMED_TARGET" != "$PMJS_OFFLINE_MOUNT_TARGET" ] ||
       ! images_offline_devices_are_same "$PMJS_OFFLINE_CONFIRMED_SOURCE" \
            "$PMJS_OFFLINE_MOUNT_SOURCE"; then
        ui_warning "Mídia offline não desmontada: identidade do mount mudou ou não pôde ser confirmada."
        log_warning "Cleanup recusou umount de $PMJS_OFFLINE_MOUNT_TARGET por divergência de identidade."
        return 1
    fi
    if [ -n "$PMJS_OFFLINE_MOUNT_ID" ] &&
       [ "$PMJS_OFFLINE_CONFIRMED_ID" != "$PMJS_OFFLINE_MOUNT_ID" ]; then
        ui_warning "Mídia offline não desmontada: o ID do mount mudou."
        log_warning "Cleanup recusou umount de $PMJS_OFFLINE_MOUNT_TARGET por mudança de ID."
        return 1
    fi
    if ! images_offline_run_umount "$PMJS_OFFLINE_MOUNT_TARGET"; then
        ui_warning "Não foi possível desmontar a mídia offline em $PMJS_OFFLINE_MOUNT_TARGET."
        log_warning "umount falhou para o mount offline criado pelo Deploy."
        return 1
    fi
    log_info "Mídia offline desmontada pelo Deploy: $PMJS_OFFLINE_MOUNT_TARGET"
    PMJS_OFFLINE_MOUNT_OWNED=0
    PMJS_OFFLINE_MOUNT_SOURCE=""
    PMJS_OFFLINE_MOUNT_TARGET=""
    PMJS_OFFLINE_MOUNT_ID=""
}

images_find_offline_media() {
    local partition mount_device mounted_base find_status=0
    local -a candidates=() qualified=()

    images_offline_validate_config || return 1
    images_offline_check_dependencies || return 1
    PMJS_OFFLINE_UDEV_TRIGGERED=0
    mapfile -t candidates < <(images_offline_list_partitions)
    for partition in "${candidates[@]}"; do
        images_offline_candidate_is_ventoy "$partition" && qualified+=("$partition")
    done

    if [ "${#qualified[@]}" -eq 0 ]; then
        log_info "Nenhuma partição Ventoy USB compatível foi encontrada para o fallback offline."
        return 1
    fi
    if [ "${#qualified[@]}" -gt 1 ]; then
        ui_error "Mais de uma partição Ventoy compatível foi encontrada; remova a mídia ambígua."
        log_error "Descoberta offline ambígua: ${qualified[*]}"
        return 1
    fi
    partition="${qualified[0]}"
    log_info "Partição de dados Ventoy candidata: $partition"

    if images_offline_find_existing_mount "$partition" mounted_base; then
        IMAGES_BASE="$mounted_base"
        IMAGES_SOURCE="offline"
        ui_success "Mídia Ventoy já montada; reutilizando $mounted_base"
        log_info "Mount offline preexistente reutilizado; ownership permanece externo."
        return 0
    else
        find_status=$?
    fi
    if [ "$find_status" -eq 2 ]; then
        ui_error "A partição Ventoy já está montada, mas não contém uma origem PMJS válida."
        return 1
    fi

    images_offline_resolve_mount_device "$partition" mount_device || return 1
    images_offline_mount_device "$mount_device" || return 1
    mounted_base="$OFFLINE_MOUNTPOINT/$OFFLINE_IMAGES_SUBDIR"
    if ! images_directory_has_images "$mounted_base"; then
        ui_error "A mídia Ventoy não contém imagens PMJS válidas em $OFFLINE_IMAGES_SUBDIR/."
        log_error "Estrutura offline ausente ou inválida em $mounted_base."
        images_cleanup_offline_mount || true
        return 1
    fi
    IMAGES_BASE="$mounted_base"
    IMAGES_SOURCE="offline"
    log_info "Fonte offline selecionada em $IMAGES_BASE usando $mount_device."
}

images_find_offline() {
    local offline_dir="${1:-${OFFLINE_IMAGES_DIR:-}}"

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
    ui_info "Procurando imagens na partição de dados do Ventoy..."

    if images_find_offline_media; then
        ui_success "Imagens encontradas na mídia offline."
        log_info "Fonte de imagens selecionada: Ventoy offline em $IMAGES_BASE"
        return 0
    fi

    if [ -n "${OFFLINE_IMAGES_DIR:-}" ]; then
        ui_info "Tentando o diretório offline configurado como fallback legado..."
        if images_find_offline "$OFFLINE_IMAGES_DIR"; then
            ui_success "Imagens encontradas no diretório offline configurado."
            log_info "Fonte de imagens selecionada: offline configurada em $IMAGES_BASE"
            return 0
        fi
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
