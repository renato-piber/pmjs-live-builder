#!/bin/bash

SELECTED_DISK=""
SELECTED_DISK_NAME=""
DISK_CANDIDATES=()

disks_parent_from_path() {
    local path="$1"
    local source
    local parent

    source=$(findmnt -n -o SOURCE --target "$path" 2>/dev/null || true)

    [ -n "$source" ] || return 1

    if [[ "$source" == /dev/* ]]; then
        parent=$(lsblk -no PKNAME "$source" 2>/dev/null || true)

        if [ -n "$parent" ]; then
            printf '/dev/%s\n' "$parent"
        else
            printf '%s\n' "$source"
        fi

        return 0
    fi

    return 1
}

disks_get_project_device() {
    disks_parent_from_path "$PROJECT_ROOT"
}

disks_get_live_device() {
    if [ -e /run/live/medium ]; then
        disks_parent_from_path /run/live/medium
    fi
}


disks_is_usb_or_removable() {
    local disk="$1"
    local transport
    local removable

    transport=$(lsblk -dn -o TRAN "$disk" 2>/dev/null | xargs)
    removable=$(lsblk -dn -o RM "$disk" 2>/dev/null | xargs)

    [ "$transport" = "usb" ] || [ "$removable" = "1" ]
}

disks_is_protected() {
    local disk="$1"
    local live_device=""
    local project_device=""

    live_device=$(disks_get_live_device || true)
    project_device=$(disks_get_project_device || true)

    if [ -n "$live_device" ] && [ "$disk" = "$live_device" ]; then
        log_info "Protegido por conter o ambiente Live: $disk"
        return 0
    fi

    if [ -n "$project_device" ] &&
    disks_is_usb_or_removable "$project_device" &&
    [ "$disk" = "$project_device" ]; then

    log_info "Protegido por conter o PMJS Deploy: $disk"
    return 0
    
    fi

    if disks_is_usb_or_removable "$disk"; then
        log_info "Protegido por ser USB/removível: $disk"
        return 0
    fi

    return 1
}

disks_collect_candidates() {
    local disk
    local type

    DISK_CANDIDATES=()

    while read -r disk type; do
        [ "$type" = "disk" ] || continue

        if disks_is_protected "$disk"; then
            continue
        fi

        DISK_CANDIDATES+=("$disk")
    done < <(
        lsblk \
            --nodeps \
            --noheadings \
            --paths \
            --output NAME,TYPE
    )
}

disks_show_candidates() {
    local index
    local disk
    local size
    local model
    local transport

    disks_collect_candidates

    if [ "${#DISK_CANDIDATES[@]}" -eq 0 ]; then
        ui_error "Nenhum disco interno disponível para instalação."
        log_error "Nenhum disco candidato encontrado."
        return 1
    fi

    echo
    echo "Discos internos disponíveis:"
    echo

    for index in "${!DISK_CANDIDATES[@]}"; do
        disk="${DISK_CANDIDATES[$index]}"

        size=$(lsblk -dn -o SIZE "$disk" | xargs)
        model=$(lsblk -dn -o MODEL "$disk" | xargs)
        transport=$(lsblk -dn -o TRAN "$disk" | xargs)

        printf '%2d) %-15s %-10s %-8s %s\n' \
            "$((index + 1))" \
            "$disk" \
            "$size" \
            "${transport:-desconhecido}" \
            "${model:-modelo não informado}"
    done
}

disks_select() {
    local option
    local count

    disks_show_candidates || return 1

    count=${#DISK_CANDIDATES[@]}

    echo
    read -rp "Escolha o disco de destino: " option

    if ! [[ "$option" =~ ^[0-9]+$ ]]; then
        ui_error "Digite apenas o número do disco."
        return 1
    fi

    if [ "$option" -lt 1 ] || [ "$option" -gt "$count" ]; then
        ui_error "Opção de disco inválida."
        return 1
    fi

    SELECTED_DISK="${DISK_CANDIDATES[$((option - 1))]}"
    SELECTED_DISK_NAME=$(basename "$SELECTED_DISK")

    ui_success "Disco selecionado: $SELECTED_DISK"
    log_info "Disco selecionado: $SELECTED_DISK"
}

disks_show_details() {
    local disk="$1"

    echo
    lsblk \
        --paths \
        --output NAME,TYPE,SIZE,FSTYPE,LABEL,MODEL,MOUNTPOINT \
        "$disk"
}

storage_detect_eduinstall_layout() {
    local disk="${1:-${INSTALL_DISK:-}}"
    local -a partition_names=()
    local -a partition_sizes=()
    local -a partition_fstypes=()
    local -a partition_numbers=()
    local partition_count=0
    local idx=0
    local path type size fstype pkname partn
    local efi_min efi_max swap_min swap_max root_min root_max
    local parent
    local expected_count=4
    local efi_index=0
    local swap_index=1
    local root_index=2
    local home_index=3
    local expected_table="gpt"
    local actual_table=""

    INSTALL_EFI_PARTITION=""
    INSTALL_SWAP_PARTITION=""
    INSTALL_ROOT_PARTITION=""
    INSTALL_HOME_PARTITION=""
    EDUINSTALL_LAYOUT_DETECTED=0

    [ -n "$disk" ] || return 1
    [[ "$disk" == /dev/* ]] || return 1
    [ -b "$disk" ] || return 1

    while read -r path type size fstype pkname partn; do
        [ -n "$path" ] || continue
        [ "$type" = "part" ] || continue
        [ -n "$pkname" ] || continue
        [ "$(basename "$pkname")" = "$(basename "$disk")" ] || continue

        partition_names+=("$path")
        partition_sizes+=("$size")
        partition_fstypes+=("$fstype")
        partition_numbers+=("$partn")
        partition_count=$((partition_count + 1))
    done < <(
        lsblk -bnrpo PATH,TYPE,SIZE,FSTYPE,PKNAME,PARTN "$disk" 2>/dev/null |
            sort -V
    )
    if [ "${INSTALL_BOOT_MODE:-}" = "legacy" ]; then
        expected_count=3
        expected_table="msdos"
        efi_index=-1
        swap_index=0
        root_index=1
        home_index=2
    fi
    actual_table=$(parted -sm "$disk" print 2>/dev/null | awk -F: 'NR==2 {print $6}' || true)
    [ "$actual_table" = "$expected_table" ] || return 1
    if [ "$partition_count" -ne "$expected_count" ]; then
        return 1
    fi

    efi_min=$((STORAGE_EFI_SIZE_MIN_BYTES - STORAGE_EFI_SIZE_TOLERANCE_BYTES))
    efi_max=$((STORAGE_EFI_SIZE_MIN_BYTES + STORAGE_EFI_SIZE_TOLERANCE_BYTES))
    swap_min=$((STORAGE_SWAP_SIZE_MIN_BYTES - STORAGE_SWAP_SIZE_TOLERANCE_BYTES))
    swap_max=$((STORAGE_SWAP_SIZE_MIN_BYTES + STORAGE_SWAP_SIZE_TOLERANCE_BYTES))
    root_min=$((STORAGE_ROOT_SIZE_MIN_BYTES - STORAGE_ROOT_SIZE_TOLERANCE_BYTES))
    root_max=$((STORAGE_ROOT_SIZE_MIN_BYTES + STORAGE_ROOT_SIZE_TOLERANCE_BYTES))

    if [ "$efi_index" -ge 0 ]; then
        if [[ "${partition_fstypes[$efi_index]}" != "vfat" ]] && [[ "${partition_fstypes[$efi_index]}" != "fat32" ]]; then
            return 1
        fi
        if [ "${partition_sizes[$efi_index]}" -lt "$efi_min" ] || [ "${partition_sizes[$efi_index]}" -gt "$efi_max" ]; then
            return 1
        fi
    fi

    case "${partition_fstypes[$swap_index]}" in
        swap|linux-swap)
            ;;
        *)
            return 1
            ;;
    esac

    if [ "${partition_sizes[$swap_index]}" -lt "$swap_min" ] || [ "${partition_sizes[$swap_index]}" -gt "$swap_max" ]; then
        return 1
    fi

    if [ "${partition_fstypes[$root_index]}" != "btrfs" ]; then
        return 1
    fi

    if [ "${partition_sizes[$root_index]}" -lt "$root_min" ] || [ "${partition_sizes[$root_index]}" -gt "$root_max" ]; then
        return 1
    fi

    if [ "${partition_fstypes[$home_index]}" != "btrfs" ]; then
        return 1
    fi

    if [ "${partition_sizes[$home_index]}" -le "${partition_sizes[$root_index]}" ]; then
        return 1
    fi

    for ((idx=0; idx<expected_count; idx++)); do
        if [ "${partition_numbers[$idx]:-}" != "$((idx + 1))" ]; then
            log_error "Layout EduInstall rejeitado: ${partition_names[$idx]} possui PARTN=${partition_numbers[$idx]:-vazio}, esperado $((idx + 1))."
            return 1
        fi
        parent=$(lsblk -no PKNAME "${partition_names[$idx]}" 2>/dev/null | xargs || true)

        if [ "$(basename "$parent")" != "$(basename "$disk")" ]; then
            return 1
        fi
    done

    if [ "$efi_index" -ge 0 ]; then
        INSTALL_EFI_PARTITION="${partition_names[$efi_index]}"
    fi
    INSTALL_SWAP_PARTITION="${partition_names[$swap_index]}"
    INSTALL_ROOT_PARTITION="${partition_names[$root_index]}"
    INSTALL_HOME_PARTITION="${partition_names[$home_index]}"
    EDUINSTALL_LAYOUT_DETECTED=1

    log_info "Layout EduInstall $INSTALL_BOOT_MODE detectado no disco $disk com $expected_count partições"
    return 0
}
