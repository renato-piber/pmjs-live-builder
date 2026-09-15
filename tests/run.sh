#!/usr/bin/env bash
set -uo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export PROJECT_ROOT

# shellcheck source=../lib/ui.sh
source "${PROJECT_ROOT}/lib/ui.sh"
# shellcheck source=../lib/logs.sh
source "${PROJECT_ROOT}/lib/logs.sh"
# shellcheck source=../lib/checks.sh
source "${PROJECT_ROOT}/lib/checks.sh"
# shellcheck source=../lib/build.sh
source "${PROJECT_ROOT}/lib/build.sh"
# Carrega tambem o parser CLI; main nao e executado quando o arquivo e sourced.
# shellcheck source=../build-live.sh
source "${PROJECT_ROOT}/build-live.sh"
# O atualizador expoe as listas controladas quando carregado como biblioteca.
# shellcheck source=../tools/update-pmjs-snapshots.sh
source "${PROJECT_ROOT}/tools/update-pmjs-snapshots.sh"

tests_run=0
tests_failed=0
TEST_ROOT=''
TEST_ORIGINAL_PROJECT_ROOT=''
TEST_ORIGINAL_WORK_DIR_ABS=''
TEST_ORIGINAL_CACHE_DIR_ABS=''
TEST_EXTERNAL_ROOT=''

setup_test_sandbox() {
    TEST_ORIGINAL_PROJECT_ROOT=$PROJECT_ROOT
    TEST_ORIGINAL_WORK_DIR_ABS=${WORK_DIR_ABS:-}
    TEST_ORIGINAL_CACHE_DIR_ABS=${CACHE_DIR_ABS:-}
    TEST_ROOT=$(mktemp -d /tmp/pmjs-live-builder-test.XXXXXX)
    TEST_EXTERNAL_ROOT=$(mktemp -d /tmp/pmjs-live-builder-external.XXXXXX)
    PROJECT_ROOT=$TEST_ROOT
    WORK_DIR_ABS="${TEST_ROOT}/work"
    CACHE_DIR_ABS="${TEST_ROOT}/cache"
    CACHE_ENABLED=true
    mkdir -p -- "$WORK_DIR_ABS"
}

cleanup_test_sandbox() {
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        find "$TEST_ROOT" -xdev -mindepth 1 -delete
        rmdir -- "$TEST_ROOT"
    fi
    if [[ -n "$TEST_EXTERNAL_ROOT" && -d "$TEST_EXTERNAL_ROOT" ]]; then
        find "$TEST_EXTERNAL_ROOT" -xdev -mindepth 1 -delete
        rmdir -- "$TEST_EXTERNAL_ROOT"
    fi
    if [[ -n "$TEST_ORIGINAL_PROJECT_ROOT" ]]; then
        PROJECT_ROOT=$TEST_ORIGINAL_PROJECT_ROOT
        WORK_DIR_ABS=$TEST_ORIGINAL_WORK_DIR_ABS
        CACHE_DIR_ABS=$TEST_ORIGINAL_CACHE_DIR_ABS
    fi
    TEST_ROOT=''
    TEST_EXTERNAL_ROOT=''
}

run_test() {
    local name=$1 status=0
    shift
    tests_run=$((tests_run + 1))
    "$@" >/tmp/pmjs-live-test-output.$$ 2>&1 || status=$?
    cleanup_test_sandbox >/dev/null 2>&1 || true
    if (( status == 0 )); then
        printf 'ok %d - %s\n' "$tests_run" "$name"
    else
        printf 'not ok %d - %s\n' "$tests_run" "$name"
        sed 's/^/  /' /tmp/pmjs-live-test-output.$$
        tests_failed=$((tests_failed + 1))
    fi
}

test_config_parsing() {
    load_live_config "${PROJECT_ROOT}/config/live.conf"
    validate_config
    [[ "$LIVE_NAME" == pmjs-live ]]
    [[ "$LIVE_VERSION" == 0.1.2 ]]
    [[ "$DEBIAN_SUITE" == trixie ]]
    [[ "$CACHE_ENABLED" == true ]]
    [[ "$CACHE_DIR_ABS" == "${PROJECT_ROOT}/cache" ]]
    [[ "$CACHE_STAGES" == bootstrap ]]
}

