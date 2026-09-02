#!/usr/bin/env bash

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    UI_BLUE=$'\033[1;34m'
    UI_GREEN=$'\033[1;32m'
    UI_YELLOW=$'\033[1;33m'
    UI_RED=$'\033[1;31m'
    UI_RESET=$'\033[0m'
else
    UI_BLUE=''
    UI_GREEN=''
    UI_YELLOW=''
    UI_RED=''
    UI_RESET=''
fi

ui_step() { printf '%s==>%s %s\n' "$UI_BLUE" "$UI_RESET" "$*"; }
ui_ok() { printf '%sOK:%s %s\n' "$UI_GREEN" "$UI_RESET" "$*"; }
ui_warn() { printf '%sAVISO:%s %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2; }
ui_error() { printf '%sERRO:%s %s\n' "$UI_RED" "$UI_RESET" "$*" >&2; }

