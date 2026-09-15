#!/bin/bash

SMART_TEMPERATURE_WARNING="${SMART_TEMPERATURE_WARNING:-55}"
SMART_PERCENTAGE_USED_WARNING="${SMART_PERCENTAGE_USED_WARNING:-80}"

SMART_RESULT=""
SMART_DEVICE=""
SMART_MODEL=""
SMART_SERIAL=""
SMART_CAPACITY=""
SMART_DEVICE_TYPE=""
SMART_SUPPORT=""
SMART_HEALTH=""
SMART_TEMPERATURE=""
SMART_POWER_ON_HOURS=""
SMART_REALLOCATED=""
SMART_PENDING=""
SMART_UNCORRECTABLE=""
SMART_REPORTED_UNCORRECT=""
SMART_COMMAND_TIMEOUT=""
SMART_NVME_CRITICAL_WARNING=""
SMART_NVME_MEDIA_ERRORS=""
SMART_NVME_PERCENTAGE_USED=""
SMART_NVME_AVAILABLE_SPARE=""
SMART_NVME_SPARE_THRESHOLD=""
SMART_REASONS=()

smart_find_smartctl() {
    local smartctl_bin=""

    smartctl_bin=$(command -v smartctl 2>/dev/null || true)
    if [ -n "$smartctl_bin" ] && [ -x "$smartctl_bin" ]; then
        printf '%s\n' "$smartctl_bin"
        return 0
    fi
    if [ -x /usr/sbin/smartctl ]; then
        printf '%s\n' /usr/sbin/smartctl
        return 0
    fi
    if [ -x /usr/bin/smartctl ]; then
        printf '%s\n' /usr/bin/smartctl
        return 0
    fi
    return 1
}

smart_reset_result() {
    SMART_RESULT="HEALTHY"
    SMART_DEVICE="Não disponível"
    SMART_MODEL="Não disponível"
    SMART_SERIAL="Não disponível"
    SMART_CAPACITY="Não disponível"
    SMART_DEVICE_TYPE="Não disponível"
    SMART_SUPPORT="Não disponível"
    SMART_HEALTH="Não disponível"
    SMART_TEMPERATURE="Não disponível"
    SMART_POWER_ON_HOURS="Não disponível"
    SMART_REALLOCATED="Não disponível"
    SMART_PENDING="Não disponível"
    SMART_UNCORRECTABLE="Não disponível"
    SMART_REPORTED_UNCORRECT="Não disponível"
    SMART_COMMAND_TIMEOUT="Não disponível"
    SMART_NVME_CRITICAL_WARNING="Não disponível"
    SMART_NVME_MEDIA_ERRORS="Não disponível"
    SMART_NVME_PERCENTAGE_USED="Não disponível"
    SMART_NVME_AVAILABLE_SPARE="Não disponível"
    SMART_NVME_SPARE_THRESHOLD="Não disponível"
    SMART_REASONS=()
}

smart_trim() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

smart_colon_value() {
    local output_file="$1"
    local field_pattern="$2"

    awk -v pattern="$field_pattern" '
        $0 ~ pattern {
            value=$0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            print value
            exit
        }
    ' "$output_file"
}

smart_ata_attribute() {
    local output_file="$1"
    local attribute="$2"

    awk -v wanted="$attribute" '
        $2 == wanted {
            if (NF >= 10) print $10
            exit
        }
    ' "$output_file"
}

smart_numeric_value() {
    local value="${1:-}"

    value="${value//,/}"
    if [[ "$value" =~ 0[xX]([0-9a-fA-F]+) ]]; then
        printf '%d\n' "$((16#${BASH_REMATCH[1]}))"
        return 0
    fi
    if [[ "$value" =~ ([0-9]+) ]]; then
        printf '%d\n' "$((10#${BASH_REMATCH[1]}))"
        return 0
    fi
    return 1
}

smart_mark_warning() {
    local reason="$1"

    if [ "$SMART_RESULT" = "HEALTHY" ]; then
        SMART_RESULT="WARNING"
    fi
    SMART_REASONS+=("$reason")
}

smart_mark_critical() {
    local reason="$1"

    SMART_RESULT="CRITICAL"
    SMART_REASONS+=("$reason")
}