test_output_name() {
    load_live_config "${PROJECT_ROOT}/config/live.conf"
    [[ "$(iso_filename)" == pmjs-live-0.1.2-amd64.iso ]]
}

test_suite_validation() {
    validate_suite trixie
    validate_suite bookworm
    ! validate_suite stable
    ! validate_suite 'trixie;id'
    ! validate_suite ''
}

test_architecture_validation() {
    validate_architecture amd64
    ! validate_architecture i386
    ! validate_architecture arm64
}

test_missing_dependency_detection() {
    local output status=0
    output=$(missing_commands sh pmjs-command-that-does-not-exist) || status=$?
    [[ "$status" == 1 ]]
    [[ "$output" == pmjs-command-that-does-not-exist ]]
}

test_clean_path_guards() {
    assert_safe_work_dir "${PROJECT_ROOT}/work"
    assert_safe_work_dir "${PROJECT_ROOT}/work/unit-test"
    ! assert_safe_work_dir /
    ! assert_safe_work_dir "$PROJECT_ROOT"
    ! assert_safe_work_dir "${PROJECT_ROOT}/output"
    ! assert_safe_work_dir "${PROJECT_ROOT}/../work"
    assert_safe_cache_dir "${PROJECT_ROOT}/cache"
    ! assert_safe_cache_dir /
    ! assert_safe_cache_dir "$PROJECT_ROOT"
    ! assert_safe_cache_dir "${PROJECT_ROOT}/output"
}

test_normal_build_preserves_cache() {
    setup_test_sandbox
    mkdir -p -- "$CACHE_DIR_ABS"
    : > "${CACHE_DIR_ABS}/cached.deb"
    mkdir -p -- "${CACHE_DIR_ABS}/bootstrap"
    : > "${CACHE_DIR_ABS}/bootstrap/base-state"
    : > "${WORK_DIR_ABS}/old-state"
    prepare_build_workspace
    [[ -f "${CACHE_DIR_ABS}/cached.deb" ]]
    [[ -f "${CACHE_DIR_ABS}/bootstrap/base-state" ]]
    [[ -L "${WORK_DIR_ABS}/cache" ]]
    [[ "$(realpath -- "${WORK_DIR_ABS}/cache")" == "$CACHE_DIR_ABS" ]]
    [[ ! -e "${WORK_DIR_ABS}/old-state" ]]
}

test_clean_preserves_cache() {
    setup_test_sandbox
    mkdir -p -- "${CACHE_DIR_ABS}/packages.chroot" "${CACHE_DIR_ABS}/bootstrap"
    : > "${CACHE_DIR_ABS}/packages.chroot/cached.deb"
    : > "${CACHE_DIR_ABS}/bootstrap/base-state"
    : > "${WORK_DIR_ABS}/old-state"
    clean_state_preserving_cache
    [[ -f "${CACHE_DIR_ABS}/packages.chroot/cached.deb" ]]
    [[ ! -e "${CACHE_DIR_ABS}/bootstrap" ]]
    [[ -z "$(find "$WORK_DIR_ABS" -mindepth 1 -print -quit)" ]]
}

test_purge_removes_cache() {
    setup_test_sandbox
    mkdir -p -- "${CACHE_DIR_ABS}/packages.chroot"
    : > "${CACHE_DIR_ABS}/packages.chroot/cached.deb"
    : > "${WORK_DIR_ABS}/old-state"
    purge_builder_state
    [[ -d "$CACHE_DIR_ABS" ]]
    [[ -z "$(find "$CACHE_DIR_ABS" -mindepth 1 -print -quit)" ]]
    [[ -z "$(find "$WORK_DIR_ABS" -mindepth 1 -print -quit)" ]]
}

test_legacy_cache_migration() {
    setup_test_sandbox
    mkdir -p -- "${WORK_DIR_ABS}/cache/packages.chroot"
    : > "${WORK_DIR_ABS}/cache/packages.chroot/cached.deb"
    prepare_persistent_cache
    [[ -f "${CACHE_DIR_ABS}/packages.chroot/cached.deb" ]]
    [[ ! -e "${WORK_DIR_ABS}/cache" ]]
}

