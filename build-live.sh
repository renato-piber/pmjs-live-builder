#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export PROJECT_ROOT

# shellcheck source=lib/ui.sh
source "${PROJECT_ROOT}/lib/ui.sh"
# shellcheck source=lib/logs.sh
source "${PROJECT_ROOT}/lib/logs.sh"
# shellcheck source=lib/checks.sh
source "${PROJECT_ROOT}/lib/checks.sh"
# shellcheck source=lib/build.sh
source "${PROJECT_ROOT}/lib/build.sh"

CURRENT_STAGE='inicializacao'
START_EPOCH=$(date +%s)
RUN_RESULT='falha'

usage() {
    cat <<'USAGE'
Uso:
  sudo ./build-live.sh                 Constroi e publica a ISO
  sudo ./build-live.sh --preflight     Executa somente as verificacoes
  sudo ./build-live.sh --clean         Limpa apenas a area work/ com protecoes
       ./build-live.sh --smoke-test [ISO]
                                       Inspeciona uma ISO ja construida
       ./build-live.sh --help
USAGE
}

handle_error() {
    local status=$1 line=$2 command_text=$3
    trap - ERR
    log_error "Etapa '${CURRENT_STAGE}' falhou na linha ${line} (status ${status}): ${command_text}"
    ui_error "Falha na etapa '${CURRENT_STAGE}'. Consulte: ${LOG_FILE:-logs/}"
    exit "$status"
}

handle_exit() {
    local status=$? duration
    duration=$(( $(date +%s) - START_EPOCH ))
    if (( status == 0 )); then
        RUN_RESULT='sucesso'
    fi
    [[ -n "$LOG_FILE" ]] && log_info "Fim: resultado=${RUN_RESULT}; duracao=${duration}s"
}

main() {
    local mode='build' smoke_path=''
    if (( $# > 0 )); then
        case "$1" in
            --clean) mode='clean' ;;
            --preflight) mode='preflight' ;;
            --smoke-test)
                mode='smoke'
                smoke_path=${2:-}
                (( $# <= 2 )) || { usage >&2; return 2; }
                ;;
            --help|-h) usage; return 0 ;;
            --version) tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION"; printf '\n'; return 0 ;;
            *) usage >&2; return 2 ;;
        esac
        [[ "$mode" == smoke ]] || (( $# == 1 )) || { usage >&2; return 2; }
    fi

    init_logging "${PROJECT_ROOT}/logs"
    trap 'handle_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
    trap handle_exit EXIT
    log_info "Inicio do PMJS Live Builder; modo=$mode"

    CURRENT_STAGE='carregamento da configuracao'
    load_live_config "${PROJECT_ROOT}/config/live.conf"
    validate_config
    log_info "Versao: $LIVE_VERSION; suite: $DEBIAN_SUITE; arquitetura: $LIVE_ARCH"

    case "$mode" in
        build)
            CURRENT_STAGE='pipeline de build'
            run_build_pipeline
            ;;
        preflight)
            CURRENT_STAGE='preflight'
            run_preflight
            ;;
        clean)
            CURRENT_STAGE='clean'
            check_root
            clean_workdir
            ;;
        smoke)
            CURRENT_STAGE='smoke test'
            if [[ -z "$smoke_path" ]]; then
                smoke_path="${OUTPUT_DIR_ABS}/$(iso_filename)"
            elif [[ "$smoke_path" != /* ]]; then
                smoke_path="${PROJECT_ROOT}/${smoke_path}"
            fi
            smoke_test_iso "$smoke_path"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

