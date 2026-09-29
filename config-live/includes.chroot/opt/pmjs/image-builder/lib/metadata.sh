#!/usr/bin/env bash

read_checksum_digests() {
    local checksum_file=$1 rootfs_name=$2 homefs_name=$3
    local root_hash_ref=$4 home_hash_ref=$5
    local -a checksum_lines

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
    printf -v "${root_hash_ref}" '%s' "${checksum_lines[0]:0:64}"
    printf -v "${home_hash_ref}" '%s' "${checksum_lines[1]:0:64}"
}

generate_checksums() {
    local build_dir=$1 rootfs_file=$2 homefs_file=$3 output_file=$4
    local root_hash_ref=${5:-} home_hash_ref=${6:-}
    local perf_started perf_context rootfs_size homefs_size total_size status
    local checksum_output generated_root_hash generated_home_hash
    rootfs_size="$(stat -c '%s' -- "${rootfs_file}" 2>/dev/null || true)"
    homefs_size="$(stat -c '%s' -- "${homefs_file}" 2>/dev/null || true)"
    total_size=$(( ${rootfs_size:-0} + ${homefs_size:-0} ))
    perf_context="$(perf_archives_context "${rootfs_file}" "${homefs_file}")"
    perf_operation_start metadata.sha256sums.generate perf_started \
        "${perf_context} access=two_full_reads"
    if checksum_output="$(
        cd -- "${build_dir}"
        sha256sum -- "$(basename -- "${rootfs_file}")" "$(basename -- "${homefs_file}")"
    )"; then
        status=0
    else
        status=$?
    fi
    perf_operation_end metadata.sha256sums.generate "${perf_started}" "${status}" \
        "${total_size}" compressed_input "${perf_context} access=two_full_reads"
    (( status == 0 )) || return "${status}"
    printf '%s\n' "${checksum_output}" > "${output_file}" || return 1
    read_checksum_digests "${output_file}" "$(basename -- "${rootfs_file}")" \
        "$(basename -- "${homefs_file}")" generated_root_hash generated_home_hash || return 1
    [[ -z "${root_hash_ref}" ]] || printf -v "${root_hash_ref}" '%s' "${generated_root_hash}"
    [[ -z "${home_hash_ref}" ]] || printf -v "${home_hash_ref}" '%s' "${generated_home_hash}"
}

validate_checksums() {
    local build_dir=$1 checksum_file=$2
    local rootfs_name=${3:-} homefs_name=${4:-}
    local expected_root_hash=${5:-} expected_home_hash=${6:-}
    local root_hash_ref=${7:-} home_hash_ref=${8:-}
    local perf_started perf_context rootfs_size homefs_size total_size status
    local rootfs_file homefs_file parsed_root_hash parsed_home_hash

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

    read_checksum_digests "${checksum_file}" "${rootfs_name}" "${homefs_name}" \
        parsed_root_hash parsed_home_hash || return 1
    rootfs_file="${build_dir}/${rootfs_name}"
    homefs_file="${build_dir}/${homefs_name}"
    if [[ -n "${expected_root_hash}" || -n "${expected_home_hash}" ]]; then
        [[ -n "${expected_root_hash}" && -n "${expected_home_hash}" ]] || {
            ui_error "Reutilização SHA256 exige os dois digests"
            return 1
        }
        perf_operation_start metadata.sha256sums.verify.reused perf_started \
            "checksum_file=$(printf '%q' "${checksum_file}") access=no_archive_read"
        if [[ "${parsed_root_hash}" == "${expected_root_hash}" &&
              "${parsed_home_hash}" == "${expected_home_hash}" ]]; then
            status=0
        else
            status=1
        fi
        perf_operation_end metadata.sha256sums.verify.reused "${perf_started}" "${status}" \
            "" none "checksum_file=$(printf '%q' "${checksum_file}") access=no_archive_read"
        (( status == 0 )) || ui_error "SHA256SUMS diverge dos digests recém-calculados"
    else
        rootfs_size="$(stat -c '%s' -- "${rootfs_file}" 2>/dev/null || true)"
        homefs_size="$(stat -c '%s' -- "${homefs_file}" 2>/dev/null || true)"
        total_size=$(( ${rootfs_size:-0} + ${homefs_size:-0} ))
        perf_context="$(perf_archives_context "${rootfs_file}" "${homefs_file}")"
        perf_operation_start metadata.sha256sums.verify perf_started \
            "checksum_file=$(printf '%q' "${checksum_file}") ${perf_context} access=two_full_reads"
        if (cd -- "${build_dir}" && sha256sum --check --strict -- "$(basename -- "${checksum_file}")"); then
            status=0
        else
            status=$?
        fi
        perf_operation_end metadata.sha256sums.verify "${perf_started}" "${status}" \
            "${total_size}" compressed_input \
            "checksum_file=$(printf '%q' "${checksum_file}") ${perf_context} access=two_full_reads"
    fi
    (( status == 0 )) || return "${status}"
    [[ -z "${root_hash_ref}" ]] || printf -v "${root_hash_ref}" '%s' "${parsed_root_hash}"
    [[ -z "${home_hash_ref}" ]] || printf -v "${home_hash_ref}" '%s' "${parsed_home_hash}"
}

