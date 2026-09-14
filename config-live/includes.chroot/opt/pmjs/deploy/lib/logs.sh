#!/bin/bash

LOG_FILE=""

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

    if [ -z "${LOG_FILE:-}" ]; then
        return 1
    fi

    printf '%s [COMMAND] ' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    printf '%q ' "$@" >> "$LOG_FILE"
    printf '\n' >> "$LOG_FILE"

    "$@" >> "$LOG_FILE" 2>&1 || status=$?
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
