#!/bin/bash

IMAGE_CONTRACT_READY=0
IMAGE_CONTRACT_DIR=""
IMAGE_CONTRACT_FORMAT=""
IMAGE_CONTRACT_SCHEMA_VERSION=""
IMAGE_CONTRACT_NAME=""
IMAGE_CONTRACT_VERSION=""
IMAGE_CONTRACT_COMPRESSION=""
IMAGE_CONTRACT_ROOTFS_FILENAME=""
IMAGE_CONTRACT_HOMEFS_FILENAME=""
IMAGE_CONTRACT_ROOTFS_ARCHIVE=""
IMAGE_CONTRACT_HOMEFS_ARCHIVE=""
IMAGE_CONTRACT_ROOTFS_SHA256=""
IMAGE_CONTRACT_HOMEFS_SHA256=""
IMAGE_CONTRACT_SHA256_ROOTFS_SECONDS=0
IMAGE_CONTRACT_SHA256_HOMEFS_SECONDS=0
IMAGE_CONTRACT_SHA256_TOTAL_SECONDS=0
IMAGE_CONTRACT_ERROR=""
IMAGE_CONTRACT_QUIET=0

image_contract_reset() {
    IMAGE_CONTRACT_READY=0
    IMAGE_CONTRACT_DIR=""
    IMAGE_CONTRACT_FORMAT=""
    IMAGE_CONTRACT_SCHEMA_VERSION=""
    IMAGE_CONTRACT_NAME=""
    IMAGE_CONTRACT_VERSION=""
    IMAGE_CONTRACT_COMPRESSION=""
    IMAGE_CONTRACT_ROOTFS_FILENAME=""
    IMAGE_CONTRACT_HOMEFS_FILENAME=""
    IMAGE_CONTRACT_ROOTFS_ARCHIVE=""
    IMAGE_CONTRACT_HOMEFS_ARCHIVE=""
    IMAGE_CONTRACT_ROOTFS_SHA256=""
    IMAGE_CONTRACT_HOMEFS_SHA256=""
    IMAGE_CONTRACT_SHA256_ROOTFS_SECONDS=0
    IMAGE_CONTRACT_SHA256_HOMEFS_SECONDS=0
    IMAGE_CONTRACT_SHA256_TOTAL_SECONDS=0
    IMAGE_CONTRACT_ERROR=""
}

image_contract_fail() {
    IMAGE_CONTRACT_ERROR="$1"
    if [ "$IMAGE_CONTRACT_QUIET" -ne 1 ] && declare -F log_error >/dev/null; then
        log_error "$IMAGE_CONTRACT_ERROR"
    fi
    return 1
}

image_contract_parse_manifest() {
    local manifest_file="$1"
    local parsed_file=""
    local error_file=""
    local parser_error=""

    command -v python3 >/dev/null 2>&1 || {
        image_contract_fail "Imagem schema 1 requer python3 para validar manifest.json."
        return 1
    }
    parsed_file=$(mktemp /tmp/pmjs-manifest-values.XXXXXX) || return 1
    error_file=$(mktemp /tmp/pmjs-manifest-error.XXXXXX) || {
        rm -f -- "$parsed_file"
        return 1
    }

    if ! python3 - "$manifest_file" >"$parsed_file" 2>"$error_file" <<'PY'
import json
import re
import sys

manifest_path = sys.argv[1]
with open(manifest_path, encoding="utf-8") as stream:
    data = json.load(stream)

required = ("schema_version", "image_name", "image_version", "compression", "rootfs", "homefs")
missing = [key for key in required if key not in data]
if missing:
    raise ValueError("campos obrigatórios ausentes: " + ", ".join(missing))
if type(data["schema_version"]) is not int or data["schema_version"] != 1:
    raise ValueError("schema_version deve ser o inteiro 1")

identifier = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
for key in ("image_name", "image_version"):
    if not isinstance(data[key], str) or not identifier.fullmatch(data[key]):
        raise ValueError(f"{key} inválido")
if data["compression"] not in ("gzip", "zstd"):
    raise ValueError("compression deve ser gzip ou zstd")

values = []
for role in ("rootfs", "homefs"):
    descriptor = data[role]
    if not isinstance(descriptor, dict):
        raise ValueError(f"{role} deve ser um objeto")
    missing_descriptor = [key for key in ("filename", "sha256") if key not in descriptor]
    if missing_descriptor:
        raise ValueError(f"campos obrigatórios ausentes em {role}: " + ", ".join(missing_descriptor))
    filename = descriptor["filename"]
    digest = descriptor["sha256"]
    if not isinstance(filename, str) or not identifier.fullmatch(filename) or filename in (".", ".."):
        raise ValueError(f"filename perigoso ou inválido em {role}")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9A-Fa-f]{64}", digest):
        raise ValueError(f"SHA256 inválido em {role}")
    values.extend((filename, digest.lower()))
