#!/usr/bin/env bash

NFS_MOUNTED_BY_BUILDER=0
NFS_ACTIVE_MOUNTPOINT=""
NFS_ACTIVE_SOURCE=""
NFS_ACTIVE_ID=""
NFS_MOUNT_IN_PROGRESS=0
NFS_PENDING_SIGNAL=""

check_nfs_dependencies() {
    local dependency
    for dependency in mount umount findmnt mount.nfs; do
        command -v "${dependency}" >/dev/null 2>&1 || {
            ui_error "Suporte NFS indisponível: falta ${dependency}. Instale o cliente NFS (nfs-common no Debian) e util-linux."
            return 1
        }
    done
}

validate_nfs_mount_config() {
    local path=${NFS_MOUNTPOINT:-} canonical
    [[ "${path}" == /*/* && "${path}" != *[[:space:][:cntrl:]]* ]] || {
        ui_error "NFS_MOUNTPOINT vazio, amplo ou inseguro: ${path}"
        return 1
    }
    canonical="$(realpath -m -- "${path}")" || return 1
    [[ "${canonical}" == "${path}" ]] || {
        ui_error "NFS_MOUNTPOINT deve ser canônico, sem symlinks, . ou ..: ${path}"
        return 1
    }
    case "${path}" in
        /|/mnt|/var|/tmp|/var/tmp|/var/lib|/var/cache|/var/log|/usr/local|/run/user|\
        /etc/*|/proc/*|/sys/*|/dev/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/boot/*|/root/*|/home/*)
            ui_error "NFS_MOUNTPOINT amplo ou inseguro: ${path}"
            return 1 ;;
    esac
    [[ "${NFS_SERVER:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ &&
       "${NFS_EXPORT:-}" == /* && "${NFS_EXPORT}" != / &&
       "${NFS_EXPORT}" != *[[:space:][:cntrl:]]* &&
       "${NFS_EXPORT}" != *:* && "${NFS_EXPORT}" != *'['* &&
       "${NFS_EXPORT}" != *']'* ]] || {
        ui_error "NFS_SERVER ou NFS_EXPORT inválido"
        return 1
    }
}

# -M exige o mountpoint exato: -T sozinho também retornaria o filesystem pai
# quando o NFS não está montado. Uma leitura reúne tipo, origem, alvo e ID.
read_nfs_mount() {
    findmnt --noheadings --raw --mountpoint "$1" --output ID,SOURCE,FSTYPE,TARGET
}

nfs_mount_matches() {
    local record=$1 expected_path=$2 expected_source=$3 expected_id=${4:-}
    local mount_id source filesystem target extra
    [[ -n "${record}" && "${record}" != *$'\n'* ]] || return 1
    read -r mount_id source filesystem target extra <<< "${record}"
    [[ "${mount_id}" =~ ^[0-9]+$ && -z "${extra}" &&
       ( "${filesystem}" == nfs || "${filesystem}" == nfs4 ) &&
       "${source}" == "${expected_source}" && "${target}" == "${expected_path}" &&
       ( -z "${expected_id}" || "${mount_id}" == "${expected_id}" ) ]]
}

nfs_active_mount_unchanged() {
    local record
    [[ -n "${NFS_ACTIVE_MOUNTPOINT}" && -n "${NFS_ACTIVE_ID}" ]] || return 1
    [[ "$(realpath -e -- "${NFS_ACTIVE_MOUNTPOINT}")" == "${NFS_ACTIVE_MOUNTPOINT}" ]] || return 1
    record="$(read_nfs_mount "${NFS_ACTIVE_MOUNTPOINT}")" || return 1
    nfs_mount_matches "${record}" "${NFS_ACTIVE_MOUNTPOINT}" \
        "${NFS_ACTIVE_SOURCE}" "${NFS_ACTIVE_ID}"
}

prepare_nfs_automount() {
    local record status expected_source mount_status=0 confirmed=0
    check_nfs_dependencies || return 1
    validate_nfs_mount_config || return 1
    expected_source="${NFS_SERVER}:${NFS_EXPORT}"
    ui_info "Verificando servidor NFS..."
    mkdir -p -- "${NFS_MOUNTPOINT}" || return 1
    validate_nfs_mount_config || return 1

    if record="$(read_nfs_mount "${NFS_MOUNTPOINT}")"; then
        nfs_mount_matches "${record}" "${NFS_MOUNTPOINT}" "${expected_source}" || {
            ui_error "Mountpoint ocupado por tipo ou origem diferente do NFS esperado: ${NFS_MOUNTPOINT} (${record})"
            return 1
        }
        ui_info "NFS já montado; reutilizando ${NFS_MOUNTPOINT}"
    else
        status=$?
        [[ ${status} -eq 1 && -z "${record}" ]] || {
            ui_error "Não foi possível consultar o mountpoint NFS com findmnt"
            return 1
        }
        ui_info "Montando ${expected_source} em ${NFS_MOUNTPOINT}"
        # O shell pode receber um sinal depois de mount retornar, mas antes
        # de registrar a responsabilidade. Adiar o handler até a confirmação
        # evita abandonar um mount conhecido nessa janela.
        NFS_MOUNT_IN_PROGRESS=1
        mount -t nfs -- "${expected_source}" "${NFS_MOUNTPOINT}" || mount_status=$?
        if [[ ${mount_status} -eq 0 ]]; then
            NFS_MOUNTED_BY_BUILDER=1
            NFS_ACTIVE_MOUNTPOINT=${NFS_MOUNTPOINT}
            NFS_ACTIVE_SOURCE=${expected_source}
            if record="$(read_nfs_mount "${NFS_MOUNTPOINT}")" &&
                nfs_mount_matches "${record}" "${NFS_MOUNTPOINT}" "${expected_source}"; then
                NFS_ACTIVE_ID=${record%% *}
                confirmed=1
            fi
        fi
        NFS_MOUNT_IN_PROGRESS=0
        if [[ -n "${NFS_PENDING_SIGNAL}" ]]; then
            on_signal "${NFS_PENDING_SIGNAL}"
        fi
        if [[ ${mount_status} -ne 0 ]]; then
            ui_error "Não foi possível montar ${expected_source}"
            return 1
        fi
        # Sem ID confirmado, o cleanup avisa e não desmonta um mount incerto.
        [[ ${confirmed} -eq 1 ]] || {
            ui_error "findmnt não confirmou o NFS esperado após mount: ${expected_source}"
            return 1
        }
        ui_success "NFS montado e validado"
    fi
    NFS_ACTIVE_MOUNTPOINT=${NFS_MOUNTPOINT}
    NFS_ACTIVE_SOURCE=${expected_source}
    NFS_ACTIVE_ID=${record%% *}
    BUILD_NFS_DIR=${NFS_MOUNTPOINT}
}

select_build_nfs_destination() {
    # CLI sempre vence, inclusive configurações de automount inválidas.
    if [[ -n "${BUILD_NFS_DIR}" ]]; then
        command -v findmnt >/dev/null 2>&1 || {
            ui_error "Suporte NFS indisponível: falta findmnt (util-linux)."
            return 1
        }
        return 0
    fi
    case "${NFS_ENABLED:-0}" in
        1) prepare_nfs_automount ;;
        0)
            BUILD_NFS_DIR=${NFS_IMAGES_DIR:-}
            if [[ -n "${BUILD_NFS_DIR}" ]]; then
                command -v findmnt >/dev/null 2>&1 || {
                    ui_error "Suporte NFS indisponível: falta findmnt (util-linux)."
                    return 1
                }
            fi
            ;;
        *) ui_error "NFS_ENABLED deve ser 0 ou 1"; return 1 ;;
    esac
}

cleanup_nfs_mount() {
    [[ "${NFS_MOUNTED_BY_BUILDER}" == 1 ]] || return 0
    if ! nfs_active_mount_unchanged; then
        ui_warn "NFS não desmontado: mount ausente, alterado ou sem identidade confirmada em ${NFS_ACTIVE_MOUNTPOINT}."
    elif umount -- "${NFS_ACTIVE_MOUNTPOINT}"; then
        NFS_MOUNTED_BY_BUILDER=0
        ui_info "NFS desmontado: ${NFS_ACTIVE_MOUNTPOINT}"
    else
        ui_warn "Não foi possível desmontar ${NFS_ACTIVE_MOUNTPOINT}; o resultado original do build foi preservado."
    fi
    return 0
}
