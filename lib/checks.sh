#!/usr/bin/env bash

CONFIG_FILE=''
OUTPUT_DIR_ABS=''
WORK_DIR_ABS=''
LOG_DIR_ABS=''
CACHE_DIR_ABS=''

MICROSOFT_VSCODE_REPOSITORY='https://packages.microsoft.com/repos/code'
MICROSOFT_VSCODE_KEY_SHA256='2fa9c05d591a1582a9aba276272478c262e95ad00acf60eaee1644d93941e3c6'

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
    CACHE_DIR_ABS=$(resolve_project_path "$CACHE_DIR")
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
              CACHE_DIR CACHE_ENABLED CACHE_PACKAGES CACHE_INDICES MIN_FREE_GIB)

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
    [[ "${CACHE_STAGES+x}" == x ]] || die "Parametro obrigatorio ausente: CACHE_STAGES"
    [[ "$CACHE_ENABLED" == true ]] || die "CACHE_ENABLED deve permanecer true nesta Sprint."
    [[ "$CACHE_PACKAGES" == true ]] || die "CACHE_PACKAGES deve permanecer true nesta Sprint."
    [[ "$CACHE_INDICES" == false ]] || die "CACHE_INDICES deve permanecer false para atualizar e validar metadados APT."
    [[ "$CACHE_STAGES" == bootstrap ]] || die "CACHE_STAGES deve ser bootstrap nesta Sprint."

    validate_project_child OUTPUT_DIR "$OUTPUT_DIR_ABS"
    validate_project_child WORK_DIR "$WORK_DIR_ABS"
    validate_project_child LOG_DIR "$LOG_DIR_ABS"
    validate_project_child CACHE_DIR "$CACHE_DIR_ABS"
    [[ "$CACHE_DIR_ABS" == "${PROJECT_ROOT}/cache" ]] || die "CACHE_DIR deve resolver exatamente para ${PROJECT_ROOT}/cache."
    [[ "$CACHE_DIR_ABS" != "$WORK_DIR_ABS" ]] || die "CACHE_DIR e WORK_DIR devem ser separados."

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
    if ! missing_output=$(missing_commands lb debootstrap xorriso mksquashfs unsquashfs \
        sha256sum realpath findmnt desktop-file-validate file); then
        die "Dependencias ausentes no HOST: ${missing_output//$'\n'/, }. Instale: live-build debootstrap xorriso squashfs-tools desktop-file-utils file."
    fi
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        die "Preflight de rede requer curl ou wget no HOST."
    fi
}

