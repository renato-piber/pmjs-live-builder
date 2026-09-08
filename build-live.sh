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
CLI_MODE='build'
CLI_SMOKE_PATH=''

usage() {
    cat <<'USAGE'
Uso:
  sudo ./build-live.sh                 Constroi e publica a ISO
  sudo ./build-live.sh --preflight     Executa somente as verificacoes
  sudo ./build-live.sh --clean         Limpa work/ e preserva cache/
  sudo ./build-live.sh --purge         Limpa work/ e tambem todo o cache/
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
    if [[ -n "$LOG_FILE" ]]; then
        [[ -n "${CACHE_DIR_ABS:-}" ]] && log_cache_metrics final
        log_info "Fim: resultado=${RUN_RESULT}; duracao=${duration}s"
    fi
}

parse_arguments() {
    CLI_MODE='build'
    CLI_SMOKE_PATH=''
    if (( $# > 0 )); then
        case "$1" in
            --clean) CLI_MODE='clean' ;;
            --purge) CLI_MODE='purge' ;;
            --preflight) CLI_MODE='preflight' ;;
            --smoke-test)
                CLI_MODE='smoke'
                CLI_SMOKE_PATH=${2:-}
                (( $# <= 2 )) || { usage >&2; return 2; }
                ;;
            --help|-h) CLI_MODE='help' ;;
            --version) CLI_MODE='version' ;;
            *) usage >&2; return 2 ;;
        esac
        [[ "$CLI_MODE" == smoke ]] || (( $# == 1 )) || { usage >&2; return 2; }
    fi
}

main() {
    parse_arguments "$@" || return $?
    case "$CLI_MODE" in
        help) usage; return 0 ;;
        version) tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION"; printf '\n'; return 0 ;;
    esac

    init_logging "${PROJECT_ROOT}/logs"
    trap 'handle_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
    trap handle_exit EXIT
    log_info "Inicio do PMJS Live Builder; modo=$CLI_MODE"

    CURRENT_STAGE='carregamento da configuracao'
    load_live_config "${PROJECT_ROOT}/config/live.conf"
    validate_config
    log_info "Versao: $LIVE_VERSION; suite: $DEBIAN_SUITE; arquitetura: $LIVE_ARCH"
    log_info "Cache: habilitado=$CACHE_ENABLED; local=$CACHE_DIR_ABS; pacotes=$CACHE_PACKAGES; indices=$CACHE_INDICES"

    case "$CLI_MODE" in
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
            clean_state_preserving_cache
            ;;
        purge)
            CURRENT_STAGE='purge'
            check_root
            purge_builder_state
            ;;
        smoke)
            CURRENT_STAGE='smoke test'
            if [[ -z "$CLI_SMOKE_PATH" ]]; then
                CLI_SMOKE_PATH="${OUTPUT_DIR_ABS}/$(iso_filename)"
            elif [[ "$CLI_SMOKE_PATH" != /* ]]; then
                CLI_SMOKE_PATH="${PROJECT_ROOT}/${CLI_SMOKE_PATH}"
            fi
            smoke_test_iso "$CLI_SMOKE_PATH"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
