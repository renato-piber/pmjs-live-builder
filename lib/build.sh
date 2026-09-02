#!/usr/bin/env bash

iso_filename() {
    printf '%s-%s-%s.iso\n' "$LIVE_NAME" "$LIVE_VERSION" "$LIVE_ARCH"
}

assert_safe_work_dir() {
    local candidate=$1
    local resolved root_resolved
    resolved=$(realpath -m -- "$candidate")
    root_resolved=$(realpath -m -- "$PROJECT_ROOT")

    [[ "$resolved" != / ]] || return 1
    [[ "$resolved" != "$root_resolved" ]] || return 1
    case "$resolved" in
        "${root_resolved}/work"|"${root_resolved}/work/"*) ;;
        *) return 1 ;;
    esac
    [[ ! -L "$candidate" ]] || return 1
}

clean_workdir() {
    assert_safe_work_dir "$WORK_DIR_ABS" || die "Clean recusado para caminho inseguro: $WORK_DIR_ABS"

    if [[ -d "$WORK_DIR_ABS/config" ]] && command -v lb >/dev/null 2>&1; then
        ui_step "Executando limpeza do live-build"
        (cd "$WORK_DIR_ABS" && lb clean --purge)
    fi

    if command -v findmnt >/dev/null 2>&1 && findmnt -rn -o TARGET | awk -v path="$WORK_DIR_ABS" '$0 == path || index($0, path "/") == 1 { found=1 } END { exit !found }'; then
        die "Clean recusado: ainda existem mounts sob $WORK_DIR_ABS. Desmonte-os antes de continuar."
    fi

    mkdir -p -- "$WORK_DIR_ABS"
    find "$WORK_DIR_ABS" -xdev -mindepth 1 -delete
    ui_ok "Workdir limpo: $WORK_DIR_ABS"
}

configure_live_build() {
    local image_base
    image_base="${LIVE_NAME}-${LIVE_VERSION}-${LIVE_ARCH}"

    ui_step "Configurando live-build"
    (
        cd "$WORK_DIR_ABS"
        lb config \
            --ignore-system-defaults \
            --mode debian \
            --distribution "$DEBIAN_SUITE" \
            --architecture "$LIVE_ARCH" \
            --binary-image iso-hybrid \
            --bootloaders "grub-pc grub-efi" \
            --uefi-secure-boot auto \
            --archive-areas "$ARCHIVE_AREAS" \
            --mirror-bootstrap "$DEBIAN_MIRROR" \
            --mirror-chroot "$DEBIAN_MIRROR" \
            --mirror-chroot-security "$DEBIAN_SECURITY_MIRROR" \
            --mirror-binary "$DEBIAN_MIRROR" \
            --mirror-binary-security "$DEBIAN_SECURITY_MIRROR" \
            --security true \
            --updates true \
            --apt-recommends false \
            --binary-filesystem fat32 \
            --chroot-filesystem squashfs \
            --chroot-squashfs-compression-type zstd \
            --checksums sha256 \
            --debian-installer none \
            --memtest none \
            --source false \
            --image-name "$image_base" \
            --iso-application "PMJS Live ${LIVE_VERSION}" \
            --iso-publisher "PMJS" \
            --iso-volume "PMJS_LIVE" \
            --bootappend-live "boot=live components username=${LIVE_USER} hostname=${LIVE_HOSTNAME} locales=${LIVE_LOCALE} keyboard-layouts=${LIVE_KEYBOARD_LAYOUT}"
    )

    ui_step "Aplicando package lists, includes e hooks versionados"
    cp -a -- "${PROJECT_ROOT}/config-live/." "${WORK_DIR_ABS}/config/"
}

build_iso() {
    ui_step "Construindo a ISO (a saida completa do live-build sera preservada)"
    (cd "$WORK_DIR_ABS" && lb build)
}

locate_built_iso() {
    local -a candidates=()
    mapfile -t candidates < <(find "$WORK_DIR_ABS" -maxdepth 1 -type f \( -name '*.hybrid.iso' -o -name '*.iso' \) -print | sort)
    (( ${#candidates[@]} == 1 )) || die "Esperava exatamente uma ISO no workdir; encontrei ${#candidates[@]}."
    printf '%s\n' "${candidates[0]}"
}

smoke_test_iso() {
    local iso_path=$1 report listing
    [[ -f "$iso_path" && -s "$iso_path" ]] || die "ISO ausente ou vazia: $iso_path"
    command -v xorriso >/dev/null 2>&1 || die "xorriso e necessario para o smoke test."

    report=$(xorriso -indev "$iso_path" -report_el_torito plain 2>&1)
    grep -Eq 'BIOS|0x00' <<< "$report" || die "Smoke test: entrada de boot Legacy BIOS nao encontrada."
    grep -Eq 'UEFI|0xef' <<< "$report" || die "Smoke test: entrada de boot UEFI nao encontrada."
    listing=$(xorriso -indev "$iso_path" -ls /live 2>&1)
    grep -q 'filesystem.squashfs' <<< "$listing" || die "Smoke test: filesystem.squashfs nao encontrado em /live."
    ui_ok "Estrutura ISO, SquashFS e entradas El Torito BIOS/UEFI detectadas"
    ui_warn "Este smoke test nao substitui boot em VM, UEFI real e Legacy BIOS real."
}

publish_iso() {
    local built_iso=$1 output_name final_path temp_path checksum_temp size sha
    output_name=$(iso_filename)
    final_path="${OUTPUT_DIR_ABS}/${output_name}"
    temp_path="${OUTPUT_DIR_ABS}/.${output_name}.tmp.$$"
    checksum_temp="${OUTPUT_DIR_ABS}/.SHA256SUMS.tmp.$$"

    mkdir -p -- "$OUTPUT_DIR_ABS"
    install -m 0644 -- "$built_iso" "$temp_path"
    mv -f -- "$temp_path" "$final_path"
    (
        cd "$OUTPUT_DIR_ABS"
        sha256sum "$output_name" > "$checksum_temp"
        mv -f -- "$checksum_temp" SHA256SUMS
    )

    size=$(du -h "$final_path" | awk '{print $1}')
    sha=$(sha256sum "$final_path" | awk '{print $1}')
    log_info "ISO publicada: $final_path"
    log_info "Tamanho: $size"
    log_info "SHA256: $sha"
    PUBLISHED_ISO=$final_path
}

run_build_pipeline() {
    local built_iso
    run_preflight
    ui_step "Preparando workdir descartavel"
    clean_workdir
    configure_live_build
    build_iso
    built_iso=$(locate_built_iso)
    ui_step "Validando artefato antes da publicacao"
    smoke_test_iso "$built_iso"
    publish_iso "$built_iso"
    ui_ok "Build concluido: $PUBLISHED_ISO"
}