smart_log_raw_output() {
    local output_file="$1"

    if [ -z "${LOG_FILE:-}" ] || [ ! -w "$LOG_FILE" ]; then
        return 0
    fi
    {
        printf '%s [INFO] Início da saída integral do smartctl para %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SMART_DEVICE"
        sed 's/^/[SMART RAW] /' "$output_file"
        printf '%s [INFO] Fim da saída integral do smartctl para %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SMART_DEVICE"
    } >> "$LOG_FILE"
}

smart_parse_common_fields() {
    local output_file="$1"
    local value=""

    value=$(smart_colon_value "$output_file" "^Device Model:") || true
    [ -n "$value" ] || value=$(smart_colon_value "$output_file" "^Model Number:") || true
    [ -n "$value" ] || value=$(smart_colon_value "$output_file" "^Product:") || true
    [ -n "$value" ] || value=$(smart_colon_value "$output_file" "^Model Family:") || true
    [ -n "$value" ] && SMART_MODEL=$(smart_trim "$value")

    value=$(smart_colon_value "$output_file" "^Serial Number:") || true
    [ -n "$value" ] && SMART_SERIAL=$(smart_trim "$value")

    value=$(awk '
        /^(User Capacity|Total NVM Capacity):/ {
            if (match($0, /\[[^]]+\]/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
            } else {
                value=$0
                sub(/^[^:]*:[[:space:]]*/, "", value)
                print value
            }
            exit
        }
    ' "$output_file") || true
    [ -n "$value" ] && SMART_CAPACITY=$(smart_trim "$value")

    if [[ "$SMART_DEVICE" == /dev/nvme* ]] ||
       grep -Eqi "NVMe (Version|device)|NVM Express" "$output_file"; then
        SMART_DEVICE_TYPE="NVMe"
        SMART_SUPPORT="Disponível"
    else
        value=$(smart_colon_value "$output_file" \
            "^(Transport protocol|SATA Version is|ATA Version is):") || true
        if [ -n "$value" ]; then
            SMART_DEVICE_TYPE=$(smart_trim "$value")
        else
            SMART_DEVICE_TYPE="ATA/SATA ou controladora"
        fi
        if grep -Eqi "^SMART support is:[[:space:]]+Available" "$output_file"; then
            SMART_SUPPORT="Disponível"
        elif grep -Eqi "SMART support is:[[:space:]]+Unavailable|SMART support is:.*Ambiguous" "$output_file"; then
            SMART_SUPPORT="Indisponível"
        fi
    fi

    value=$(smart_colon_value "$output_file" \
        "^(SMART overall-health self-assessment test result|SMART Health Status):") || true
    [ -n "$value" ] && SMART_HEALTH=$(smart_trim "$value")
    return 0
}

smart_parse_ata_fields() {
    local output_file="$1"
    local value=""

    value=$(smart_ata_attribute "$output_file" "Reallocated_Sector_Ct") || true
    [ -n "$value" ] && SMART_REALLOCATED="$value"
    value=$(smart_ata_attribute "$output_file" "Current_Pending_Sector") || true
    [ -n "$value" ] && SMART_PENDING="$value"
    value=$(smart_ata_attribute "$output_file" "Offline_Uncorrectable") || true
    [ -n "$value" ] && SMART_UNCORRECTABLE="$value"
    value=$(smart_ata_attribute "$output_file" "Reported_Uncorrect") || true
    [ -n "$value" ] && SMART_REPORTED_UNCORRECT="$value"
    value=$(smart_ata_attribute "$output_file" "Command_Timeout") || true
    [ -n "$value" ] && SMART_COMMAND_TIMEOUT="$value"
    value=$(smart_ata_attribute "$output_file" "Power_On_Hours") || true
    [ -n "$value" ] && SMART_POWER_ON_HOURS="$value"
    value=$(smart_ata_attribute "$output_file" "Temperature_Celsius") || true
    if [ -z "$value" ]; then
        value=$(smart_ata_attribute "$output_file" "Airflow_Temperature_Cel") || true
    fi
    [ -n "$value" ] && SMART_TEMPERATURE="$value"
    return 0
}

smart_parse_nvme_fields() {
    local output_file="$1"
    local value=""

    value=$(smart_colon_value "$output_file" "^Critical Warning:") || true
    [ -n "$value" ] && SMART_NVME_CRITICAL_WARNING=$(smart_trim "$value")
    value=$(smart_colon_value "$output_file" "^Media and Data Integrity Errors:") || true
    [ -n "$value" ] && SMART_NVME_MEDIA_ERRORS=$(smart_trim "$value")
    value=$(smart_colon_value "$output_file" "^Percentage Used:") || true
    [ -n "$value" ] && SMART_NVME_PERCENTAGE_USED=$(smart_trim "$value")
    value=$(smart_colon_value "$output_file" "^Available Spare:") || true
    [ -n "$value" ] && SMART_NVME_AVAILABLE_SPARE=$(smart_trim "$value")
    value=$(smart_colon_value "$output_file" "^Available Spare Threshold:") || true
    [ -n "$value" ] && SMART_NVME_SPARE_THRESHOLD=$(smart_trim "$value")
    value=$(smart_colon_value "$output_file" "^Temperature:") || true
    if [ -n "$value" ]; then
        SMART_TEMPERATURE=$(smart_numeric_value "$value" || smart_trim "$value")
    fi
    value=$(smart_colon_value "$output_file" "^Power On Hours:") || true
    [ -n "$value" ] && SMART_POWER_ON_HOURS=$(smart_trim "$value")
    return 0
}

smart_classify_numeric_greater_than_zero() {
    local raw_value="$1"
    local severity="$2"
    local reason="$3"
    local numeric=""

    [ "$raw_value" != "Não disponível" ] || return 0
    numeric=$(smart_numeric_value "$raw_value") || {
        smart_mark_warning "Não foi possível interpretar: $reason ($raw_value)."
        return 0
    }
    if [ "$numeric" -gt 0 ]; then
        if [ "$severity" = "critical" ]; then
            smart_mark_critical "$reason: $raw_value."
        else
            smart_mark_warning "$reason: $raw_value."
        fi
    fi
}

smart_classify_result() {
    local smartctl_status="$1"
    local numeric=""
    local spare=""
    local threshold=""

    if [[ "$SMART_HEALTH" =~ (FAILED|FAIL|BAD) ]]; then
        smart_mark_critical "O teste geral SMART indica falha: $SMART_HEALTH."
    fi
    if [ $((smartctl_status & 8)) -ne 0 ]; then
        smart_mark_critical "O código do smartctl indica falha geral de saúde."
    fi
    if [ $((smartctl_status & 7)) -ne 0 ]; then
        smart_mark_warning "smartctl não conseguiu obter todas as informações (código $smartctl_status)."
    elif [ $((smartctl_status & 240)) -ne 0 ]; then
        smart_mark_warning "smartctl registrou eventos ou atributos degradados (código $smartctl_status)."
    fi

    if [ "$SMART_DEVICE_TYPE" = "NVMe" ]; then
        if [ "$SMART_NVME_CRITICAL_WARNING" = "Não disponível" ]; then
            smart_mark_warning "Critical Warning NVMe não pôde ser interpretado."
        fi
        if [ "$SMART_NVME_MEDIA_ERRORS" = "Não disponível" ]; then
            smart_mark_warning "Erros de mídia/integridade NVMe não puderam ser interpretados."
        fi
        smart_classify_numeric_greater_than_zero \
            "$SMART_NVME_CRITICAL_WARNING" critical "Critical Warning NVMe"
        smart_classify_numeric_greater_than_zero \
            "$SMART_NVME_MEDIA_ERRORS" critical "Erros de mídia/integridade NVMe"

        if [ "$SMART_NVME_PERCENTAGE_USED" != "Não disponível" ]; then
            numeric=$(smart_numeric_value "$SMART_NVME_PERCENTAGE_USED") || true
            if [ -z "$numeric" ]; then
                smart_mark_warning "Não foi possível interpretar o desgaste NVMe."
            elif [ "$numeric" -ge "$SMART_PERCENTAGE_USED_WARNING" ]; then
                smart_mark_warning "Desgaste NVMe elevado: $SMART_NVME_PERCENTAGE_USED."
            fi
        fi
        spare=$(smart_numeric_value "$SMART_NVME_AVAILABLE_SPARE") || true
        threshold=$(smart_numeric_value "$SMART_NVME_SPARE_THRESHOLD") || true
        if [ -n "$spare" ] && [ -n "$threshold" ] && [ "$spare" -le "$threshold" ]; then
            smart_mark_warning \
                "Reserva NVMe no limite: $SMART_NVME_AVAILABLE_SPARE (limite $SMART_NVME_SPARE_THRESHOLD)."
        fi
    else
        if [ "$SMART_SUPPORT" = "Disponível" ]; then
            [ "$SMART_PENDING" != "Não disponível" ] ||
                smart_mark_warning "Setores pendentes não puderam ser interpretados."
            [ "$SMART_UNCORRECTABLE" != "Não disponível" ] ||
                smart_mark_warning "Setores irrecuperáveis não puderam ser interpretados."
        fi
        smart_classify_numeric_greater_than_zero \
            "$SMART_REALLOCATED" warning "Setores realocados"
        smart_classify_numeric_greater_than_zero \
            "$SMART_PENDING" critical "Setores pendentes"
        smart_classify_numeric_greater_than_zero \
            "$SMART_UNCORRECTABLE" critical "Setores irrecuperáveis"
        smart_classify_numeric_greater_than_zero \
            "$SMART_REPORTED_UNCORRECT" warning "Erros não corrigidos reportados"
        smart_classify_numeric_greater_than_zero \
            "$SMART_COMMAND_TIMEOUT" warning "Timeouts de comando"
        if [ "$SMART_SUPPORT" = "Não disponível" ] ||
           [ "$SMART_SUPPORT" = "Indisponível" ]; then
            smart_mark_warning "Suporte SMART indisponível ou não identificado."
        fi
        if [ "$SMART_HEALTH" = "Não disponível" ]; then
            smart_mark_warning "Estado geral SMART não pôde ser interpretado."
        fi
    fi

    if [ "$SMART_TEMPERATURE" != "Não disponível" ]; then
        numeric=$(smart_numeric_value "$SMART_TEMPERATURE") || true
        if [ -z "$numeric" ]; then
            smart_mark_warning "Temperatura SMART não pôde ser interpretada."
        elif [ "$numeric" -ge "$SMART_TEMPERATURE_WARNING" ]; then
            smart_mark_warning "Temperatura elevada: $SMART_TEMPERATURE."
        fi
    fi
}

smart_analyze_output() {
    local output_file="$1"
    local smartctl_status="${2:-0}"
    local disk="${3:-Não disponível}"

    smart_reset_result
    SMART_DEVICE="$disk"
    smart_parse_common_fields "$output_file"
    if [ "$SMART_DEVICE_TYPE" = "NVMe" ]; then
        smart_parse_nvme_fields "$output_file"
    else
        smart_parse_ata_fields "$output_file"
    fi
    smart_classify_result "$smartctl_status"
}

smart_display_value() {
    local value="$1"
    local suffix="${2:-}"

    if [ "$value" = "Não disponível" ]; then
        printf '%s\n' "$value"
    else
        printf '%s%s\n' "$value" "$suffix"
    fi
}

smart_show_summary() {
    local reason=""
    local translated_result=""

    case "$SMART_RESULT" in
        HEALTHY) translated_result="SAUDÁVEL" ;;
        WARNING) translated_result="ATENÇÃO" ;;
        CRITICAL) translated_result="CRÍTICO" ;;
    esac

    echo
    echo "Diagnóstico do disco"
    echo
    printf '%-22s %s\n' "Dispositivo:" "$SMART_DEVICE"
    printf '%-22s %s\n' "Modelo:" "$SMART_MODEL"
    printf '%-22s %s\n' "Capacidade:" "$SMART_CAPACITY"
    printf '%-22s %s\n' "Serial:" "$SMART_SERIAL"
    printf '%-22s %s\n' "Tipo:" "$SMART_DEVICE_TYPE"
    printf '%-22s %s\n' "Suporte SMART:" "$SMART_SUPPORT"
    printf '%-22s %s\n' "SMART:" "$SMART_HEALTH"
    printf '%-22s %s\n' "Horas de uso:" "$SMART_POWER_ON_HOURS"
    printf '%-22s %s\n' "Temperatura:" \
        "$(smart_display_value "$SMART_TEMPERATURE" " °C")"

    if [ "$SMART_DEVICE_TYPE" = "NVMe" ]; then
        echo
        printf '%-28s %s\n' "Critical Warning:" "$SMART_NVME_CRITICAL_WARNING"
        printf '%-28s %s\n' "Erros de mídia/integridade:" "$SMART_NVME_MEDIA_ERRORS"
        printf '%-28s %s\n' "Percentual usado:" "$SMART_NVME_PERCENTAGE_USED"
        printf '%-28s %s\n' "Reserva disponível:" "$SMART_NVME_AVAILABLE_SPARE"
        printf '%-28s %s\n' "Limite da reserva:" "$SMART_NVME_SPARE_THRESHOLD"
    else
        echo
        printf '%-28s %s\n' "Setores realocados:" "$SMART_REALLOCATED"
        printf '%-28s %s\n' "Setores pendentes:" "$SMART_PENDING"
        printf '%-28s %s\n' "Erros irrecuperáveis:" "$SMART_UNCORRECTABLE"
        printf '%-28s %s\n' "Erros reportados:" "$SMART_REPORTED_UNCORRECT"
        printf '%-28s %s\n' "Timeouts de comando:" "$SMART_COMMAND_TIMEOUT"
    fi
    echo
    printf 'Resultado: %s\n' "$translated_result"

    for reason in "${SMART_REASONS[@]}"; do
        printf ' - %s\n' "$reason"
    done
    echo
}

