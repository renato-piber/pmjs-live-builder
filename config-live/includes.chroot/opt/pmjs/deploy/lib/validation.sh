#!/bin/bash

validation_reset() {
    VALIDATION_ERRORS=0
    VALIDATION_WARNINGS=0
}

validation_record_ok() {
    local message="$1"

    ui_validation_ok "$message"
    log_info "$message"
}

validation_record_warning() {
    local message="$1"

    VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
    ui_validation_warning "$message"
    log_warning "$message"
}

validation_record_error() {
    local message="$1"

    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    ui_validation_error "$message"
    log_error "$message"
}

validate_environment() {
    case "${PMJS_ENVIRONMENT:-}" in
        production|development) ;;
        *) validation_record_error "Ambiente invalido: ${PMJS_ENVIRONMENT:-vazio}"; return 1 ;;
    esac
    if [ "${INSTALL_MODE:-}" != "$PMJS_ENVIRONMENT" ]; then
        validation_record_error "O resumo nao corresponde ao ambiente ativo."
        return 1
    fi
    validation_record_ok "Ambiente ativo: $PMJS_ENVIRONMENT."
}

validate_source() {
    local source="${IMAGES_SOURCE:-}"
    local base="${IMAGES_BASE:-}"

    if [ -z "$source" ]; then
        validation_record_error "A origem das imagens não foi definida."
        return 1
    fi

    case "$source" in
    online|offline|local)
        ;;
    *)
        validation_record_error "Tipo de origem não reconhecido: $source"
        return 1
        ;;
    esac

    if [ -z "$base" ]; then
        validation_record_error "O caminho base da origem não está definido."
        return 1
    fi

    if [ ! -e "$base" ]; then
        validation_record_error "O caminho da origem não existe: $base"
        return 1
    fi

    if [ ! -d "$base" ]; then
        validation_record_error "O caminho da origem não é um diretório: $base"
        return 1
    fi

    if [ ! -r "$base" ]; then
        validation_record_error "O caminho da origem não é legível: $base"
        return 1
    fi

    validation_record_ok "Origem $source acessível em $base."
}

validate_image() {
    local image_dir="${INSTALL_IMAGE_DIR:-}"
    local image_name="${INSTALL_IMAGE:-}"

    if [ -z "$image_name" ]; then
        validation_record_error "Nenhuma imagem foi selecionada."
        return 1
    fi

    if [ -z "$image_dir" ]; then
        validation_record_error "O diretório da imagem não foi definido para $image_name."
        return 1
    fi

    if ! image_contract_load "$image_dir" "${INSTALL_STORAGE_MODE:-clean}" 1; then
        validation_record_error "Imagem inválida: ${IMAGE_CONTRACT_ERROR:-falha no contrato da imagem}"
        return 1
    fi

    EXTRACT_ROOTFS_ARCHIVE="$IMAGE_CONTRACT_ROOTFS_ARCHIVE"
    EXTRACT_HOMEFS_ARCHIVE="$IMAGE_CONTRACT_HOMEFS_ARCHIVE"
    validation_record_ok "Imagem reconhecida: $IMAGE_CONTRACT_FORMAT; compressão $IMAGE_CONTRACT_COMPRESSION."
    validation_record_ok "Rootfs válido: $IMAGE_CONTRACT_ROOTFS_FILENAME"
    if [ "$IMAGE_CONTRACT_FORMAT" = schema1 ] ||
       [ "${INSTALL_STORAGE_MODE:-}" != preserve_home ]; then
        validation_record_ok "Homefs válido: $IMAGE_CONTRACT_HOMEFS_FILENAME"
    else
        validation_record_ok "Modo preserve_home: homefs legado não será exigido nem utilizado."
    fi
}