generate_manifest() {
    local output_file=$1 image_name=$2 image_version=$3 builder_version=$4
    local compression=$5 rootfs_file=$6 homefs_file=$7 source_root=$8
    local supplied_root_hash=${9:-} supplied_home_hash=${10:-}
    local created_at architecture distribution kernel root_hash home_hash
    local perf_started perf_context perf_size status

    created_at="$(date --utc '+%Y-%m-%dT%H:%M:%SZ')"
    architecture="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    distribution="$(awk -F= '$1 == "PRETTY_NAME" { value=$2; gsub(/^"|"$/, "", value); print value; exit }' \
        "${source_root}/etc/os-release")"
    kernel="$(uname -r)"
    if [[ -n "${supplied_root_hash}" || -n "${supplied_home_hash}" ]]; then
        [[ "${supplied_root_hash}" =~ ^[0-9a-f]{64}$ &&
           "${supplied_home_hash}" =~ ^[0-9a-f]{64}$ ]] || {
            ui_error "Digests reutilizados para o manifest são inválidos"
            return 1
        }
        root_hash=${supplied_root_hash}
        home_hash=${supplied_home_hash}
        perf_operation_start metadata.manifest.hashes.reused perf_started \
            "access=no_archive_read source=SHA256SUMS_generation"
        perf_operation_end metadata.manifest.hashes.reused "${perf_started}" 0 \
            "" none "access=no_archive_read source=SHA256SUMS_generation"
    else
        perf_size="$(stat -c '%s' -- "${rootfs_file}" 2>/dev/null || true)"
        perf_context="$(perf_archive_context "${rootfs_file}")"
        perf_operation_start metadata.manifest.rootfs_sha256 perf_started \
            "${perf_context} access=full_read"
        if root_hash="$(sha256sum -- "${rootfs_file}" | awk '{print $1}')"; then
            status=0
        else
            status=$?
        fi
        perf_operation_end metadata.manifest.rootfs_sha256 "${perf_started}" "${status}" \
            "${perf_size}" compressed_input "${perf_context} access=full_read"
        (( status == 0 )) || return "${status}"

        perf_size="$(stat -c '%s' -- "${homefs_file}" 2>/dev/null || true)"
        perf_context="$(perf_archive_context "${homefs_file}")"
        perf_operation_start metadata.manifest.homefs_sha256 perf_started \
            "${perf_context} access=full_read"
        if home_hash="$(sha256sum -- "${homefs_file}" | awk '{print $1}')"; then
            status=0
        else
            status=$?
        fi
        perf_operation_end metadata.manifest.homefs_sha256 "${perf_started}" "${status}" \
            "${perf_size}" compressed_input "${perf_context} access=full_read"
        (( status == 0 )) || return "${status}"
    fi

    perf_operation_start metadata.manifest.write perf_started \
        "manifest=$(printf '%q' "${output_file}") access=small_metadata_write"
    if python3 - "${output_file}" "${image_name}" "${image_version}" "${created_at}" \
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
    then
        status=0
    else
        status=$?
    fi
    perf_operation_end metadata.manifest.write "${perf_started}" "${status}" \
        "" none "manifest=$(printf '%q' "${output_file}") access=small_metadata_write"
    (( status == 0 )) || return "${status}"
}

