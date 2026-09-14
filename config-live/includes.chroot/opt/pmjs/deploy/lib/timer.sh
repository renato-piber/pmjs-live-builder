#!/bin/bash

TIMER_TOTAL_START=0
TIMER_TOTAL_DURATION=0
TIMER_CURRENT_STEP=""
TIMER_CURRENT_START=0
TIMER_LIVE_PID=""
TIMER_LIVE_STATE_FILE=""
TIMER_LIVE_ACTIVE=0
declare -a TIMER_STEP_ORDER=()
declare -A TIMER_STEP_LABELS=()
declare -A TIMER_STEP_DURATIONS=()

timer_now() {
    date +%s
}

timer_reset() {
    timer_live_stop "cleanup antes de reiniciar o timer" || true
    TIMER_TOTAL_START=0
    TIMER_TOTAL_DURATION=0
    TIMER_CURRENT_STEP=""
    TIMER_CURRENT_START=0
    TIMER_STEP_ORDER=()
    TIMER_STEP_LABELS=()
    TIMER_STEP_DURATIONS=()
}

timer_terminal_size() {
    local size=""
    local rows=""
    local columns=""

    if command -v tput >/dev/null 2>&1; then
        rows=$(tput lines </dev/tty 2>/dev/null || true)
        columns=$(tput cols </dev/tty 2>/dev/null || true)
    fi
    if ! [[ "$rows" =~ ^[0-9]+$ ]] || ! [[ "$columns" =~ ^[0-9]+$ ]]; then
        size=$(stty size </dev/tty 2>/dev/null || true)
        rows=${size%% *}
        columns=${size##* }
    fi
    [[ "$rows" =~ ^[0-9]+$ ]] || return 1
    [[ "$columns" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$rows" "$columns"
}

timer_live_publish_state() {
    local temporary=""
    local label=""

    [ "$TIMER_LIVE_ACTIVE" -eq 1 ] || return 0
    [ -n "$TIMER_LIVE_STATE_FILE" ] || return 1
    if [ -n "$TIMER_CURRENT_STEP" ]; then
        label="${TIMER_STEP_LABELS[$TIMER_CURRENT_STEP]:-Aguardando próxima etapa}"
    else
        label="Aguardando próxima etapa"
    fi
    label=${label//$'\n'/ }
    label=${label//|/-}
    temporary="${TIMER_LIVE_STATE_FILE}.tmp.$$"
    if ! printf '%s|%s|%s|%s\n' \
        "$TIMER_CURRENT_STEP" "$label" "$TIMER_CURRENT_START" "$TIMER_TOTAL_START" \
        > "$temporary" ||
       ! mv -f -- "$temporary" "$TIMER_LIVE_STATE_FILE"; then
        rm -f -- "$temporary"
        return 1
    fi
}

timer_live_worker() {
    local parent_pid="$1"
    local state_file="$2"
    local rows="$3"
    local columns="$4"
    local scroll_bottom=$((rows - 4))
    local step_id=""
    local label=""
    local step_start=0
    local total_start=0
    local now=0
    local step_elapsed=0
    local total_elapsed=0
    local cleanup_reason="encerramento normal"

    timer_live_worker_cleanup() {
        local row=0

        if exec 9<>/dev/tty 2>/dev/null; then
            printf '\0337\033[r' >&9
            for row in $((rows - 2)) $((rows - 1)) "$rows"; do
                printf '\033[%s;1H\033[2K' "$row" >&9
            done
            printf '\0338\033[?25h' >&9
            exec 9>&-
        fi
        log_info "Timer ao vivo: encerrado por $cleanup_reason."
    }

    trap 'cleanup_reason="cleanup/sinal"; exit 0' INT TERM HUP
    trap timer_live_worker_cleanup EXIT

    exec 9<>/dev/tty 2>/dev/null || {
        cleanup_reason="falha não fatal ao abrir /dev/tty"
        return 0
    }
    printf '\033[?25l\033[1;%sr\033[%s;1H' "$scroll_bottom" "$scroll_bottom" >&9
    : > "${state_file}.ready"

    while kill -0 "$parent_pid" 2>/dev/null; do
        if IFS='|' read -r step_id label step_start total_start < "$state_file" 2>/dev/null; then
            now=$(timer_now)
            [[ "$step_start" =~ ^[0-9]+$ ]] || step_start=$now
            [[ "$total_start" =~ ^[0-9]+$ ]] || total_start=$now
            step_elapsed=$((now - step_start))
            total_elapsed=$((now - total_start))
            label=${label:0:$((columns > 24 ? columns - 14 : 10))}

            printf '\0337\033[%s;1H\033[2KEtapa atual: %s\033[%s;1H\033[2KTempo da etapa: %s\033[%s;1H\033[2KTempo total: %s\0338' \
                "$((rows - 2))" "$label" \
                "$((rows - 1))" "$(timer_format_duration "$step_elapsed")" \
                "$rows" "$(timer_format_duration "$total_elapsed")" >&9
        fi
        sleep 1
    done
    cleanup_reason="cleanup após encerramento do processo principal"
}

timer_live_start() {
    local size=""
    local rows=0
    local columns=0
    local attempt=0

    [ "$TIMER_LIVE_ACTIVE" -eq 0 ] || return 0
    if [ ! -c /dev/tty ] || ! { : </dev/tty; } 2>/dev/null; then
        log_warning "Timer ao vivo: /dev/tty indisponível; recurso desabilitado sem interromper a instalação."
        return 0
    fi
    size=$(timer_terminal_size) || {
        log_warning "Timer ao vivo: não foi possível obter o tamanho do terminal; recurso desabilitado."
        return 0
    }
    read -r rows columns <<< "$size"
    if [ "$rows" -lt 10 ] || [ "$columns" -lt 32 ]; then
        log_warning "Timer ao vivo: terminal pequeno (${rows}x${columns}); recurso desabilitado."
        return 0
    fi

    TIMER_LIVE_STATE_FILE=$(mktemp /tmp/pmjs-timer-live.XXXXXX) || {
        log_warning "Timer ao vivo: falha não fatal ao criar arquivo de estado."
        return 0
    }
    TIMER_LIVE_ACTIVE=1
    timer_live_publish_state || {
        rm -f -- "$TIMER_LIVE_STATE_FILE"
        TIMER_LIVE_STATE_FILE=""
        TIMER_LIVE_ACTIVE=0
        log_warning "Timer ao vivo: falha não fatal ao publicar estado inicial."
        return 0
    }
    timer_live_worker "$$" "$TIMER_LIVE_STATE_FILE" "$rows" "$columns" \
        >/dev/null 2>&1 &
    TIMER_LIVE_PID=$!
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [ -e "${TIMER_LIVE_STATE_FILE}.ready" ] && break
        kill -0 "$TIMER_LIVE_PID" 2>/dev/null || break
        sleep 0.05
    done
    if [ ! -e "${TIMER_LIVE_STATE_FILE}.ready" ]; then
        log_warning "Timer ao vivo: falha não fatal ao reservar a região do terminal."
        timer_live_stop "falha na inicialização" || true
        return 0
    fi
    log_info "Timer ao vivo iniciado com PID $TIMER_LIVE_PID."
}

timer_live_stop() {
    local reason="${1:-encerramento normal}"
    local pid="${TIMER_LIVE_PID:-}"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    if [ "$TIMER_LIVE_ACTIVE" -eq 1 ]; then
        log_info "Timer ao vivo: encerramento solicitado ($reason)."
    fi
    if [ -n "$TIMER_LIVE_STATE_FILE" ]; then
        rm -f -- "$TIMER_LIVE_STATE_FILE" "${TIMER_LIVE_STATE_FILE}.ready"
    fi
    TIMER_LIVE_PID=""
    TIMER_LIVE_STATE_FILE=""
    TIMER_LIVE_ACTIVE=0
}

timer_total_start() {
    TIMER_TOTAL_START=$(timer_now)
    log_info "Timer total iniciado."
}

timer_total_stop() {
    local now=0

    [ "$TIMER_TOTAL_START" -gt 0 ] || return 1
    now=$(timer_now)
    TIMER_TOTAL_DURATION=$((now - TIMER_TOTAL_START))
    log_info "Timer total finalizado em $TIMER_TOTAL_DURATION segundo(s)."
}

timer_step_start() {
    local step_id="$1"
    local label="$2"

    if [ -n "$TIMER_CURRENT_STEP" ]; then
        log_warning "Timer: etapa $TIMER_CURRENT_STEP ainda estava ativa; encerrando antes de iniciar $step_id."
        timer_step_stop "$TIMER_CURRENT_STEP" || true
    fi

    TIMER_CURRENT_STEP="$step_id"
    TIMER_CURRENT_START=$(timer_now)
    TIMER_STEP_LABELS["$step_id"]="$label"
    TIMER_STEP_ORDER+=("$step_id")
    log_info "Timer da etapa iniciado: $label."
    if [ "$TIMER_LIVE_ACTIVE" -eq 1 ]; then
        log_info "Timer ao vivo: troca de etapa para $label."
        timer_live_publish_state || {
            log_warning "Timer ao vivo: falha não fatal ao atualizar a etapa."
            timer_live_stop "falha de publicação" || true
        }
    fi
}

timer_step_stop() {
    local step_id="$1"
    local now=0
    local duration=0

    [ "$TIMER_CURRENT_STEP" = "$step_id" ] || return 1
    now=$(timer_now)
    duration=$((now - TIMER_CURRENT_START))
    TIMER_STEP_DURATIONS["$step_id"]="$duration"
    log_info "Timer da etapa finalizado: ${TIMER_STEP_LABELS[$step_id]} em $duration segundo(s)."
    TIMER_CURRENT_STEP=""
    TIMER_CURRENT_START=0
    timer_live_publish_state || true
}

timer_run_step() {
    local step_id="$1"
    local label="$2"
    local status=0
    shift 2

    timer_step_start "$step_id" "$label"
    "$@" || status=$?
    timer_step_stop "$step_id" || true
    if [ "$status" -ne 0 ]; then
        timer_live_stop "cleanup após falha na etapa $label" || true
    fi
    return "$status"
}

timer_format_duration() {
    local total_seconds="${1:-0}"
    local hours=0
    local minutes=0
    local seconds=0

    hours=$((total_seconds / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if [ "$hours" -gt 0 ]; then
        printf '%02dh %02dm %02ds' "$hours" "$minutes" "$seconds"
    elif [ "$minutes" -gt 0 ]; then
        printf '%02dm %02ds' "$minutes" "$seconds"
    else
        printf '%02ds' "$seconds"
    fi
}

timer_show_summary() {
    local step_id=""
    local label=""
    local duration=0

    echo
    echo "Tempos da instalação:"
    for step_id in "${TIMER_STEP_ORDER[@]}"; do
        label="${TIMER_STEP_LABELS[$step_id]}"
        duration="${TIMER_STEP_DURATIONS[$step_id]:-0}"
        printf '  %-28s %s\n' "$label:" "$(timer_format_duration "$duration")"
    done
    printf '  %-28s %s\n' "Total:" "$(timer_format_duration "$TIMER_TOTAL_DURATION")"

    log_info "Resumo de tempos da instalação:"
    for step_id in "${TIMER_STEP_ORDER[@]}"; do
        log_info "Timer resumo: ${TIMER_STEP_LABELS[$step_id]}=${TIMER_STEP_DURATIONS[$step_id]:-0}s."
    done
    log_info "Timer resumo: total=${TIMER_TOTAL_DURATION}s."
}
