#!/usr/bin/env bash

PUBLISHED_ISO=''

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

assert_safe_cache_dir() {
    local candidate=$1
    local resolved root_resolved
    resolved=$(realpath -m -- "$candidate")
    root_resolved=$(realpath -m -- "$PROJECT_ROOT")

    [[ "$resolved" == "${root_resolved}/cache" ]] || return 1
    [[ ! -L "$candidate" ]] || return 1
}

managed_path_has_mounts() {
    local path=$1
    command -v findmnt >/dev/null 2>&1 || return 1
    findmnt -rn -o TARGET | awk -v path="$path" '$0 == path || index($0, path "/") == 1 { found=1 } END { exit !found }'
}

directory_is_empty() {
    [[ -d "$1" ]] && [[ -z "$(find "$1" -mindepth 1 -print -quit)" ]]
}

prepare_persistent_cache() {
    local legacy_cache="${WORK_DIR_ABS}/cache" link_target
    if ! assert_safe_work_dir "$WORK_DIR_ABS"; then
        die "Workdir inseguro durante preparacao do cache: $WORK_DIR_ABS"
        return 1
    fi
    if ! assert_safe_cache_dir "$CACHE_DIR_ABS"; then
        die "Cache recusado para caminho inseguro ou symlink: $CACHE_DIR_ABS"
        return 1
    fi

    if [[ -L "$legacy_cache" ]]; then
        link_target=$(realpath -- "$legacy_cache" 2>/dev/null || true)
        if [[ "$link_target" != "$CACHE_DIR_ABS" ]]; then
            die "Symlink de cache inesperado em $legacy_cache; esperado: $CACHE_DIR_ABS"
            return 1
        fi
    elif [[ -e "$legacy_cache" ]]; then
        if [[ ! -d "$legacy_cache" ]]; then
            die "Cache legado nao e um diretorio: $legacy_cache"
            return 1
        fi
        if managed_path_has_mounts "$legacy_cache"; then
            die "Migracao recusada: existem mounts sob o cache legado $legacy_cache"
            return 1
        fi
        if [[ -e "$CACHE_DIR_ABS" || -L "$CACHE_DIR_ABS" ]]; then
            if ! assert_safe_cache_dir "$CACHE_DIR_ABS"; then
                die "Cache persistente inseguro: $CACHE_DIR_ABS"
                return 1
            fi
            if directory_is_empty "$CACHE_DIR_ABS"; then
                if ! rmdir -- "$CACHE_DIR_ABS" || ! mv -- "$legacy_cache" "$CACHE_DIR_ABS"; then
                    die "Falha ao migrar o cache legado para $CACHE_DIR_ABS"
                    return 1
                fi
                log_info "Cache nativo legado migrado de $legacy_cache para $CACHE_DIR_ABS"
            elif directory_is_empty "$legacy_cache"; then
                if ! rmdir -- "$legacy_cache"; then
                    die "Falha ao remover cache legado vazio: $legacy_cache"
                    return 1
                fi
            else
                die "Existem caches nao vazios em $legacy_cache e $CACHE_DIR_ABS; mesclagem automatica recusada."
                return 1
            fi
        else
            if ! mv -- "$legacy_cache" "$CACHE_DIR_ABS"; then
                die "Falha ao migrar o cache legado para $CACHE_DIR_ABS"
                return 1
            fi
            log_info "Cache nativo legado migrado de $legacy_cache para $CACHE_DIR_ABS"
        fi
    fi

    if ! mkdir -p -- "$CACHE_DIR_ABS"; then
        die "Falha ao criar o cache persistente: $CACHE_DIR_ABS"
        return 1
    fi
    if ! assert_safe_cache_dir "$CACHE_DIR_ABS"; then
        die "Cache persistente inseguro apos criacao: $CACHE_DIR_ABS"
        return 1
    fi
}

clean_workdir() {
    if ! assert_safe_work_dir "$WORK_DIR_ABS"; then
        die "Clean recusado para caminho inseguro: $WORK_DIR_ABS"
        return 1
    fi

    if [[ -d "$WORK_DIR_ABS/config" ]] && command -v lb >/dev/null 2>&1; then
        ui_step "Executando limpeza do live-build"
        if ! (cd "$WORK_DIR_ABS" && lb clean); then
            die "O live-build nao conseguiu limpar o estado anterior."
            return 1
        fi
    fi

    if managed_path_has_mounts "$WORK_DIR_ABS"; then
        die "Clean recusado: ainda existem mounts sob $WORK_DIR_ABS. Desmonte-os antes de continuar."
        return 1
    fi

    if ! mkdir -p -- "$WORK_DIR_ABS"; then
        die "Falha ao criar o workdir: $WORK_DIR_ABS"
        return 1
    fi
    if ! find "$WORK_DIR_ABS" -xdev -mindepth 1 -delete; then
        die "Falha ao esvaziar o workdir validado: $WORK_DIR_ABS"
        return 1
    fi
    ui_ok "Workdir limpo: $WORK_DIR_ABS"
}