check_package_list_duplicates() {
    local duplicates
    duplicates="$(awk '
        /^[[:space:]]*(#|$)/ { next }
        { count[$1]++ }
        END { for (package in count) if (count[package] > 1) print package }
    ' "${PROJECT_ROOT}"/config-live/package-lists/*.list.chroot | sort)"
    [[ -z "${duplicates}" ]] || {
        die "Pacotes duplicados nas listas: ${duplicates//$'\n'/, }"
        return 1
    }
}

check_microsoft_vscode_repository_config() {
    local archive_dir source_file preference_file key_file expected_source actual_key_sha
    archive_dir="${PROJECT_ROOT}/config-live/archives"
    source_file="${archive_dir}/microsoft-vscode.list"
    preference_file="${archive_dir}/microsoft-vscode.pref"
    key_file="${archive_dir}/microsoft-vscode.key"
    expected_source="deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/microsoft-vscode.key.asc] ${MICROSOFT_VSCODE_REPOSITORY} stable main"

    [[ -f "$source_file" && "$(<"$source_file")" == "$expected_source" ]] || {
        die "Repositorio oficial do Visual Studio Code ausente ou alterado: $source_file"
        return 1
    }
    [[ -f "$preference_file" ]] &&
        grep -Fxq 'Package: code' "$preference_file" &&
        grep -Fxq 'Pin: origin "packages.microsoft.com"' "$preference_file" &&
        grep -Fxq 'Pin-Priority: 9999' "$preference_file" || {
            die "Pinning do pacote code ausente ou invalido: $preference_file"
            return 1
        }
    [[ -f "$key_file" ]] || {
        die "Chave do repositorio do Visual Studio Code ausente: $key_file"
        return 1
    }
    actual_key_sha=$(sha256sum -- "$key_file" | awk '{print $1}')
    [[ "$actual_key_sha" == "$MICROSOFT_VSCODE_KEY_SHA256" ]] || {
        die "Chave do repositorio do Visual Studio Code nao corresponde ao arquivo auditado."
        return 1
    }
    grep -Ehq '^[[:space:]]*code[[:space:]]*$' \
        "${PROJECT_ROOT}"/config-live/package-lists/*.list.chroot || {
            die "Pacote code ausente das package lists."
            return 1
        }
    ! grep -Ehq '^[[:space:]]*vscode[[:space:]]*$' \
        "${PROJECT_ROOT}"/config-live/package-lists/*.list.chroot || {
            die "Nome de pacote invalido vscode ainda presente nas package lists."
            return 1
        }
}

check_embedded_pmjs_runtime() {
    local include_root="${PROJECT_ROOT}/config-live/includes.chroot"
    local path forbidden
    local -a required_paths=(
        opt/pmjs/deploy/VERSION
        opt/pmjs/deploy/SNAPSHOT
        opt/pmjs/deploy/deploy.sh
        opt/pmjs/deploy/config/deploy.conf
        opt/pmjs/deploy/assets/auto-mirror-x11
        opt/pmjs/deploy/lib/image_contract.sh
        opt/pmjs/deploy/lib/install.sh
        opt/pmjs/image-builder/VERSION
        opt/pmjs/image-builder/SNAPSHOT
        opt/pmjs/image-builder/build-image.sh
        opt/pmjs/image-builder/publish-image.sh
        opt/pmjs/image-builder/sync-image-to-ventoy.sh
        opt/pmjs/image-builder/config/image.conf
        opt/pmjs/image-builder/lib/archive.sh
        opt/pmjs/image-builder/lib/metadata.sh
        usr/local/bin/pmjs-deploy
        usr/local/bin/pmjs-image-builder
        usr/share/applications/pmjs-deploy.desktop
        usr/share/applications/pmjs-image-builder.desktop
        usr/share/pixmaps/pmjs-deploy.png
        usr/share/pixmaps/pmjs-image-builder.png
        usr/share/backgrounds/pmjs/pmjs-wallpaper.jpg
        usr/share/glib-2.0/schemas/90_pmjs-live.gschema.override
    )

    for path in "${required_paths[@]}"; do
        [[ -f "${include_root}/${path}" && -s "${include_root}/${path}" ]] || {
            die "Arquivo integrado ausente ou vazio: ${path}"
            return 1
        }
    done
    for path in \
        opt/pmjs/deploy/deploy.sh \
        opt/pmjs/deploy/assets/auto-mirror-x11 \
        opt/pmjs/image-builder/build-image.sh \
        opt/pmjs/image-builder/publish-image.sh \
        opt/pmjs/image-builder/sync-image-to-ventoy.sh \
        usr/local/bin/pmjs-deploy \
        usr/local/bin/pmjs-image-builder; do
        [[ -x "${include_root}/${path}" ]] || {
            die "Executavel integrado sem permissao de execucao: ${path}"
            return 1
        }
    done

    [[ "$(readlink -- "${include_root}/etc/skel/Desktop/PMJS Deploy.desktop")" == \
       /usr/share/applications/pmjs-deploy.desktop ]] || {
        die "Atalho do Desktop para PMJS Deploy ausente ou incorreto."
        return 1
    }
    [[ "$(readlink -- "${include_root}/etc/skel/Desktop/PMJS Image Builder.desktop")" == \
       /usr/share/applications/pmjs-image-builder.desktop ]] || {
        die "Atalho do Desktop para PMJS Image Builder ausente ou incorreto."
        return 1
    }
    desktop-file-validate \
        "${include_root}/usr/share/applications/pmjs-deploy.desktop" \
        "${include_root}/usr/share/applications/pmjs-image-builder.desktop" || {
        die "Launcher .desktop invalido."
        return 1
    }
    [[ "$(file --brief --mime-type -- "${include_root}/usr/share/pixmaps/pmjs-deploy.png")" == image/png &&
       "$(file --brief --mime-type -- "${include_root}/usr/share/pixmaps/pmjs-image-builder.png")" == image/png &&
       "$(file --brief --mime-type -- "${include_root}/usr/share/backgrounds/pmjs/pmjs-wallpaper.jpg")" == image/jpeg ]] || {
        die "Formato invalido em um dos assets PMJS integrados."
        return 1
    }

    forbidden="$(find "${include_root}/opt/pmjs/deploy" \
        "${include_root}/opt/pmjs/image-builder" \
        \( -name .git -o -name logs -o -name cache -o -name output -o \
           -name work -o -name tests -o -name '*.partial' -o \
           -name 'rootfs.tar.*' -o -name 'homefs.tar.*' -o \
           -name 'pmjs-linux-*' -o -size +20M \) -print -quit)"
    [[ -z "${forbidden}" ]] || {
        die "Artefato de desenvolvimento ou arquivo grande no snapshot: ${forbidden}"
        return 1
    }
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
    local main_release security_release vscode_release
    main_release="${DEBIAN_MIRROR%/}/dists/${DEBIAN_SUITE}/Release"
    security_release="${DEBIAN_SECURITY_MIRROR%/}/dists/${DEBIAN_SUITE}-security/Release"
    vscode_release="${MICROSOFT_VSCODE_REPOSITORY}/dists/stable/InRelease"

    repository_url_is_reachable "$main_release" || die "Repositorio Debian inacessivel: $main_release. Verifique Internet, DNS, proxy e a suite."
    repository_url_is_reachable "$security_release" || die "Repositorio de seguranca inacessivel: $security_release. Verifique Internet, DNS, proxy e a suite."
    repository_url_is_reachable "$vscode_release" || die "Repositorio oficial do Visual Studio Code inacessivel: $vscode_release. Verifique Internet, DNS e proxy."
}

check_project_structure() {
    [[ -d "${PROJECT_ROOT}/config-live/package-lists" ]] || die "Diretorio de package lists ausente."
    [[ -d "${PROJECT_ROOT}/config-live/includes.chroot" ]] || die "Diretorio de includes ausente."
    [[ -d "${PROJECT_ROOT}/config-live/hooks" ]] || die "Diretorio de hooks ausente."
    find "${PROJECT_ROOT}/config-live/package-lists" -maxdepth 1 -type f -name '*.list.chroot' | grep -q . || die "Nenhuma package list .list.chroot encontrada."
    check_microsoft_vscode_repository_config
    check_package_list_duplicates
    check_embedded_pmjs_runtime
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
    log_info "Cache: habilitado=$CACHE_ENABLED; pacotes=$CACHE_PACKAGES; indices=$CACHE_INDICES; local=$CACHE_DIR_ABS"
    if [[ "$host" != *"(${DEBIAN_SUITE})"* ]]; then
        ui_warn "HOST ($host) e alvo ($DEBIAN_SUITE) diferem. Prefira um HOST Debian $DEBIAN_SUITE para reduzir incompatibilidades de ferramentas."
        log_warn "HOST e suite alvo diferem."
    fi

    ui_step "Verificando acesso aos repositorios de build"
    check_repository_access
    ui_ok "Preflight concluido"
}
