#!/bin/bash

DETECTED_BOOT_MODE=""
INSTALL_BOOT_MODE=""
INSTALL_SOURCE=""
INSTALL_IMAGE=""
INSTALL_IMAGE_DIR=""
INSTALL_DISK=""
INSTALL_HOSTNAME=""
INSTALL_OCS_TAG=""
INSTALL_CLASSROOM=0
INSTALL_MODE=""
INSTALL_BOOT_MODE=""
INSTALL_BOOT_DETECTED=""
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0
INSTALL_STORAGE_MODE=""
INSTALL_REPARTITION_DISK=0
INSTALL_FORMAT_ROOT=0
INSTALL_FORMAT_HOME=0
INSTALL_EFI_PARTITION=""
INSTALL_SWAP_PARTITION=""
INSTALL_ROOT_PARTITION=""
INSTALL_HOME_PARTITION=""
EDUINSTALL_LAYOUT_DETECTED=0
INSTALL_DESTRUCTIVE_STARTED=0

install_collect_environment() {
    echo
    echo "Etapa 1 de 7 - Ambiente"
    echo

    read -rp "Selecione o ambiente [dev/prod] [prod]: " INSTALL_MODE
    INSTALL_MODE=${INSTALL_MODE:-prod}

    case "$INSTALL_MODE" in
        dev)
            PMJS_ENVIRONMENT="development"
            ;;
        prod)
            PMJS_ENVIRONMENT="production"
            ;;
        *)
            ui_error "Ambiente inválido: $INSTALL_MODE"
            return 1
            ;;
    esac

    ui_success "Ambiente selecionado: $INSTALL_MODE"
    log_info "Ambiente de instalação selecionado: $INSTALL_MODE"
}

install_collect_boot_mode() {
    local detected_mode="legacy"

    if [ -d /sys/firmware/efi ]; then
        detected_mode="uefi"
    fi

    INSTALL_BOOT_DETECTED="$detected_mode"

    echo
    echo "Etapa 5 de 7 - Modo de instalação"
    echo

    read -rp "Escolha o modo de instalação [uefi/legacy] [$detected_mode]: " INSTALL_BOOT_MODE
    INSTALL_BOOT_MODE=${INSTALL_BOOT_MODE:-$detected_mode}

    case "$INSTALL_BOOT_MODE" in
        uefi|legacy)
            ;;
        *)
            ui_error "Modo de instalação inválido: $INSTALL_BOOT_MODE"
            return 1
            ;;
    esac

    ui_success "Modo de instalação selecionado: $INSTALL_BOOT_MODE"
    log_info "Modo de instalação selecionado: $INSTALL_BOOT_MODE"
}

install_collect_identity() {
    echo
    echo "Etapa 6 de 7 - Identificação da máquina"
    echo

    read -rp "Digite o hostname da nova instalação: " INSTALL_HOSTNAME

    if [ -z "$INSTALL_HOSTNAME" ]; then
        ui_error "O hostname não pode ficar vazio."
        return 1
    fi

    read -rp "Digite a tag do OCS Inventory: " INSTALL_OCS_TAG

    return 0
}

install_collect_classroom() {
    local answer

    echo
    echo "Etapa 7 de 7 - Configuração de sala"
    echo

    read -rp "Este computador será utilizado em Sala de Aula? [s/N]: " answer

    case "$answer" in
        s|S|sim|SIM)
        INSTALL_CLASSROOM=1
        log_info "Configuração automática de Sala de Aula habilitada."
        ;;
        *)
        INSTALL_CLASSROOM=0
        log_info "Configuração de Sala de Aula desabilitada."
        ;;
    esac
}