validate_manifest() {
    local manifest_file=$1 rootfs_file=$2 homefs_file=$3 compression=$4
    local expected_root_hash=${5:-} expected_home_hash=${6:-}
    local perf_started perf_context rootfs_size homefs_size total_size status
    rootfs_size="$(stat -c '%s' -- "${rootfs_file}" 2>/dev/null || true)"
    homefs_size="$(stat -c '%s' -- "${homefs_file}" 2>/dev/null || true)"
    total_size=$(( ${rootfs_size:-0} + ${homefs_size:-0} ))
    perf_context="$(perf_archives_context "${rootfs_file}" "${homefs_file}")"
    if [[ -n "${expected_root_hash}" || -n "${expected_home_hash}" ]]; then
        [[ "${expected_root_hash}" =~ ^[0-9a-f]{64}$ &&
           "${expected_home_hash}" =~ ^[0-9a-f]{64}$ ]] || {
            ui_error "Digests reutilizados para validar o manifest são inválidos"
            return 1
        }
        perf_operation_start metadata.manifest.validate.reused perf_started \
            "manifest=$(printf '%q' "${manifest_file}") ${perf_context} access=no_archive_read"
    else
        perf_operation_start metadata.manifest.validate perf_started \
            "manifest=$(printf '%q' "${manifest_file}") ${perf_context} access=two_full_reads"
    fi
    if python3 - "${manifest_file}" "${rootfs_file}" "${homefs_file}" "${compression}" \
        "${expected_root_hash}" "${expected_home_hash}" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime

manifest_path, rootfs, homefs, compression, expected_root_hash, expected_home_hash = sys.argv[1:]
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
expected_hashes = {"rootfs": expected_root_hash, "homefs": expected_home_hash}
for key, path in (("rootfs", rootfs), ("homefs", homefs)):
    if not isinstance(data[key], dict) or set(data[key]) != {"filename", "sha256", "size_bytes"}:
        raise ValueError(f"descritor inválido: {key}")
    if type(data[key]["size_bytes"]) is not int or data[key]["size_bytes"] <= 0:
        raise ValueError(f"size_bytes inválido: {key}")
    if not isinstance(data[key]["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", data[key]["sha256"]):
        raise ValueError(f"sha256 inválido: {key}")
    actual_hash = expected_hashes[key]
    if not actual_hash:
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        actual_hash = digest.hexdigest()
    if data[key]["filename"] != os.path.basename(path):
        raise ValueError(f"filename divergente: {key}")
    if data[key]["size_bytes"] != os.path.getsize(path):
        raise ValueError(f"size_bytes divergente: {key}")
    if data[key]["sha256"] != actual_hash:
        raise ValueError(f"sha256 divergente: {key}")

PY
    then
        status=0
    else
        status=$?
    fi
    if [[ -n "${expected_root_hash}" ]]; then
        perf_operation_end metadata.manifest.validate.reused "${perf_started}" "${status}" \
            "" none \
            "manifest=$(printf '%q' "${manifest_file}") ${perf_context} access=no_archive_read"
    else
        perf_operation_end metadata.manifest.validate "${perf_started}" "${status}" \
            "${total_size}" compressed_input \
            "manifest=$(printf '%q' "${manifest_file}") ${perf_context} access=two_full_reads"
    fi
    (( status == 0 )) || return "${status}"
}

validate_image_directory() {
    local image_dir=$1
    local rootfs_file="${image_dir}/rootfs.tar.zst"
    local homefs_file="${image_dir}/homefs.tar.zst"
    local checksum_file="${image_dir}/SHA256SUMS"
    local manifest_file="${image_dir}/manifest.json"
    local path name perf_started perf_context perf_size status
    local verified_root_hash verified_home_hash
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

    perf_size="$(stat -c '%s' -- "${rootfs_file}" 2>/dev/null || true)"
    perf_context="$(perf_archive_context "${rootfs_file}")"
    perf_operation_start bundle.rootfs.integrity.zstd perf_started \
        "${perf_context} access=full_read+full_decompression"
    if validate_archive_compression "${rootfs_file}" zstd; then status=0; else status=$?; fi
    perf_operation_end bundle.rootfs.integrity.zstd "${perf_started}" "${status}" \
        "${perf_size}" compressed_input "${perf_context} access=full_read+full_decompression"
    (( status == 0 )) || {
        ui_error "rootfs.tar.zst inválido"
        return 1
    }
    perf_size="$(stat -c '%s' -- "${homefs_file}" 2>/dev/null || true)"
    perf_context="$(perf_archive_context "${homefs_file}")"
    perf_operation_start bundle.homefs.integrity.zstd perf_started \
        "${perf_context} access=full_read+full_decompression"
    if validate_archive_compression "${homefs_file}" zstd; then status=0; else status=$?; fi
    perf_operation_end bundle.homefs.integrity.zstd "${perf_started}" "${status}" \
        "${perf_size}" compressed_input "${perf_context} access=full_read+full_decompression"
    (( status == 0 )) || {
        ui_error "homefs.tar.zst inválido"
        return 1
    }
    perf_size="$(stat -c '%s' -- "${rootfs_file}" 2>/dev/null || true)"
    perf_context="$(perf_archive_context "${rootfs_file}")"
    perf_operation_start bundle.rootfs.tar_listing perf_started \
        "${perf_context} access=full_read+full_decompression"
    if tar --list --zstd --file "${rootfs_file}" >/dev/null; then status=0; else status=$?; fi
    perf_operation_end bundle.rootfs.tar_listing "${perf_started}" "${status}" \
        "${perf_size}" compressed_input "${perf_context} access=full_read+full_decompression"
    (( status == 0 )) || {
        ui_error "rootfs.tar.zst não contém um tar legível"
        return 1
    }
    perf_size="$(stat -c '%s' -- "${homefs_file}" 2>/dev/null || true)"
    perf_context="$(perf_archive_context "${homefs_file}")"
    perf_operation_start bundle.homefs.tar_listing perf_started \
        "${perf_context} access=full_read+full_decompression"
    if tar --list --zstd --file "${homefs_file}" >/dev/null; then status=0; else status=$?; fi
    perf_operation_end bundle.homefs.tar_listing "${perf_started}" "${status}" \
        "${perf_size}" compressed_input "${perf_context} access=full_read+full_decompression"
    (( status == 0 )) || {
        ui_error "homefs.tar.zst não contém um tar legível"
        return 1
    }
    validate_checksums "${image_dir}" "${checksum_file}" \
        rootfs.tar.zst homefs.tar.zst "" "" \
        verified_root_hash verified_home_hash || return 1
    # O sha256sum --check acima acabou de verificar os bytes armazenados. O
    # manifest deve concordar com esses mesmos digests; recalcular os archives
    # aqui seria uma segunda leitura sem qualquer mutação legítima intermediária.
    validate_manifest "${manifest_file}" "${rootfs_file}" "${homefs_file}" zstd \
        "${verified_root_hash}" "${verified_home_hash}" || return 1
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