smart_confirm_result() {
    local answer=""

    case "$SMART_RESULT" in
        HEALTHY)
            ui_success "Disco classificado como saudável; instalação continuará."
            log_info "Decisão SMART automática: continuar com disco HEALTHY."
            return 0
            ;;
        WARNING)
            ui_warning "O disco apresenta sinais de atenção."
            read -rp "Continuar com este disco? [s/N]: " answer
            if [[ "$answer" =~ ^[Ss]$ ]]; then
                log_warning "Técnico autorizou continuar com disco classificado como WARNING."
                return 0
            fi
            ui_warning "Instalação cancelada antes do particionamento."
            log_warning "Técnico cancelou a instalação para disco WARNING."
            return 1
            ;;
        CRITICAL)
            ui_error "RISCO CRÍTICO NO DISCO. Recomenda-se substituir o dispositivo."
            read -rp "Digite CONTINUAR para assumir o risco: " answer
            if [ "$answer" = "CONTINUAR" ]; then
                log_warning "Técnico assumiu explicitamente o risco do disco CRITICAL."
                return 0
            fi
            ui_warning "Instalação cancelada antes do particionamento."
            log_error "Técnico cancelou a instalação para disco CRITICAL."
            return 1
            ;;
    esac
}

smart_check_selected_disk() {
    local disk="${1:-}"
    local smartctl_bin=""
    local output_file=""
    local smartctl_status=0
    local reason=""

    if [ -z "$disk" ] || [[ "$disk" != /dev/* ]]; then
        ui_error "Disco inválido para diagnóstico SMART: ${disk:-não definido}"
        log_error "Diagnóstico SMART recebeu dispositivo inválido."
        return 1
    fi

    log_info "Iniciando diagnóstico SMART somente leitura para $disk."
    if ! smartctl_bin=$(smart_find_smartctl); then
        ui_info "Diagnóstico SMART ignorado: smartctl não está disponível no ambiente Live."
        log_info "smartctl ausente; instale smartmontools para habilitar o diagnóstico opcional."
        return 0
    fi
    log_info "smartctl localizado em $smartctl_bin; dispositivo analisado: $disk."

    output_file=$(mktemp /tmp/pmjs-smart.XXXXXX) || {
        ui_warning "Não foi possível criar arquivo temporário para o diagnóstico SMART."
        log_warning "Diagnóstico SMART ignorado por falha em mktemp."
        return 0
    }
    if LC_ALL=C "$smartctl_bin" -a "$disk" > "$output_file" 2>&1; then
        smartctl_status=0
    else
        smartctl_status=$?
    fi

    smart_analyze_output "$output_file" "$smartctl_status" "$disk"
    smart_log_raw_output "$output_file"
    rm -f "$output_file"

    log_info "Classificação SMART final para $disk: $SMART_RESULT (smartctl=$smartctl_status)."
    for reason in "${SMART_REASONS[@]}"; do
        log_warning "SMART $disk: $reason"
    done
    smart_show_summary
    smart_confirm_result
}