install_summary() {
    local classroom_text
    local install_boot_text
    local box_width=50

    if [ "$INSTALL_CLASSROOM" -eq 1 ]; then
        classroom_text="Sim — espelhamento automático"
    else
        classroom_text="Não"
    fi

    install_boot_text="${INSTALL_BOOT_MODE:-não definido}"

    ui_clear
    ui_title "$VERSION"

    printf '=%.0s' {1..50}
    echo
    printf "%*s\n" $(( (box_width + ${#VERSION}) / 2 )) "$VERSION"
    printf '=%.0s' {1..50}
    echo

    printf "             RESUMO DA INSTALAÇÃO\n\n"

    printf "%-20s : %s\n" "Ambiente" "${INSTALL_MODE:-não definido}"
    printf "%-20s : %s\n" "Origem" "${IMAGES_SOURCE:-não definida}"
    printf "%-20s : %s\n" "Imagem" "${INSTALL_IMAGE:-não definida}"
    printf "%-20s : %s\n" "Disco" "${INSTALL_DISK:-não definido}"
    printf "%-20s : %s\n" "Armazenamento" "${INSTALL_STORAGE_MODE:-não definido}"
    printf "%-20s : %s\n" "Boot detectado" "${INSTALL_BOOT_DETECTED:-não definido}"
    printf "%-20s : %s\n" "Instalação" "${INSTALL_BOOT_MODE:-não definido}"
    printf "%-20s : %s\n" "Hostname" "${INSTALL_HOSTNAME:-não definido}"
    printf "%-20s : %s\n" "Tag OCS" "${INSTALL_OCS_TAG:-não definida}"
    printf "%-20s : %s\n" "Sala" "$classroom_text"

    echo
    printf '%s\n' '--------------------------------------------------'
    echo ' MODO SIMULAÇÃO: nenhuma alteração será executada.'
    printf '=%.0s' {1..50}
    echo
}

install_collect_execution_mode() {
    local option

    echo
    echo "Modo de execução"
    echo
    echo "1) Simulação"
    echo "2) Instalação real"
    echo

    read -rp "Escolha [1]: " option
    option=${option:-1}

    case "$option" in
        1)
            INSTALL_EXECUTION_MODE="dry-run"
            PARTITIONS_DRY_RUN=1
            FILESYSTEMS_DRY_RUN=1
            MOUNTS_DRY_RUN=1
            ;;
        2)
            INSTALL_EXECUTION_MODE="real"
            PARTITIONS_DRY_RUN=0
            FILESYSTEMS_DRY_RUN=0
            MOUNTS_DRY_RUN=0
            ;;
        *)
            ui_error "Opção inválida."
            return 1
            ;;
    esac

    return 0
}

install_confirm_destructive() {
    local answer=""
    local disk_model=""
    local disk_size=""
    local prompt=""

    disk_model=$(lsblk -dn -o MODEL -- "$INSTALL_DISK" 2>/dev/null | xargs || true)
    disk_size=$(lsblk -dn -o SIZE -- "$INSTALL_DISK" 2>/dev/null | xargs || true)

    echo
    echo "=================================================="
    echo "       CONFIRMAÇÃO DO PLANO DE INSTALAÇÃO"
    echo "=================================================="
    printf '%-22s %s\n' "Imagem:" "${INSTALL_IMAGE:-não definida}"
    printf '%-22s %s\n' "Disco:" "${INSTALL_DISK:-não definido}"
    printf '%-22s %s\n' "Modelo:" "${disk_model:-não disponível}"
    printf '%-22s %s\n' "Tamanho:" "${disk_size:-não disponível}"
    printf '%-22s %s\n' "Modo de boot:" "${INSTALL_BOOT_MODE:-não definido}"
    printf '%-22s %s\n' "Armazenamento:" "${INSTALL_STORAGE_MODE:-não definido}"
    echo

    log_info "Resumo destrutivo: imagem=${INSTALL_IMAGE:-não definida}; disco=${INSTALL_DISK:-não definido}; modelo=${disk_model:-não disponível}; tamanho=${disk_size:-não disponível}; boot=${INSTALL_BOOT_MODE:-não definido}; armazenamento=${INSTALL_STORAGE_MODE:-não definido}."

    case "${INSTALL_STORAGE_MODE:-}" in
        clean)
            echo "Partições que serão formatadas:"
            if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
                echo "  - EFI: nova partição, formatada como FAT32"
                log_warning "Plano clean: EFI será recriada e formatada."
            fi
            echo "  - swap: nova partição, assinatura swap recriada"
            echo "  - root (/): nova partição, formatada como Btrfs"
            echo "  - home (/home): nova partição, formatada como Btrfs"
            echo
            echo "Partições preservadas: nenhuma"
            echo
            ui_warning "TODO O CONTEÚDO DO DISCO $INSTALL_DISK SERÁ PERDIDO."
            log_warning "Plano clean em $INSTALL_DISK: disco reparticionado; EFI formatada quando UEFI; swap, root e home formatadas; nenhuma partição preservada."
            prompt="Continuar com a instalação? [s/N]: "
            ;;
        preserve_home)
            echo "Partições que serão formatadas:"
            echo "  - root (/): ${INSTALL_ROOT_PARTITION:-não identificada}"
            echo
            echo "Partições preservadas ou reutilizadas:"
            echo "  - home (/home): ${INSTALL_HOME_PARTITION:-não identificada} — PRESERVADA"
            echo "    UUID: ${PRESERVE_HOME_SNAPSHOT_UUID:-não identificado}"
            echo "  - swap: ${INSTALL_SWAP_PARTITION:-não identificada} — REUTILIZADA"
            if [ "${INSTALL_BOOT_MODE:-}" = "uefi" ]; then
                echo "  - EFI: ${INSTALL_EFI_PARTITION:-não identificada} — REUTILIZADA"
            else
                echo "  - EFI: não se aplica ao layout Legacy"
            fi
            echo
            ui_warning "A PARTIÇÃO ROOT SERÁ FORMATADA E SEUS DADOS SERÃO PERDIDOS."
            ui_warning "A HOME SERÁ PRESERVADA, MAS UM BACKUP CONTINUA RECOMENDADO."
            log_warning "Plano preserve_home em $INSTALL_DISK: root=${INSTALL_ROOT_PARTITION:-não identificada} formatada; home=${INSTALL_HOME_PARTITION:-não identificada} preservada; swap=${INSTALL_SWAP_PARTITION:-não identificada} reutilizada; EFI=${INSTALL_EFI_PARTITION:-não aplicável} reutilizada quando UEFI."
            prompt="Continuar com a instalação preservando /home? [s/N]: "
            ;;
        *)
            ui_error "Modo de armazenamento inválido para confirmação."
            log_error "Confirmação destrutiva recebeu modo inválido: ${INSTALL_STORAGE_MODE:-não definido}."
            return 1
            ;;
    esac

    if [ "${INSTALL_EXECUTION_MODE:-dry-run}" != "real" ]; then
        ui_warning "DRY RUN: plano exibido sem solicitar autorização destrutiva."
        log_info "Confirmação destrutiva dispensada em dry-run para $INSTALL_DISK no modo $INSTALL_STORAGE_MODE."
        return 0
    fi

    echo
    read -rp "$prompt" answer
    case "$answer" in
        s|S|sim|SIM)
            log_warning "Operador confirmou o plano $INSTALL_STORAGE_MODE para o disco $INSTALL_DISK."
            return 0
            ;;
        *)
            ui_warning "Instalação cancelada antes de qualquer operação destrutiva."
            log_warning "Operador cancelou o plano $INSTALL_STORAGE_MODE para o disco $INSTALL_DISK; resposta='${answer:-vazia}'."
            return 1
            ;;
    esac
}

