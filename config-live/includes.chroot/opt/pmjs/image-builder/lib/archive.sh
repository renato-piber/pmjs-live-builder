#!/usr/bin/env bash

archive_extension() {
    case "$1" in
        gzip) printf '%s\n' 'tar.gz' ;;
        zstd) printf '%s\n' 'tar.zst' ;;
        *) return 1 ;;
    esac
}

archive_tar_create_options() {
    local compression=$1 zstd_level=$2
    local -n options_ref=$3
    case "${compression}" in
        gzip) options_ref=(--gzip) ;;
        zstd) options_ref=(--use-compress-program="zstd -${zstd_level}") ;;
        *) return 1 ;;
    esac
}

archive_tar_read_options() {
    local compression=$1
    local -n options_ref=$2
    case "${compression}" in
        gzip) options_ref=(--gzip) ;;
        zstd) options_ref=(--zstd) ;;
        *) return 1 ;;
    esac
}

validate_archive_compression() {
    local archive_file=$1 compression=$2
    case "${compression}" in
        gzip) gzip -t -- "${archive_file}" ;;
        zstd) zstd --test --quiet -- "${archive_file}" ;;
        *) return 1 ;;
    esac
}
