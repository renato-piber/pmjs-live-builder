#!/usr/bin/env bash

generate_checksums() {
    local build_dir=$1 rootfs_file=$2 homefs_file=$3 output_file=$4
    (
        cd -- "${build_dir}"
        sha256sum -- "$(basename -- "${rootfs_file}")" "$(basename -- "${homefs_file}")"
    ) > "${output_file}"
}

validate_checksums() {
    local build_dir=$1 checksum_file=$2
    local rootfs_name=${3:-} homefs_name=${4:-}
    local -a checksum_lines

    if [[ -z "${rootfs_name}" || -z "${homefs_name}" ]]; then
        if [[ -f "${build_dir}/rootfs.tar.zst" && -f "${build_dir}/homefs.tar.zst" ]]; then
            rootfs_name=rootfs.tar.zst
            homefs_name=homefs.tar.zst
        elif [[ -f "${build_dir}/rootfs.tar.gz" && -f "${build_dir}/homefs.tar.gz" ]]; then
            rootfs_name=rootfs.tar.gz
            homefs_name=homefs.tar.gz
        else
            ui_error "Não foi possível inferir os archives cobertos por SHA256SUMS"
            return 1
        fi
    fi

    [[ -s "${checksum_file}" ]] || { ui_error "SHA256SUMS vazio"; return 1; }
    [[ $(wc -l < "${checksum_file}") -eq 2 ]] || {
        ui_error "SHA256SUMS deve conter exatamente dois artefatos"
        return 1
    }
    ! grep -Fq -- '.partial' "${checksum_file}" || {
        ui_error "SHA256SUMS contém arquivo temporário"
        return 1
    }
    mapfile -t checksum_lines < "${checksum_file}"
    [[ ${#checksum_lines[0]} -eq $(( 64 + 2 + ${#rootfs_name} )) &&
       "${checksum_lines[0]:64:2}" == "  " &&
       "${checksum_lines[0]:66}" == "${rootfs_name}" &&
       "${checksum_lines[0]:0:64}" != *[!0-9a-f]* ]] || {
        ui_error "SHA256SUMS não contém a entrada canônica de ${rootfs_name}"
        return 1
    }
    [[ ${#checksum_lines[1]} -eq $(( 64 + 2 + ${#homefs_name} )) &&
       "${checksum_lines[1]:64:2}" == "  " &&
       "${checksum_lines[1]:66}" == "${homefs_name}" &&
       "${checksum_lines[1]:0:64}" != *[!0-9a-f]* ]] || {
        ui_error "SHA256SUMS não contém a entrada canônica de ${homefs_name}"
        return 1
    }
    (cd -- "${build_dir}" && sha256sum --check --strict -- "$(basename -- "${checksum_file}")")
}

generate_manifest() {
    local output_file=$1 image_name=$2 image_version=$3 builder_version=$4
    local compression=$5 rootfs_file=$6 homefs_file=$7 source_root=$8
    local created_at architecture distribution kernel root_hash home_hash

    created_at="$(date --utc '+%Y-%m-%dT%H:%M:%SZ')"
    architecture="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    distribution="$(awk -F= '$1 == "PRETTY_NAME" { value=$2; gsub(/^"|"$/, "", value); print value; exit }' \
        "${source_root}/etc/os-release")"
    kernel="$(uname -r)"
    root_hash="$(sha256sum -- "${rootfs_file}" | awk '{print $1}')"
    home_hash="$(sha256sum -- "${homefs_file}" | awk '{print $1}')"

    python3 - "${output_file}" "${image_name}" "${image_version}" "${created_at}" \
        "${builder_version}" "${compression}" "${rootfs_file}" "${root_hash}" \
        "${homefs_file}" "${home_hash}" "${architecture}" "${distribution}" "${kernel}" <<'PY'
import json
import os
import sys

(output, image_name, image_version, created_at, builder_version, compression,
 rootfs, root_hash, homefs, home_hash, architecture, distribution, kernel) = sys.argv[1:]
manifest = {
    "schema_version": 1,
    "image_name": image_name,
    "image_version": image_version,
    "created_at": created_at,
    "builder_version": builder_version,
    "compression": compression,
    "architecture": architecture,
    "distribution": distribution,
    "builder_kernel": kernel,
    "rootfs": {"filename": os.path.basename(rootfs), "sha256": root_hash,
               "size_bytes": os.path.getsize(rootfs)},
    "homefs": {"filename": os.path.basename(homefs), "sha256": home_hash,
               "size_bytes": os.path.getsize(homefs)},
}
with open(output, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY
}

validate_manifest() {
    local manifest_file=$1 rootfs_file=$2 homefs_file=$3 compression=$4
    python3 - "${manifest_file}" "${rootfs_file}" "${homefs_file}" "${compression}" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime

manifest_path, rootfs, homefs, compression = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    data = json.load(stream)

required = {
    "schema_version", "image_name", "image_version", "created_at",
    "builder_version", "compression", "architecture",
    "distribution", "builder_kernel", "rootfs", "homefs",
}
if set(data) != required:
    raise ValueError("campos do manifest divergem do schema 1")
if type(data["schema_version"]) is not int or data["schema_version"] != 1:
    raise ValueError("schema_version do formato PMJS inválida")
if data["compression"] != compression:
    raise ValueError("compressão do manifest diverge da imagem")
for field in ("image_name", "image_version", "builder_version", "architecture",
              "distribution", "builder_kernel"):
    if not isinstance(data[field], str) or not data[field]:
        raise ValueError(f"campo textual inválido: {field}")
for field in ("image_name", "image_version"):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", data[field]):
        raise ValueError(f"identificador inseguro: {field}")
try:
    datetime.strptime(data["created_at"], "%Y-%m-%dT%H:%M:%SZ")
except (TypeError, ValueError):
    raise ValueError("created_at não está em UTC/RFC 3339")
for key, path in (("rootfs", rootfs), ("homefs", homefs)):
    if not isinstance(data[key], dict) or set(data[key]) != {"filename", "sha256", "size_bytes"}:
        raise ValueError(f"descritor inválido: {key}")
    if type(data[key]["size_bytes"]) is not int or data[key]["size_bytes"] <= 0:
        raise ValueError(f"size_bytes inválido: {key}")
    if not isinstance(data[key]["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", data[key]["sha256"]):
        raise ValueError(f"sha256 inválido: {key}")
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if data[key]["filename"] != os.path.basename(path):
        raise ValueError(f"filename divergente: {key}")
    if data[key]["size_bytes"] != os.path.getsize(path):
        raise ValueError(f"size_bytes divergente: {key}")
    if data[key]["sha256"] != digest.hexdigest():
        raise ValueError(f"sha256 divergente: {key}")

PY
}

validate_image_directory() {
    local image_dir=$1
    local rootfs_file="${image_dir}/rootfs.tar.zst"
    local homefs_file="${image_dir}/homefs.tar.zst"
    local checksum_file="${image_dir}/SHA256SUMS"
    local manifest_file="${image_dir}/manifest.json"
    local path name
    local -a expected=(SHA256SUMS homefs.tar.zst manifest.json rootfs.tar.zst)
    local -a actual=()

    [[ -d "${image_dir}" && ! -L "${image_dir}" ]] || {
        ui_error "Diretório de imagem inválido: ${image_dir}"
        return 1
    }
    while IFS= read -r -d '' path; do
        name="$(basename -- "${path}")"
        [[ -f "${path}" && ! -L "${path}" ]] || {
            ui_error "A imagem contém item que não é arquivo regular: ${name}"
            return 1
        }
        actual+=("${name}")
    done < <(find -P "${image_dir}" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
    [[ "${actual[*]}" == "${expected[*]}" ]] || {
        ui_error "Conteúdo do diretório diverge do formato PMJS schema 1"
        return 1
    }
    [[ -s "${rootfs_file}" && -s "${homefs_file}" && -s "${checksum_file}" &&
       -s "${manifest_file}" ]] || {
        ui_error "Imagem PMJS contém arquivo ausente ou vazio"
        return 1
    }

    validate_archive_compression "${rootfs_file}" zstd || {
        ui_error "rootfs.tar.zst inválido"
        return 1
    }
    validate_archive_compression "${homefs_file}" zstd || {
        ui_error "homefs.tar.zst inválido"
        return 1
    }
    tar --list --zstd --file "${rootfs_file}" >/dev/null || {
        ui_error "rootfs.tar.zst não contém um tar legível"
        return 1
    }
    tar --list --zstd --file "${homefs_file}" >/dev/null || {
        ui_error "homefs.tar.zst não contém um tar legível"
        return 1
    }
    validate_checksums "${image_dir}" "${checksum_file}" \
        rootfs.tar.zst homefs.tar.zst || return 1
    validate_manifest "${manifest_file}" "${rootfs_file}" "${homefs_file}" zstd || return 1
    python3 - "${manifest_file}" "$(basename -- "${image_dir}")" <<'PY'
import json
import re
import sys

manifest_path, actual_directory = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    data = json.load(stream)
expected = f'{data["image_name"]}-{data["image_version"]}'
staging_pattern = rf"\.{re.escape(expected)}\.(?:build|partial|sync)\.[A-Za-z0-9]+"
if actual_directory != expected and not re.fullmatch(staging_pattern, actual_directory):
    raise ValueError("nome do diretório diverge de image_name/image_version")
PY
}