if values[0] == values[2]:
    raise ValueError("rootfs e homefs não podem apontar para o mesmo arquivo")

print("\t".join((
    str(data["schema_version"]), data["image_name"], data["image_version"],
    data["compression"], *values,
)))
PY
    then
        parser_error=$(tail -n 1 -- "$error_file")
        rm -f -- "$parsed_file" "$error_file"
        image_contract_fail "manifest.json inválido: ${parser_error:-erro de parsing}"
        return 1
    fi

    if ! IFS=$'\t' read -r IMAGE_CONTRACT_SCHEMA_VERSION IMAGE_CONTRACT_NAME \
        IMAGE_CONTRACT_VERSION IMAGE_CONTRACT_COMPRESSION \
        IMAGE_CONTRACT_ROOTFS_FILENAME IMAGE_CONTRACT_ROOTFS_SHA256 \
        IMAGE_CONTRACT_HOMEFS_FILENAME IMAGE_CONTRACT_HOMEFS_SHA256 < "$parsed_file"; then
        rm -f -- "$parsed_file" "$error_file"
        image_contract_fail "manifest.json inválido: parser não retornou os campos esperados."
        return 1
    fi
    rm -f -- "$parsed_file" "$error_file"
}

image_contract_validate_archive_file() {
    local image_dir="$1"
    local filename="$2"
    local role="$3"
    local archive="$image_dir/$filename"
    local resolved_dir=""
    local resolved_archive=""

    if [ ! -e "$archive" ]; then
        image_contract_fail "Arquivo declarado para $role não existe: $filename"
        return 1
    fi
    if [ ! -f "$archive" ] || [ -L "$archive" ] || [ ! -r "$archive" ] || [ ! -s "$archive" ]; then
        image_contract_fail "Arquivo declarado para $role não é regular, legível e não vazio: $filename"
        return 1
    fi
    resolved_dir=$(realpath -e -- "$image_dir") || return 1
    resolved_archive=$(realpath -e -- "$archive") || return 1
    case "$resolved_archive" in
        "$resolved_dir"/*)
            ;;
        *)
            image_contract_fail "Arquivo declarado para $role escapa do diretório da imagem: $filename"
            return 1
            ;;
    esac
}

image_contract_validate_checksum_manifest_coherence() {
    local checksum_file="$1"
    local error_file=""
    local parser_error=""

    [ ! -e "$checksum_file" ] && return 0
    if [ ! -f "$checksum_file" ] || [ -L "$checksum_file" ] || [ ! -r "$checksum_file" ]; then
        image_contract_fail "SHA256SUMS existe, mas não é um arquivo regular e legível."
        return 1
    fi
    error_file=$(mktemp /tmp/pmjs-checksums-error.XXXXXX) || return 1
    if ! python3 - "$checksum_file" \
        "$IMAGE_CONTRACT_ROOTFS_FILENAME" "$IMAGE_CONTRACT_ROOTFS_SHA256" \
        "$IMAGE_CONTRACT_HOMEFS_FILENAME" "$IMAGE_CONTRACT_HOMEFS_SHA256" \
        2>"$error_file" <<'PY'
import re
import sys

checksum_path, root_name, root_hash, home_name, home_hash = sys.argv[1:]
expected = {root_name: root_hash.lower(), home_name: home_hash.lower()}
found = {}
with open(checksum_path, encoding="utf-8") as stream:
    for number, raw_line in enumerate(stream, 1):
        line = raw_line.rstrip("\n")
        match = re.fullmatch(r"([0-9A-Fa-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        if not match or match.group(2) in (".", ".."):
            raise ValueError(f"linha {number} inválida em SHA256SUMS")
        digest, filename = match.groups()
        if filename in found:
            raise ValueError(f"entrada duplicada em SHA256SUMS: {filename}")
        found[filename] = digest.lower()
if set(found) != set(expected):
    raise ValueError("SHA256SUMS deve descrever exatamente rootfs e homefs do manifest")
for filename, digest in expected.items():
    if found[filename] != digest:
        raise ValueError(f"hash conflitante entre manifest e SHA256SUMS: {filename}")
PY
    then
        parser_error=$(tail -n 1 -- "$error_file")
        rm -f -- "$error_file"
        image_contract_fail "SHA256SUMS incoerente: ${parser_error:-erro de parsing}"
        return 1
    fi
    rm -f -- "$error_file"
}

image_contract_verify_sha256() {
    local role="$1"
    local archive="$2"
    local expected="$3"
    local duration_variable="$4"
    local started=0
    local finished=0
    local actual=""
    local checksum_output=""

    command -v sha256sum >/dev/null 2>&1 || {
        image_contract_fail "Imagem schema 1 requer sha256sum para validar $role."
        return 1
    }
    started=$(date +%s)
    checksum_output=$(sha256sum -- "$archive" 2>/dev/null) || {
        image_contract_fail "Falha ao calcular SHA256 de $role."
        return 1
    }
    actual=${checksum_output%% *}
    finished=$(date +%s)
    printf -v "$duration_variable" '%s' "$((finished - started))"
    if [ "$IMAGE_CONTRACT_QUIET" -ne 1 ] && declare -F log_info >/dev/null; then
        log_info "Validação SHA256 de $role concluída em $((finished - started)) segundo(s)."
    fi
    if [ "$actual" != "$expected" ]; then
        image_contract_fail "SHA256 divergente para $role: $(basename -- "$archive")"
        return 1
    fi
}

image_contract_probe_schema1() {
    local image_dir="$1"
    local previous_quiet="$IMAGE_CONTRACT_QUIET"

    IMAGE_CONTRACT_QUIET=1
    image_contract_reset
    if [ ! -f "$image_dir/manifest.json" ] || [ -L "$image_dir/manifest.json" ]; then
        IMAGE_CONTRACT_QUIET="$previous_quiet"
        return 1
    fi
    if ! image_contract_parse_manifest "$image_dir/manifest.json" ||
       [ "$(basename -- "$image_dir")" != "$IMAGE_CONTRACT_NAME-$IMAGE_CONTRACT_VERSION" ] ||
       ! image_contract_validate_archive_file "$image_dir" "$IMAGE_CONTRACT_ROOTFS_FILENAME" rootfs ||
       ! image_contract_validate_archive_file "$image_dir" "$IMAGE_CONTRACT_HOMEFS_FILENAME" homefs; then
        IMAGE_CONTRACT_QUIET="$previous_quiet"
        return 1
    fi
    IMAGE_CONTRACT_QUIET="$previous_quiet"
}

image_contract_load() {
    local image_dir="$1"
    local storage_mode="${2:-clean}"
    local verify_hashes="${3:-1}"
    local manifest_file="$image_dir/manifest.json"
    local hash_started=0
    local hash_finished=0

    image_contract_reset
    if [ ! -d "$image_dir" ] || [ ! -r "$image_dir" ]; then
        image_contract_fail "Diretório da imagem inválido ou ilegível: $image_dir"
        return 1
    fi
    IMAGE_CONTRACT_DIR=$(realpath -e -- "$image_dir") || {
        image_contract_fail "Não foi possível resolver o diretório da imagem: $image_dir"
        return 1
    }

    if [ -e "$manifest_file" ]; then
        if [ ! -f "$manifest_file" ] || [ -L "$manifest_file" ] || [ ! -r "$manifest_file" ]; then
            image_contract_fail "manifest.json deve ser um arquivo regular e legível."
            return 1
        fi
        image_contract_parse_manifest "$manifest_file" || return 1
        if [ "$(basename -- "$IMAGE_CONTRACT_DIR")" != "$IMAGE_CONTRACT_NAME-$IMAGE_CONTRACT_VERSION" ]; then
            image_contract_fail "Nome do diretório diverge de image_name/image_version do manifest."
            return 1
        fi
        IMAGE_CONTRACT_FORMAT=schema1
        IMAGE_CONTRACT_ROOTFS_ARCHIVE="$IMAGE_CONTRACT_DIR/$IMAGE_CONTRACT_ROOTFS_FILENAME"
        IMAGE_CONTRACT_HOMEFS_ARCHIVE="$IMAGE_CONTRACT_DIR/$IMAGE_CONTRACT_HOMEFS_FILENAME"
        image_contract_validate_archive_file "$IMAGE_CONTRACT_DIR" \
            "$IMAGE_CONTRACT_ROOTFS_FILENAME" rootfs || return 1
        image_contract_validate_archive_file "$IMAGE_CONTRACT_DIR" \
            "$IMAGE_CONTRACT_HOMEFS_FILENAME" homefs || return 1
        if [ "$IMAGE_CONTRACT_COMPRESSION" = zstd ] && ! command -v zstd >/dev/null 2>&1; then
            image_contract_fail "Imagem schema 1 usa Zstandard, mas o comando 'zstd' não está disponível."
            return 1
        fi
        image_contract_validate_checksum_manifest_coherence \
            "$IMAGE_CONTRACT_DIR/SHA256SUMS" || return 1

        if [ "$verify_hashes" -eq 1 ]; then
            hash_started=$(date +%s)
            image_contract_verify_sha256 rootfs "$IMAGE_CONTRACT_ROOTFS_ARCHIVE" \
                "$IMAGE_CONTRACT_ROOTFS_SHA256" IMAGE_CONTRACT_SHA256_ROOTFS_SECONDS || return 1
            image_contract_verify_sha256 homefs "$IMAGE_CONTRACT_HOMEFS_ARCHIVE" \
                "$IMAGE_CONTRACT_HOMEFS_SHA256" IMAGE_CONTRACT_SHA256_HOMEFS_SECONDS || return 1
            hash_finished=$(date +%s)
            IMAGE_CONTRACT_SHA256_TOTAL_SECONDS=$((hash_finished - hash_started))
            if declare -F log_info >/dev/null; then
                log_info "Validação SHA256 total concluída em $IMAGE_CONTRACT_SHA256_TOTAL_SECONDS segundo(s)."
            fi
        fi
        if declare -F log_info >/dev/null; then
            log_info "Tipo de imagem detectada: schema 1."
            log_info "Compressão da imagem: $IMAGE_CONTRACT_COMPRESSION."
        fi
    else
        IMAGE_CONTRACT_FORMAT=legacy
        IMAGE_CONTRACT_COMPRESSION=gzip
        IMAGE_CONTRACT_ROOTFS_FILENAME=rootfs.tar.gz
        IMAGE_CONTRACT_HOMEFS_FILENAME=homefs.tar.gz
        IMAGE_CONTRACT_ROOTFS_ARCHIVE="$IMAGE_CONTRACT_DIR/$IMAGE_CONTRACT_ROOTFS_FILENAME"
        IMAGE_CONTRACT_HOMEFS_ARCHIVE="$IMAGE_CONTRACT_DIR/$IMAGE_CONTRACT_HOMEFS_FILENAME"
        image_contract_validate_archive_file "$IMAGE_CONTRACT_DIR" \
            "$IMAGE_CONTRACT_ROOTFS_FILENAME" rootfs || return 1
        if [ "$storage_mode" != preserve_home ]; then
            image_contract_validate_archive_file "$IMAGE_CONTRACT_DIR" \
                "$IMAGE_CONTRACT_HOMEFS_FILENAME" homefs || return 1
        fi
        if declare -F log_info >/dev/null; then
            log_info "Tipo de imagem detectada: legacy gzip."
            log_info "Compressão da imagem: gzip."
        fi
    fi

    IMAGE_CONTRACT_READY=1
}