clean_work_preserving_all_cache() {
    prepare_persistent_cache || return 1
    clean_workdir || return 1
    ui_ok "Estado de work removido; cache persistente preservado em $CACHE_DIR_ABS"
}

remove_cached_build_stages() {
    local stage_path stage_name
    for stage_name in bootstrap chroot binary_rootfs; do
        stage_path="${CACHE_DIR_ABS}/${stage_name}"
        if [[ -L "$stage_path" ]]; then
            die "Clean recusado: cache de estagio e symlink: $stage_path"
            return 1
        elif [[ -d "$stage_path" ]]; then
            if managed_path_has_mounts "$stage_path"; then
                die "Clean recusado: existem mounts sob $stage_path"
                return 1
            fi
            if ! find "$stage_path" -xdev -mindepth 1 -delete || ! rmdir -- "$stage_path"; then
                die "Falha ao remover cache de estagio: $stage_path"
                return 1
            fi
        elif [[ -e "$stage_path" ]]; then
            die "Clean recusado: cache de estagio inesperado: $stage_path"
            return 1
        fi
    done
}

clean_state_preserving_cache() {
    clean_work_preserving_all_cache || return 1
    remove_cached_build_stages || return 1
    ui_ok "Estado e snapshots de build removidos; downloads .deb preservados em $CACHE_DIR_ABS"
}

link_persistent_cache() {
    local cache_link="${WORK_DIR_ABS}/cache"
    if [[ -e "$cache_link" || -L "$cache_link" ]]; then
        die "Nao e seguro criar o link de cache: $cache_link ja existe."
        return 1
    fi
    if ! ln -s -- "$CACHE_DIR_ABS" "$cache_link"; then
        die "Falha ao criar o link do cache persistente."
        return 1
    fi
    if [[ "$(realpath -- "$cache_link")" != "$CACHE_DIR_ABS" ]]; then
        die "Falha ao validar o link do cache persistente."
        return 1
    fi
}

prepare_build_workspace() {
    clean_work_preserving_all_cache || return 1
    if [[ "$CACHE_ENABLED" == true ]]; then
        link_persistent_cache || return 1
    fi
}

purge_persistent_cache() {
    if ! assert_safe_cache_dir "$CACHE_DIR_ABS"; then
        die "Purge recusado para caminho inseguro ou symlink: $CACHE_DIR_ABS"
        return 1
    fi
    if managed_path_has_mounts "$CACHE_DIR_ABS"; then
        die "Purge recusado: ainda existem mounts sob $CACHE_DIR_ABS."
        return 1
    fi
    if ! mkdir -p -- "$CACHE_DIR_ABS"; then
        die "Falha ao criar o diretorio de cache para purge: $CACHE_DIR_ABS"
        return 1
    fi
    if ! assert_safe_cache_dir "$CACHE_DIR_ABS"; then
        die "Cache inseguro apos preparacao do purge: $CACHE_DIR_ABS"
        return 1
    fi
    if ! find "$CACHE_DIR_ABS" -xdev -mindepth 1 -delete; then
        die "Falha ao esvaziar o cache validado: $CACHE_DIR_ABS"
        return 1
    fi
    ui_ok "Cache persistente removido: $CACHE_DIR_ABS"
}

purge_builder_state() {
    clean_state_preserving_cache || return 1
    purge_persistent_cache || return 1
}

