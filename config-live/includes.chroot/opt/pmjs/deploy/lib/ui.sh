#!/bin/bash

ui_clear() {
    clear
}

ui_title() {
    local version="$1"

    echo "=================================================="
    echo "                 PMJS DEPLOY"
    echo "                   v$version"
    echo "=================================================="
    echo
}

ui_info() {
    printf '[INFO] %s\n' "$*"
}

ui_success() {
    printf '[ OK ] %s\n' "$*"
}

ui_warning() {
    printf '[AVISO] %s\n' "$*" >&2
}

ui_error() {
    printf '[ERRO] %s\n' "$*" >&2
}

ui_validation_ok() {
    printf '[OK] %s\n' "$*"
}

ui_validation_warning() {
    printf '[AVISO] %s\n' "$*" >&2
}

ui_validation_error() {
    printf '[ERRO] %s\n' "$*" >&2
}

ui_pause() {
    echo
    if [ -c /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
        read -r -p "Pressione Enter para continuar..." </dev/tty
    else
        read -r -p "Pressione Enter para continuar..."
    fi
}
