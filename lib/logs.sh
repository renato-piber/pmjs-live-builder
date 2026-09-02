#!/usr/bin/env bash

LOG_FILE=''

init_logging() {
    local log_dir=$1
    local timestamp

    mkdir -p -- "$log_dir"
    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    LOG_FILE="${log_dir}/build-${timestamp}-$$.log"
    : > "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

log_timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_info() { printf '[%s] INFO  %s\n' "$(log_timestamp)" "$*"; }
log_warn() { printf '[%s] WARN  %s\n' "$(log_timestamp)" "$*"; }
log_error() { printf '[%s] ERROR %s\n' "$(log_timestamp)" "$*"; }

