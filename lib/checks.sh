#!/usr/bin/env bash

CONFIG_FILE=''
OUTPUT_DIR_ABS=''
WORK_DIR_ABS=''
LOG_DIR_ABS=''

die() {
    ui_error "$*"
    log_error "$*"
    return 1
}

resolve_project_path() {
    local value=$1
    if [[ "$value" = /* ]]; then
        realpath -m -- "$value"
    else
        realpath -m -- "${PROJECT_ROOT}/${value}"
    fi
}

load_live_config() {
    local config_file=${1:-"${PROJECT_ROOT}/config/live.conf"}
    CONFIG_FILE=$config_file

    [[ -r "$config_file" ]] || die "Configuracao ausente ou ilegivel: $config_file"
    # O arquivo faz parte do proprio projeto versionado e contem apenas atribuicoes.
    # shellcheck disable=SC1090
    source "$config_file"

    OUTPUT_DIR_ABS=$(resolve_project_path "$OUTPUT_DIR")
    WORK_DIR_ABS=$(resolve_project_path "$WORK_DIR")
    LOG_DIR_ABS=$(resolve_project_path "$LOG_DIR")
}

validate_project_child() {
    local label=$1
    local path=$2
    case "$path" in
        "${PROJECT_ROOT}"/*) ;;
        *) die "$label deve permanecer dentro do projeto: $path" ;;
    esac
    [[ "$path" != "$PROJECT_ROOT" ]] || die "$label nao pode ser a raiz do projeto."
}

validate_suite() {
    local suite=$1
    [[ "$suite" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    case "$suite" in
        stable|testing|unstable|oldstable|oldoldstable) return 1 ;;
    esac
}

validate_architecture() {
    [[ "$1" == amd64 ]]
}

validate_config() {
    local required variable version_file
    required=(LIVE_NAME LIVE_VERSION LIVE_ARCH LIVE_USER LIVE_HOSTNAME
              LIVE_LOCALE LIVE_KEYBOARD_LAYOUT DEBIAN_SUITE DEBIAN_MIRROR
              DEBIAN_SECURITY_MIRROR ARCHIVE_AREAS OUTPUT_DIR WORK_DIR LOG_DIR
              MIN_FREE_GIB)

    for variable in "${required[@]}"; do
        [[ -n "${!variable:-}" ]] || die "Parametro obrigatorio vazio: $variable"
    done

    [[ "$LIVE_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "LIVE_NAME invalido: $LIVE_NAME"
    [[ "$LIVE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || die "LIVE_VERSION invalida: $LIVE_VERSION"
    [[ "$LIVE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "LIVE_USER invalido: $LIVE_USER"
    [[ "$LIVE_HOSTNAME" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || die "LIVE_HOSTNAME invalido: $LIVE_HOSTNAME"
    validate_suite "$DEBIAN_SUITE" || die "DEBIAN_SUITE deve ser um codinome Debian valido, nao um alias movel: $DEBIAN_SUITE"
    validate_architecture "$LIVE_ARCH" || die "Arquitetura nao suportada nesta sprint: $LIVE_ARCH (esperado: amd64)"
    [[ "$MIN_FREE_GIB" =~ ^[0-9]+$ ]] && (( MIN_FREE_GIB > 0 )) || die "MIN_FREE_GIB deve ser inteiro positivo."
    [[ "$DEBIAN_MIRROR" == https://* ]] || die "DEBIAN_MIRROR deve usar HTTPS."
    [[ "$DEBIAN_SECURITY_MIRROR" == https://* ]] || die "DEBIAN_SECURITY_MIRROR deve usar HTTPS."

    validate_project_child OUTPUT_DIR "$OUTPUT_DIR_ABS"
    validate_project_child WORK_DIR "$WORK_DIR_ABS"
    validate_project_child LOG_DIR "$LOG_DIR_ABS"

    version_file=$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION")
    [[ "$version_file" == "$LIVE_VERSION" ]] || die "VERSION ($version_file) difere de LIVE_VERSION ($LIVE_VERSION)."
}

detect_host() {
    local host_id='desconhecido' host_version='desconhecida' host_codename='desconhecido'
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        host_id=${ID:-$host_id}
        host_version=${VERSION_ID:-$host_version}
        host_codename=${VERSION_CODENAME:-$host_codename}
    fi
    printf '%s %s (%s)\n' "$host_id" "$host_version" "$host_codename"
}

missing_commands() {
    local command_name missing=0
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf '%s\n' "$command_name"
            missing=1
        fi
    done
    return "$missing"
}

check_required_commands() {
    local missing_output
    if ! missing_output=$(missing_commands lb debootstrap xorriso mksquashfs sha256sum realpath findmnt); then
        die "Dependencias ausentes no HOST: ${missing_output//$'\n'/, }. Instale: live-build debootstrap xorriso squashfs-tools."
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "Preflight de rede requer curl ou wget no HOST."
    fi
}

check_root() {
    (( EUID == 0 )) || die "Esta operacao requer root. Execute: sudo ./build-live.sh"
}

check_free_space() {
    local available_kib required_kib
    available_kib=$(df -Pk "$PROJECT_ROOT" | awk 'NR == 2 {print $4}')
    required_kib=$((MIN_FREE_GIB * 1024 * 1024))
    (( available_kib >= required_kib )) || die "Espaco insuficiente: sao exigidos pelo menos ${MIN_FREE_GIB} GiB livres."
    log_info "Espaco livre: $((available_kib / 1024 / 1024)) GiB (minimo: ${MIN_FREE_GIB} GiB)"
}

repository_url_is_reachable() {
    local url=$1
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --max-time 20 --output /dev/null "$url"
    else
        wget --quiet --timeout=20 --output-document=/dev/null "$url"
    fi
}

check_repository_access() {
    local main_release security_release
    main_release="${DEBIAN_MIRROR%/}/dists/${DEBIAN_SUITE}/Release"
    security_release="${DEBIAN_SECURITY_MIRROR%/}/dists/${DEBIAN_SUITE}-security/Release"

    repository_url_is_reachable "$main_release" || die "Repositorio Debian inacessivel: $main_release. Verifique Internet, DNS, proxy e a suite."
    repository_url_is_reachable "$security_release" || die "Repositorio de seguranca inacessivel: $security_release. Verifique Internet, DNS, proxy e a suite."
}

check_project_structure() {
    [[ -d "${PROJECT_ROOT}/config-live/package-lists" ]] || die "Diretorio de package lists ausente."
    [[ -d "${PROJECT_ROOT}/config-live/includes.chroot" ]] || die "Diretorio de includes ausente."
    [[ -d "${PROJECT_ROOT}/config-live/hooks" ]] || die "Diretorio de hooks ausente."
    find "${PROJECT_ROOT}/config-live/package-lists" -maxdepth 1 -type f -name '*.list.chroot' | grep -q . || die "Nenhuma package list .list.chroot encontrada."
}

run_preflight() {
    local host lb_version
    ui_step "Preflight"
    check_root
    validate_config
    check_project_structure
    check_required_commands
    check_free_space

    host=$(detect_host)
    lb_version=$(lb --version 2>&1 | head -n 1)
    log_info "HOST: $host"
    log_info "live-build: $lb_version"
    log_info "Configuracao: $CONFIG_FILE"
    log_info "Suite: $DEBIAN_SUITE; arquitetura: $LIVE_ARCH"
    if [[ "$host" != *"(${DEBIAN_SUITE})"* ]]; then
        ui_warn "HOST ($host) e alvo ($DEBIAN_SUITE) diferem. Prefira um HOST Debian $DEBIAN_SUITE para reduzir incompatibilidades de ferramentas."
        log_warn "HOST e suite alvo diferem."
    fi

    ui_step "Verificando acesso aos repositorios de build"
    check_repository_access
    ui_ok "Preflight concluido"
}
