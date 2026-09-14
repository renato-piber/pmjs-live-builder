#!/usr/bin/env bash

LOG_FILE=""

init_log() {
    local log_dir=$1
    local timestamp

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    mkdir -p -- "${log_dir}"
    LOG_FILE="${log_dir}/build-${timestamp}-$$.log"
    : > "${LOG_FILE}"
}

log_write() {
    local level=$1
    shift

    [[ -n "${LOG_FILE:-}" ]] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${level}" "$*" >> "${LOG_FILE}"
}

get_log_file() {
    printf '%s\n' "${LOG_FILE}"
}
