#!/bin/bash

LOG_FILE=""

# Relógio de boot Linux, resolução de centésimos; sem iniciar Python/date a
# cada consulta. Medições são somente diagnóstico e nunca mudam o resultado.
log_perf_now_ms() {
    local perf_uptime="" perf_unused="" perf_seconds="" perf_fraction=""
    if IFS=' ' read -r perf_uptime perf_unused < /proc/uptime 2>/dev/null &&
       [[ "$perf_uptime" =~ ^[0-9]+\.[0-9]+$ ]]; then
        perf_seconds=${perf_uptime%%.*}
        perf_fraction=${perf_uptime#*.}000
        printf '%s\n' "$((10#$perf_seconds * 1000 + 10#${perf_fraction:0:3}))"
    else
        printf '%s\n' "$((SECONDS * 1000))"
    fi
}

log_perf_end() {
    local perf_label=$1 perf_started=$2 perf_status=${3:-0} perf_now=0 perf_duration=0
    shift 3
    [ -n "${LOG_FILE:-}" ] || return 0
    [[ "$perf_started" =~ ^[0-9]+$ ]] || return 0
    perf_now=$(log_perf_now_ms)
    perf_duration=$((perf_now - perf_started))
    (( perf_duration >= 0 )) || perf_duration=0
    perf_label=${perf_label//$'\n'/ }; perf_label=${perf_label//|/-}
    # Sem stdout/ANSI, inclusive quando o chamador captura stdout do comando.
    { printf '%(%Y-%m-%d %H:%M:%S)T [PERF] %s: %d.%03ds status=%s phase=%s interval=%s mode=%s %s\n' \
        -1 "$perf_label" "$((perf_duration / 1000))" "$((perf_duration % 1000))" \
        "$perf_status" "${TIMER_CURRENT_STEP:-none}" "${INSTALL_PERF_PHASE:-unspecified}" \
        "${INSTALL_EXECUTION_MODE:-unspecified}" "$*" >> "$LOG_FILE"; } 2>/dev/null || true
    return 0
}

log_perf_run() {
    local perf_run_label=$1 perf_run_started=0 perf_run_status=0
    shift
    perf_run_started=$(log_perf_now_ms)
    "$@" || perf_run_status=$?
    log_perf_end "$perf_run_label" "$perf_run_started" "$perf_run_status"
    return "$perf_run_status"
}

log_init() {
    local project_root="$1"
    local timestamp

    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')

    mkdir -p "$project_root/logs"
    LOG_FILE="$project_root/logs/pmjs-deploy_$timestamp.log"

    touch "$LOG_FILE"
}

log_message() {
    local level="$1"
    shift

    printf '%s [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$level" \
        "$*" >> "$LOG_FILE"
}

log_run_external() {
    local status=0
    local external_perf_started=0

    if [ -z "${LOG_FILE:-}" ]; then
        return 1
    fi

    printf '%s [COMMAND] ' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    printf '%q ' "$@" >> "$LOG_FILE"
    printf '\n' >> "$LOG_FILE"

    external_perf_started=$(log_perf_now_ms)
    "$@" >> "$LOG_FILE" 2>&1 || status=$?
    log_perf_end "external $*" "$external_perf_started" "$status"
    printf '%s [COMMAND] código de saída: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$status" >> "$LOG_FILE"
    return "$status"
}

log_info() {
    log_message "INFO" "$@"
}

log_error() {
    log_message "ERROR" "$@"
}

log_warning() {
    log_message "WARNING" "$@"
}