log_cache_metrics() {
    local phase=${1:-estado} size='0' deb_count='0'
    if [[ -d "${CACHE_DIR_ABS:-}" && ! -L "${CACHE_DIR_ABS:-}" ]]; then
        size=$(du -sh -- "$CACHE_DIR_ABS" 2>/dev/null | awk '{print $1}' || true)
        deb_count=$(find "$CACHE_DIR_ABS" -xdev -type f -name '*.deb' -print 2>/dev/null | wc -l || true)
    fi
    log_info "Cache ($phase): habilitado=${CACHE_ENABLED:-desconhecido}; local=${CACHE_DIR_ABS:-nao-configurado}; tamanho=${size:-0}; pacotes_deb=$deb_count"
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
            --cache "$CACHE_ENABLED" \
            --cache-packages "$CACHE_PACKAGES" \
            --cache-indices "$CACHE_INDICES" \
            --cache-stages "$CACHE_STAGES" \
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
    if (( ${#candidates[@]} != 1 )); then
        die "Esperava exatamente uma ISO no workdir; encontrei ${#candidates[@]}."
        return 1
    fi
    printf '%s\n' "${candidates[0]}"
}

smoke_test_iso() {
    local iso_path=$1 report listing
    if [[ ! -f "$iso_path" || ! -s "$iso_path" ]]; then
        die "ISO ausente ou vazia: $iso_path"
        return 1
    fi
    if ! command -v xorriso >/dev/null 2>&1; then
        die "xorriso e necessario para o smoke test."
        return 1
    fi

    report=$(xorriso -indev "$iso_path" -report_el_torito plain 2>&1)
    if ! grep -Eq 'BIOS|0x00' <<< "$report"; then
        die "Smoke test: entrada de boot Legacy BIOS nao encontrada."
        return 1
    fi
    if ! grep -Eq 'UEFI|0xef' <<< "$report"; then
        die "Smoke test: entrada de boot UEFI nao encontrada."
        return 1
    fi
    listing=$(xorriso -indev "$iso_path" -ls /live 2>&1)
    if ! grep -q 'filesystem.squashfs' <<< "$listing"; then
        die "Smoke test: filesystem.squashfs nao encontrado em /live."
        return 1
    fi
    ui_ok "Estrutura ISO, SquashFS e entradas El Torito BIOS/UEFI detectadas"
    ui_warn "Este smoke test nao substitui boot em VM, UEFI real e Legacy BIOS real."
}

squashfs_has_path() {
    local squashfs=$1 path=$2
    unsquashfs -ll "$squashfs" "$path" 2>/dev/null | grep -Fq "squashfs-root/${path}"
}

validate_live_filesystem() {
    local squashfs=$1 path
    local -a required_paths=(
        usr/bin/python3
        usr/bin/bash
        usr/bin/tar
        usr/bin/gzip
        usr/bin/zstd
        usr/bin/rsync
        usr/bin/sha256sum
        usr/bin/btrfs
        usr/bin/lsblk
        usr/sbin/blkid
        usr/bin/findmnt
        usr/bin/mount
        usr/bin/umount
        usr/sbin/parted
        usr/sbin/mkfs.vfat
        usr/sbin/mkswap
        usr/sbin/swapon
        usr/sbin/swapoff
        usr/sbin/grub-install
        usr/sbin/update-grub
        usr/sbin/chroot
        usr/bin/ssh-keygen
        usr/sbin/mount.nfs
        usr/bin/curl
        usr/bin/wget
        usr/bin/ip
        usr/bin/ping
        usr/sbin/smartctl
        usr/sbin/nvme
        usr/bin/testdisk
        usr/bin/ddrescue
        usr/bin/jq
        usr/bin/pluma
        usr/bin/filezilla
        usr/sbin/gparted
        usr/bin/gnome-disks
        usr/bin/timeout
        usr/sbin/showmount
        usr/sbin/blockdev
        usr/sbin/mkfs.btrfs
        usr/sbin/mkfs.ext4
        usr/sbin/wipefs
        usr/bin/udevadm
        usr/local/bin/pmjs-deploy
        usr/local/bin/pmjs-image-builder
        opt/pmjs/deploy/deploy.sh
        opt/pmjs/deploy/config/deploy.conf
        opt/pmjs/deploy/lib/image_contract.sh
        opt/pmjs/image-builder/build-image.sh
        opt/pmjs/image-builder/config/image.conf
        opt/pmjs/image-builder/lib/metadata.sh
        usr/share/applications/pmjs-deploy.desktop
        usr/share/applications/pmjs-image-builder.desktop
        usr/share/pixmaps/pmjs-deploy.png
        usr/share/pixmaps/pmjs-image-builder.png
        usr/share/backgrounds/pmjs/pmjs-wallpaper.jpg
        usr/lib/firmware/amdgpu/renoir_asd.bin
        usr/lib/firmware/amdgpu/renoir_dmcub.bin
        usr/lib/firmware/amdgpu/renoir_pfp.bin
        usr/lib/firmware/amdgpu/renoir_sdma.bin
        usr/lib/firmware/amdgpu/renoir_vcn.bin
    )

    if [[ ! -f "$squashfs" || ! -s "$squashfs" ]]; then
        die "SquashFS ausente ou vazio: $squashfs"
        return 1
    fi
    if ! command -v unsquashfs >/dev/null 2>&1; then
        die "unsquashfs e necessario para validar executaveis da Live."
        return 1
    fi

    for path in "${required_paths[@]}"; do
        if ! squashfs_has_path "$squashfs" "$path"; then
            die "Validacao da Live: arquivo critico ausente no SquashFS: /$path"
            return 1
        fi
    done
    ui_ok "Todos os ${#required_paths[@]} arquivos criticos, incluindo aplicativos PMJS e firmware Renoir, foram encontrados no SquashFS"
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
    ui_step "Preparando workdir descartavel com cache persistente"
    prepare_build_workspace
    log_cache_metrics antes-do-build
    configure_live_build
    build_iso
    built_iso=$(locate_built_iso)
    ui_step "Validando artefato antes da publicacao"
    smoke_test_iso "$built_iso"
    validate_live_filesystem "${WORK_DIR_ABS}/binary/live/filesystem.squashfs"
    publish_iso "$built_iso"
    ui_ok "Build concluido: $PUBLISHED_ISO"
}