validate_disk() {
    local disk="${INSTALL_DISK:-}"
    local disk_type
    local size_bytes
    local size_gib
    local min_bytes
    local min_gib
    local found=0

    if [ -z "$disk" ]; then
        validation_record_error "Nenhum disco de destino foi selecionado."
        return 1
    fi

    if [[ "$disk" != /dev/* ]]; then
        validation_record_error "O disco de destino não começa com /dev/: $disk"
        return 1
    fi

    if [ ! -e "$disk" ]; then
        validation_record_error "O disco de destino não existe: $disk"
        return 1
    fi

    if [ ! -b "$disk" ]; then
        validation_record_error "O caminho informado não é um dispositivo de bloco: $disk"
        return 1
    fi

    disk_type=$(lsblk -dn -o TYPE -- "$disk" 2>/dev/null | head -n1 || true)

    if [ "$disk_type" != "disk" ]; then
        validation_record_error "O dispositivo selecionado não é um disco inteiro: $disk"
        return 1
    fi

    disks_collect_candidates

    for candidate in "${DISK_CANDIDATES[@]}"; do
        if [ "$candidate" = "$disk" ]; then
            found=1
            break
        fi
    done

    if [ "$found" -eq 0 ]; then
        validation_record_error "O disco $disk não está na lista de discos permitidos para instalação."
        return 1
    fi

    if disks_is_protected "$disk"; then
        validation_record_error "O disco selecionado está protegido pela política de segurança: $disk"
        return 1
    fi

    size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null || true)

    if [ -z "$size_bytes" ]; then
        validation_record_error "Não foi possível obter a capacidade do disco: $disk"
        return 1
    fi

    min_gib="${MIN_DISK_SIZE_GIB:-40}"
    min_bytes=$((min_gib * 1024 * 1024 * 1024))
    size_gib=$((size_bytes / 1024 / 1024 / 1024))

    if [ "$size_bytes" -lt "$min_bytes" ]; then
        validation_record_error "Capacidade do disco abaixo do mínimo: $disk (${size_gib} GiB, mínimo ${min_gib} GiB)."
        return 1
    fi

    validation_record_ok "Disco válido para instalação: $disk (${size_gib} GiB)."
}

validate_identity() {
    if [ -z "${INSTALL_HOSTNAME:-}" ]; then
        validation_record_error "O hostname não pode ficar vazio."
        return 1
    fi

    if [[ "$INSTALL_HOSTNAME" =~ [[:space:]] ]] || [[ "$INSTALL_HOSTNAME" =~ [^a-zA-Z0-9-] ]] || [[ "$INSTALL_HOSTNAME" =~ ^- ]] || [[ "$INSTALL_HOSTNAME" =~ -$ ]]; then
        validation_record_error "O hostname contém caracteres inválidos: $INSTALL_HOSTNAME"
        return 1
    fi

    if [[ "$INSTALL_HOSTNAME" =~ [A-Z] ]]; then
        validation_record_warning "O hostname contém letras maiúsculas; prefira minúsculas."
    else
        validation_record_ok "Hostname válido: $INSTALL_HOSTNAME"
    fi

    if [ -z "${INSTALL_OCS_TAG//[[:space:]]/}" ]; then
        validation_record_error "A tag do OCS Inventory não pode ficar vazia."
        return 1
    fi

    validation_record_ok "Tag OCS definida: $INSTALL_OCS_TAG"
}

validate_boot() {
    local detected_mode="${INSTALL_BOOT_DETECTED:-}"
    local selected_mode="${INSTALL_BOOT_MODE:-}"

    if [ -z "$detected_mode" ]; then
        if [ -d /sys/firmware/efi ]; then
            detected_mode="uefi"
        else
            detected_mode="legacy"
        fi
    fi

    if [ -z "$selected_mode" ]; then
        validation_record_error "O modo de instalação escolhido não foi definido."
        return 1
    fi

    case "$detected_mode" in
        uefi|legacy)
            ;;
        *)
            validation_record_error "Modo de boot detectado inválido: $detected_mode"
            return 1
            ;;
    esac

    case "$selected_mode" in
        uefi|legacy)
            ;;
        *)
            validation_record_error "Modo de instalação inválido: $selected_mode"
            return 1
            ;;
    esac

    if [ "$detected_mode" != "$selected_mode" ]; then
        validation_record_warning "O Live foi iniciado em $detected_mode, mas a instalação $selected_mode foi selecionada."
    else
        validation_record_ok "Modo de boot consistente: $selected_mode"
    fi
}


validate_storage_plan() {
    case "$INSTALL_STORAGE_MODE" in
        clean|preserve_home)
            ;;
        *)
            validation_record_error "O modo de armazenamento não foi definido."
            return 1
            ;;
    esac

    if [ "$INSTALL_STORAGE_MODE" = "preserve_home" ]; then
        if [ "$EDUINSTALL_LAYOUT_DETECTED" -ne 1 ]; then
            validation_record_error "O modo preserve_home exige um layout EduInstall reconhecido."
            return 1
        fi

        if [ -z "$INSTALL_SWAP_PARTITION" ] || [ -z "$INSTALL_ROOT_PARTITION" ] || [ -z "$INSTALL_HOME_PARTITION" ]; then
            validation_record_error "As partições do layout EduInstall não foram completamente identificadas."
            return 1
        fi
        if [ "$INSTALL_BOOT_MODE" = "uefi" ] && [ -z "$INSTALL_EFI_PARTITION" ]; then
            validation_record_error "O layout UEFI exige uma partição EFI identificada."
            return 1
        fi
        if [ "$INSTALL_BOOT_MODE" = "legacy" ] && [ -n "$INSTALL_EFI_PARTITION" ]; then
            validation_record_error "O layout Legacy oficial não deve possuir partição EFI."
            return 1
        fi

        if [ "$INSTALL_ROOT_PARTITION" = "$INSTALL_HOME_PARTITION" ]; then
            validation_record_error "As partições raiz e home devem ser diferentes."
            return 1
        fi

        if [ "$INSTALL_FORMAT_ROOT" -ne 1 ]; then
            validation_record_error "O modo preserve_home exige formatação da raiz."
            return 1
        fi

        if [ "$INSTALL_FORMAT_HOME" -ne 0 ]; then
            validation_record_error "O modo preserve_home não pode formatar /home."
            return 1
        fi

        if [ "$INSTALL_REPARTITION_DISK" -ne 0 ]; then
            validation_record_error "O modo preserve_home não deve reparticionar o disco."
            return 1
        fi
    else
        if [ "$INSTALL_REPARTITION_DISK" -ne 1 ]; then
            validation_record_error "O modo clean exige reparticionar o disco."
            return 1
        fi
        if [ "$INSTALL_FORMAT_ROOT" -ne 1 ]; then
            validation_record_error "O modo clean exige formatação da raiz."
            return 1
        fi
        if [ "$INSTALL_FORMAT_HOME" -ne 1 ]; then
            validation_record_error "O modo clean exige formatação da home."
            return 1
        fi
    fi

    validation_record_ok "Plano de armazenamento válido: $INSTALL_STORAGE_MODE"
}

install_validate() {
    local validation_status=0

    log_info "Iniciando pré-validação da instalação."
    validation_reset

    validate_environment || validation_status=1
    validate_source || validation_status=1
    validate_image || validation_status=1
    validate_disk || validation_status=1
    validate_identity || validation_status=1
    validate_boot || validation_status=1
    validate_storage_plan || validation_status=1

    echo
    echo "Validação concluída com $VALIDATION_ERRORS erros e $VALIDATION_WARNINGS avisos."

    if [ "$VALIDATION_ERRORS" -eq 0 ]; then
        ui_validation_ok "A instalação pode prosseguir."
        log_info "Pré-validação concluída com $VALIDATION_ERRORS erros e $VALIDATION_WARNINGS avisos."
        return 0
    fi

    ui_validation_error "A instalação foi bloqueada."
    log_error "Pré-validação concluída com $VALIDATION_ERRORS erro(s) e $VALIDATION_WARNINGS aviso(s)."
    return "$validation_status"
}