install_start() {
    INSTALL_DESTRUCTIVE_STARTED=0
    image_contract_reset
    timer_reset
    timer_total_start
    timer_step_start "preparation" "Preparação e coleta"

    ui_clear
    ui_title "$VERSION"

    if ! install_collect_environment; then
        ui_pause
        return
    fi

    if ! install_collect_execution_mode; then
    ui_pause
    return
    fi

    echo
    echo "Etapa 2 de 7 - Origem das imagens"
    echo

    if ! images_select_source; then
        ui_pause
        return
    fi

    echo
    echo "Etapa 3 de 7 - Seleção da imagem"

    if ! images_choose; then
        ui_pause
        return
    fi

    echo
    echo "Imagem escolhida: $INSTALL_IMAGE"

    if ! install_collect_boot_mode; then
        ui_pause
        return
    fi

    echo
    echo "Etapa 4 de 7 - Seleção do disco"

    if ! disks_select; then
        ui_pause
        return
    fi

    INSTALL_DISK="$SELECTED_DISK"

    if ! smart_check_selected_disk "$INSTALL_DISK"; then
        ui_pause
        return
    fi

    if ! storage_detect_eduinstall_layout "$INSTALL_DISK"; then
        EDUINSTALL_LAYOUT_DETECTED=0
        ui_warning "Layout EduInstall não reconhecido; apenas o modo clean estará disponível."
    else
        EDUINSTALL_LAYOUT_DETECTED=1
    fi

    if ! install_select_storage_mode; then
        ui_pause
        return
    fi

    install_show_storage_plan

    if ! install_collect_identity; then
        ui_pause
        return
    fi

    echo
    echo "Etapa 6 de 6 - Configuração de sala"

    if ! install_collect_classroom; then
        ui_pause
        return
    fi
    timer_step_stop "preparation"

    install_summary

    if ! timer_run_step "validation" "Validação do plano" install_validate; then
        ui_pause
        return
    fi

    if ! timer_run_step "legacy_preflight" "Preflight Legacy" \
        chroot_boot_preflight_legacy_image; then
        ui_pause
        return
    fi

    if ! timer_run_step "home_preflight" "Preflight da home preservada" \
        storage_preserve_home_preflight; then
        ui_pause
        return
    fi

    if ! install_confirm_destructive; then
        ui_pause
        return
    fi
    timer_live_start || true

    if ! timer_run_step "partitioning" "Particionamento" partitions_apply_plan; then
        ui_pause
        return
    fi

    if ! timer_run_step "filesystems" "Formatação" filesystems_apply_plan; then
        ui_pause
        return
    fi

    if ! timer_run_step "mounts" "Montagem" mounts_apply; then
        ui_pause
        return
    fi

    if ! timer_run_step "extraction" "Extração das imagens" extract_apply; then
        ui_pause
        return
    fi

    if ! timer_run_step "system_config" "Configuração do sistema" \
        system_config_apply; then
        ui_pause
        return
    fi

    if ! timer_run_step "home_post_validation" "Validação final da home" \
        storage_preserve_home_post_validate; then
        ui_pause
        return
    fi

    if ! timer_run_step "boot" "Boot e pós-instalação" chroot_boot_apply; then
        ui_pause
        return
    fi

    timer_total_stop
    timer_live_stop "encerramento normal das etapas" || true
    log_info "install_start: etapas concluídas; preparando mensagem final."
    ui_clear
    ui_title "$VERSION"

    if [ "${INSTALL_EXECUTION_MODE:-dry-run}" = "real" ]; then
        if [ "${INSTALL_BOOT_READY:-0}" -ne 1 ]; then
            ui_error "A instalação terminou sem confirmação dos artefatos de boot."
            ui_pause
            return
        fi
        ui_success "Instalação concluída; o sistema está pronto para inicialização."
        echo
        echo "Disco: $INSTALL_DISK"
        if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
            echo "EFI:   ${INSTALL_EFI_PARTITION:-não identificada}"
        fi
        echo "Swap:  ${INSTALL_SWAP_PARTITION:-não identificada}"
        echo "Root:  ${INSTALL_ROOT_PARTITION:-não identificada}"
        echo "Home:  ${INSTALL_HOME_PARTITION:-não identificada}"
        echo "Root mount: ${INSTALL_TARGET_ROOT:-não definido}"
        echo "Home mount: ${INSTALL_TARGET_HOME:-não definido}"
        if [ "$INSTALL_BOOT_MODE" = "uefi" ]; then
            echo "EFI mount:  ${INSTALL_TARGET_EFI:-não definido}"
        fi
    else
        echo "MODO DE SIMULAÇÃO:"
        echo "Particionamento, formatação, montagem, extração, configuração e boot simulados."
        echo "Nenhuma alteração foi executada."
    fi

    timer_show_summary
    log_info "install_start: aguardando confirmação final do operador."
    if ! ui_pause; then
        log_warning "install_start: pausa final recebeu EOF ou foi interrompida; retornando ao menu mesmo assim."
    else
        log_info "install_start: confirmação final recebida."
    fi
    log_info "install_start: retornando explicitamente ao menu principal."
    return 0
}
