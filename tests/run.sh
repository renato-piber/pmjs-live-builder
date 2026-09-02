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

tests_run=0
tests_failed=0

run_test() {
    local name=$1
    shift
    tests_run=$((tests_run + 1))
    if "$@" >/tmp/pmjs-live-test-output.$$ 2>&1; then
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
    [[ "$LIVE_VERSION" == 0.1.0 ]]
    [[ "$DEBIAN_SUITE" == trixie ]]
}

test_output_name() {
    load_live_config "${PROJECT_ROOT}/config/live.conf"
    [[ "$(iso_filename)" == pmjs-live-0.1.0-amd64.iso ]]
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
}

test_safe_clean() {
    local test_dir="${PROJECT_ROOT}/work/pmjs-test-$$"
    WORK_DIR_ABS=$test_dir
    mkdir -p -- "$test_dir/nested"
    : > "$test_dir/nested/artifact"
    clean_workdir
    [[ -d "$test_dir" ]]
    [[ -z "$(find "$test_dir" -mindepth 1 -print -quit)" ]]
    rmdir -- "$test_dir"
}

test_package_lists() {
    local package all_lists
    local -a required=(
        bash coreutils findutils grep sed gawk util-linux procps sudo
        tar gzip zstd rsync btrfs-progs dosfstools parted e2fsprogs
        smartmontools iproute2 iputils-ping nfs-common curl wget pciutils
        usbutils lshw ethtool dnsutils grub-pc-bin grub-efi-amd64-bin
        grub-common efibootmgr live-config live-tools user-setup
        keyboard-configuration xserver-xorg lightdm libpam-systemd
        mate-desktop-environment-core mate-terminal caja network-manager
    )
    all_lists=$(find "${PROJECT_ROOT}/config-live/package-lists" -maxdepth 1 -type f -name '*.list.chroot' -print | sort)
    [[ -n "$all_lists" ]]
    for package in "${required[@]}"; do
        grep -Ehq "^[[:space:]]*${package}[[:space:]]*$" $all_lists || {
            printf 'Pacote obrigatorio ausente: %s\n' "$package"
            return 1
        }
    done
}

test_project_structure() {
    check_project_structure
    [[ -f "${PROJECT_ROOT}/config-live/includes.chroot/opt/pmjs/README.md" ]]
    [[ -x "${PROJECT_ROOT}/config-live/hooks/live/010-pmjs-baseline.hook.chroot" ]]
}

test_shell_syntax() {
    local file
    while IFS= read -r file; do
        bash -n "$file" || return 1
    done < <(find "$PROJECT_ROOT" -path "$PROJECT_ROOT/work" -prune -o -type f -name '*.sh' -print)
    sh -n "${PROJECT_ROOT}/config-live/hooks/live/010-pmjs-baseline.hook.chroot"
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
    ! grep -q -- '--compression zstd' "${PROJECT_ROOT}/lib/build.sh"
}

trap 'rm -f -- /tmp/pmjs-live-test-output.$$' EXIT

printf 'TAP version 13\n'
run_test 'parsing e validacao da configuracao' test_config_parsing
run_test 'geracao do nome da ISO' test_output_name
run_test 'validacao da suite Debian' test_suite_validation
run_test 'validacao da arquitetura' test_architecture_validation
run_test 'deteccao de dependencia ausente' test_missing_dependency_detection
run_test 'protecao dos caminhos de clean' test_clean_path_guards
run_test 'clean seguro em area temporaria controlada' test_safe_clean
run_test 'estrutura e conteudo das package lists' test_package_lists
run_test 'estrutura de includes e hooks' test_project_structure
run_test 'sintaxe dos scripts e hook' test_shell_syntax
run_test 'componentes nao destrutivos do preflight' test_preflight_components
run_test 'opcoes criticas do live-build' test_live_build_options

printf '1..%d\n' "$tests_run"
if (( tests_failed > 0 )); then
    printf '# %d teste(s) falharam\n' "$tests_failed"
    exit 1
fi
printf '# todos os %d testes passaram\n' "$tests_run"
