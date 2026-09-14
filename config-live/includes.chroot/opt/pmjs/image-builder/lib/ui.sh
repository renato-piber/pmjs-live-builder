#!/usr/bin/env bash

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
    readonly UI_BLUE=$'\033[1;34m'
    readonly UI_GREEN=$'\033[1;32m'
    readonly UI_YELLOW=$'\033[1;33m'
    readonly UI_RED=$'\033[1;31m'
    readonly UI_RESET=$'\033[0m'
else
    readonly UI_BLUE=""
    readonly UI_GREEN=""
    readonly UI_YELLOW=""
    readonly UI_RED=""
    readonly UI_RESET=""
fi

ui_header() {
    printf '%s\n' "${UI_BLUE}PMJS Image Builder — Sprint 2${UI_RESET}"
}

ui_info() {
    printf '%s[INFO]%s %s\n' "${UI_BLUE}" "${UI_RESET}" "$*"
    declare -F log_write >/dev/null && log_write INFO "$*"
}

ui_success() {
    printf '%s[OK]%s %s\n' "${UI_GREEN}" "${UI_RESET}" "$*"
    declare -F log_write >/dev/null && log_write SUCCESS "$*"
}

ui_warn() {
    printf '%s[AVISO]%s %s\n' "${UI_YELLOW}" "${UI_RESET}" "$*" >&2
    declare -F log_write >/dev/null && log_write WARN "$*"
}

ui_error() {
    printf '%s[ERRO]%s %s\n' "${UI_RED}" "${UI_RESET}" "$*" >&2
    declare -F log_write >/dev/null && log_write ERROR "$*"
}