test_symlink_protection() {
    local purge_status=0
    setup_test_sandbox
    : > "${TEST_EXTERNAL_ROOT}/must-survive"
    ln -s -- "$TEST_EXTERNAL_ROOT" "$CACHE_DIR_ABS"
    ! assert_safe_cache_dir "$CACHE_DIR_ABS"
    purge_persistent_cache || purge_status=$?
    [[ "$purge_status" -ne 0 ]]
    [[ -f "${TEST_EXTERNAL_ROOT}/must-survive" ]]
    ln -s -- "$TEST_EXTERNAL_ROOT" "${WORK_DIR_ABS}/unsafe-link"
    ! assert_safe_work_dir "${WORK_DIR_ABS}/unsafe-link"
}

test_argument_parsing() {
    parse_arguments
    [[ "$CLI_MODE" == build ]]
    parse_arguments --clean
    [[ "$CLI_MODE" == clean ]]
    parse_arguments --purge
    [[ "$CLI_MODE" == purge ]]
    parse_arguments --smoke-test image.iso
    [[ "$CLI_MODE" == smoke && "$CLI_SMOKE_PATH" == image.iso ]]
    ! parse_arguments --purge extra
    ! parse_arguments --unknown
}

test_package_lists() {
    local package all_lists duplicates
    local -a required=(
        bash python3 coreutils findutils grep sed gawk util-linux mount procps sudo
        tar gzip zstd rsync btrfs-progs dosfstools parted e2fsprogs
        smartmontools iproute2 iputils-ping nfs-common openssh-client curl wget pciutils
        usbutils lshw ethtool dnsutils grub-pc-bin grub-efi-amd64-bin
        grub-common grub2-common efibootmgr live-config live-tools user-setup
        keyboard-configuration xserver-xorg lightdm libpam-systemd
        mate-desktop-environment-core mate-terminal caja network-manager
        pluma code filezilla gparted gnome-disk-utility nvme-cli testdisk gddrescue jq
        firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211
        firmware-mediatek firmware-intel-misc firmware-bnx2
        firmware-amd-graphics firmware-intel-graphics firmware-linux-free
        amd64-microcode intel-microcode
    )
    all_lists=$(find "${PROJECT_ROOT}/config-live/package-lists" -maxdepth 1 -type f -name '*.list.chroot' -print | sort)
    [[ -n "$all_lists" ]]
    for package in "${required[@]}"; do
        grep -Ehq "^[[:space:]]*${package}[[:space:]]*$" $all_lists || {
            printf 'Pacote obrigatorio ausente: %s\n' "$package"
            return 1
        }
    done
    duplicates=$(awk '
        /^[[:space:]]*(#|$)/ { next }
        { count[$1]++ }
        END { for (package in count) if (count[package] > 1) print package }
    ' $all_lists)
    [[ -z "$duplicates" ]] || {
        printf 'Pacotes duplicados: %s\n' "$duplicates"
        return 1
    }
}

test_microsoft_vscode_repository() {
    local archive_dir
    archive_dir="${PROJECT_ROOT}/config-live/archives"

    check_microsoft_vscode_repository_config
    grep -Fxq \
        'deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/microsoft-vscode.key.asc] https://packages.microsoft.com/repos/code stable main' \
        "${archive_dir}/microsoft-vscode.list"
    [[ "$(sha256sum "${archive_dir}/microsoft-vscode.key" | awk '{print $1}')" == \
        2fa9c05d591a1582a9aba276272478c262e95ad00acf60eaee1644d93941e3c6 ]]
    grep -q 'usr/bin/code' "${PROJECT_ROOT}/lib/build.sh"
}

test_repository_access_includes_vscode() (
    local checked_urls=''
    DEBIAN_MIRROR='https://deb.example/debian'
    DEBIAN_SECURITY_MIRROR='https://security.example/debian-security'
    DEBIAN_SUITE='trixie'
    repository_url_is_reachable() {
        checked_urls+="$1"$'\n'
    }

    check_repository_access
    grep -Fxq 'https://deb.example/debian/dists/trixie/Release' <<< "$checked_urls"
    grep -Fxq 'https://security.example/debian-security/dists/trixie-security/Release' <<< "$checked_urls"
    grep -Fxq 'https://packages.microsoft.com/repos/code/dists/stable/InRelease' <<< "$checked_urls"
)

test_project_structure() {
    check_project_structure
    [[ -f "${PROJECT_ROOT}/config-live/includes.chroot/opt/pmjs/README.md" ]]
    [[ -x "${PROJECT_ROOT}/config-live/hooks/live/010-pmjs-baseline.hook.chroot" ]]
}

assert_snapshot_file_set() {
    local snapshot=$1 files_name=$2
    local -n expected_files=$files_name
    diff -u \
        <(printf '%s\n' "${expected_files[@]}" | sort) \
        <(cd "$snapshot" && find . -type f ! -name SNAPSHOT -printf '%P\n' | sort)
}

test_controlled_snapshots() {
    local deploy="${PROJECT_ROOT}/config-live/includes.chroot/opt/pmjs/deploy"
    local image_builder="${PROJECT_ROOT}/config-live/includes.chroot/opt/pmjs/image-builder"
    local forbidden

    assert_snapshot_file_set "$deploy" DEPLOY_RUNTIME_FILES
    assert_snapshot_file_set "$image_builder" IMAGE_BUILDER_RUNTIME_FILES
    grep -Eq '^version=2\.0\.0-dev$' "$deploy/SNAPSHOT"
    grep -Eq '^version=0\.2\.0$' "$image_builder/SNAPSHOT"
    grep -Eq '^source_commit=[0-9a-f]{40}$' "$deploy/SNAPSHOT"
    grep -Eq '^source_commit=[0-9a-f]{40}$' "$image_builder/SNAPSHOT"
    forbidden=$(find "$deploy" "$image_builder" \
        \( -name .git -o -name logs -o -name cache -o -name output -o \
           -name work -o -name tests -o -name '*.partial' -o \
           -name 'rootfs.tar.*' -o -name 'homefs.tar.*' -o \
           -name 'pmjs-linux-*' -o -size +20M \) -print -quit)
    [[ -z "$forbidden" ]]
}

test_wrappers_and_launchers() {
    local include="${PROJECT_ROOT}/config-live/includes.chroot"
    local wrapper desktop
    for wrapper in pmjs-deploy pmjs-image-builder; do
        [[ -x "$include/usr/local/bin/$wrapper" ]]
        sh -n "$include/usr/local/bin/$wrapper"
        grep -Fq 'exec sudo -- "$entrypoint" "$@"' "$include/usr/local/bin/$wrapper"
        ! grep -Eq 'NOPASSWD|pkexec|sudoers' "$include/usr/local/bin/$wrapper"
    done
    for desktop in pmjs-deploy pmjs-image-builder; do
        [[ -x "$include/usr/share/applications/$desktop.desktop" ]]
        desktop-file-validate "$include/usr/share/applications/$desktop.desktop"
        grep -Eq "^Exec=${desktop}$" "$include/usr/share/applications/$desktop.desktop"
        grep -Eq "^TryExec=${desktop}$" "$include/usr/share/applications/$desktop.desktop"
        grep -Eq "^Icon=${desktop}$" "$include/usr/share/applications/$desktop.desktop"
        grep -Eq '^Terminal=true$' "$include/usr/share/applications/$desktop.desktop"
    done
    [[ "$(readlink -- "$include/etc/skel/Desktop/PMJS Deploy.desktop")" == \
       /usr/share/applications/pmjs-deploy.desktop ]]
    [[ "$(readlink -- "$include/etc/skel/Desktop/PMJS Image Builder.desktop")" == \
       /usr/share/applications/pmjs-image-builder.desktop ]]
}

test_branding_and_renoir_recipe() {
    local include="${PROJECT_ROOT}/config-live/includes.chroot"
    [[ "$(file -b --mime-type "$include/usr/share/pixmaps/pmjs-deploy.png")" == image/png ]]
    [[ "$(file -b --mime-type "$include/usr/share/pixmaps/pmjs-image-builder.png")" == image/png ]]
    [[ "$(file -b --mime-type "$include/usr/share/backgrounds/pmjs/pmjs-wallpaper.jpg")" == image/jpeg ]]
    grep -Fq "picture-filename='/usr/share/backgrounds/pmjs/pmjs-wallpaper.jpg'" \
        "$include/usr/share/glib-2.0/schemas/90_pmjs-live.gschema.override"
    grep -Fq 'firmware-amd-graphics' \
        "${PROJECT_ROOT}/config-live/package-lists/35-firmware-graphics.list.chroot"
    for firmware in renoir_asd.bin renoir_dmcub.bin renoir_pfp.bin renoir_sdma.bin renoir_vcn.bin; do
        grep -Fq "usr/lib/firmware/amdgpu/$firmware" "${PROJECT_ROOT}/lib/build.sh"
    done
}

test_shell_syntax() {
    local file
    while IFS= read -r file; do
        bash -n "$file" || return 1
    done < <(find "$PROJECT_ROOT" \( -path "$PROJECT_ROOT/work" -o -path "$PROJECT_ROOT/cache" \) -prune -o -type f -name '*.sh' -print)
    sh -n "${PROJECT_ROOT}/config-live/hooks/live/010-pmjs-baseline.hook.chroot"
    sh -n "${PROJECT_ROOT}/config-live/includes.chroot/usr/local/bin/pmjs-deploy"
    sh -n "${PROJECT_ROOT}/config-live/includes.chroot/usr/local/bin/pmjs-image-builder"
}

test_preflight_components() {
    load_live_config "${PROJECT_ROOT}/config/live.conf"
    validate_config
    check_project_structure
    check_free_space
    [[ -n "$(detect_host)" ]]
}

test_live_build_options() {
    grep -q -- '--binary-image iso-hybrid' "${PROJECT_ROOT}/lib/build.sh"
    grep -q -- '--bootloaders "grub-pc grub-efi"' "${PROJECT_ROOT}/lib/build.sh"
    grep -q -- '--chroot-squashfs-compression-type zstd' "${PROJECT_ROOT}/lib/build.sh"
    grep -q -- '--cache "$CACHE_ENABLED"' "${PROJECT_ROOT}/lib/build.sh"
    grep -q -- '--cache-packages "$CACHE_PACKAGES"' "${PROJECT_ROOT}/lib/build.sh"
    grep -q -- '--cache-indices "$CACHE_INDICES"' "${PROJECT_ROOT}/lib/build.sh"
    grep -q -- '--cache-stages "$CACHE_STAGES"' "${PROJECT_ROOT}/lib/build.sh"
    ! grep -q -- '--compression zstd' "${PROJECT_ROOT}/lib/build.sh"
}

test_python_recipe_and_validation() {
    grep -Ehq '^[[:space:]]*python3[[:space:]]*$' "${PROJECT_ROOT}"/config-live/package-lists/*.list.chroot
    grep -q 'usr/bin/python3' "${PROJECT_ROOT}/lib/build.sh"
    command -v unsquashfs >/dev/null 2>&1
}

trap 'cleanup_test_sandbox >/dev/null 2>&1 || true; rm -f -- /tmp/pmjs-live-test-output.$$' EXIT

printf 'TAP version 13\n'
run_test 'parsing e validacao da configuracao' test_config_parsing
run_test 'geracao do nome da ISO' test_output_name
run_test 'validacao da suite Debian' test_suite_validation
run_test 'validacao da arquitetura' test_architecture_validation
run_test 'deteccao de dependencia ausente' test_missing_dependency_detection
run_test 'protecao dos caminhos de clean' test_clean_path_guards
run_test 'build normal preserva e conecta o cache' test_normal_build_preserves_cache
run_test '--clean preserva o cache' test_clean_preserves_cache
run_test '--purge remove o cache' test_purge_removes_cache
run_test 'migracao segura do cache legado' test_legacy_cache_migration
run_test 'protecao contra symlinks' test_symlink_protection
run_test 'parsing das novas opcoes CLI' test_argument_parsing
run_test 'estrutura e conteudo das package lists' test_package_lists
run_test 'repositorio oficial e pacote do Visual Studio Code' test_microsoft_vscode_repository
run_test 'preflight verifica acesso ao repositorio do VS Code' test_repository_access_includes_vscode
run_test 'estrutura de includes e hooks' test_project_structure
run_test 'snapshots runtime controlados e sem artefatos' test_controlled_snapshots
run_test 'wrappers e launchers graficos' test_wrappers_and_launchers
run_test 'branding e receita de firmware Renoir' test_branding_and_renoir_recipe
run_test 'sintaxe dos scripts e hook' test_shell_syntax
run_test 'componentes nao destrutivos do preflight' test_preflight_components
run_test 'opcoes criticas do live-build' test_live_build_options
run_test 'python3 na receita e na validacao pos-build' test_python_recipe_and_validation

printf '1..%d\n' "$tests_run"
if (( tests_failed > 0 )); then
    printf '# %d teste(s) falharam\n' "$tests_failed"
    exit 1
fi
printf '# todos os %d testes passaram\n' "$tests_run"
