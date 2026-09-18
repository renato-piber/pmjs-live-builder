#!/bin/bash

TIMER_TOTAL_START=0
TIMER_TOTAL_DURATION=0
TIMER_CURRENT_STEP=""
TIMER_CURRENT_START=0
TIMER_LIVE_PID=""
TIMER_LIVE_STATE_FILE=""
TIMER_LIVE_STATE_DIR=""
TIMER_LIVE_ACTIVE=0
declare -a TIMER_STEP_ORDER=()
declare -A TIMER_STEP_LABELS=()
declare -A TIMER_STEP_DURATIONS=()

# Modelo separado da segurança/execução: falhas de telemetria são não fatais.
TIMER_ETA_WORKSPACE=""
TIMER_ETA_KEY=""
TIMER_ETA_FAILED=0
TIMER_ETA_COMPLETE=0
declare -a TIMER_ETA_PLAN=(validation legacy_preflight home_preflight archive_preflight partitioning filesystems mounts extraction system_config home_post_validation boot)
declare -A TIMER_ETA_BASE_STEPS=()
declare -A TIMER_ETA_BASE_OPERATIONS=()

timer_eta_cleanup() {
    local directory=${TIMER_ETA_WORKSPACE:-}
    if [[ "$directory" =~ ^/tmp/pmjs-eta\.[A-Za-z0-9]+$ ]] &&
       [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]]; then
        rm -f -- "$directory/baseline" "$directory/operations" "$directory/steps" 2>/dev/null || true
        rmdir -- "$directory" 2>/dev/null || true
    fi
    TIMER_ETA_WORKSPACE=""
}

# A chave usa metadados, nunca uma leitura extra dos archives. Não inclui a
# identidade institucional da máquina. Sem identificação, não reutiliza modelo.
timer_eta_context() {
    local disk="" source=""
    disk=$(lsblk -dnbo MODEL,SIZE,ROTA,TRAN -- "${INSTALL_DISK:-}" 2>/dev/null) || return 1
    [ -n "$disk" ] || return 1
    source=$(findmnt -rn -o SOURCE,FSTYPE --target "${INSTALL_IMAGE_DIR:-}" 2>/dev/null) || return 1
    [ -n "$source" ] || return 1
    python3 - "${INSTALL_IMAGE_DIR:-}" "${INSTALL_STORAGE_MODE:-}" "${INSTALL_BOOT_MODE:-}" \
        "${IMAGES_SOURCE:-}" "$disk" "$source" "${VERSION:-}" <<'PY'
import hashlib, json, os, pathlib, stat, sys
directory, storage, boot, origin, disk, source, version = sys.argv[1:]
root = pathlib.Path(directory)
if not root.is_dir() or storage not in ('clean', 'preserve_home') or boot not in ('uefi', 'legacy'):
    raise ValueError('contexto incompleto')
identity = {}
manifest = root / 'manifest.json'
if manifest.exists():
    if manifest.is_symlink() or manifest.stat().st_size > 65536:
        raise ValueError('manifest inseguro')
    data = manifest.read_bytes()
    descriptor = json.loads(data)
    if descriptor.get('schema_version') != 1:
        raise ValueError('schema desconhecido')
    identity['manifest'] = hashlib.sha256(data).hexdigest()
    names = [descriptor[role]['filename'] for role in ('rootfs', 'homefs')]
else:
    names = ['rootfs.tar.gz'] + ([] if storage == 'preserve_home' else ['homefs.tar.gz'])
for name in names:
    if not isinstance(name, str) or pathlib.Path(name).name != name or name in ('.', '..'):
        raise ValueError('nome inseguro')
    info = (root / name).lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
        raise ValueError('archive inválido')
    identity[name] = [info.st_size, info.st_mtime_ns]
cpu = [line.strip() for line in pathlib.Path('/proc/cpuinfo').read_text().splitlines()
       if line.startswith(('vendor_id', 'cpu family', 'model\t', 'model name'))][:4]
if not cpu:
    raise ValueError('CPU não identificado')
context = [1, version, root.name, identity, storage, boot, origin, disk.strip(), source.strip(), cpu]
print(hashlib.sha256(json.dumps(context, sort_keys=True).encode()).hexdigest())
PY
}

# Histórico limitado, JSON sem código executável; lock e rename no mesmo FS.
# A mesma rotina valida leitura e gravação. Arquivos/symlinks inseguros não são
# seguidos; corrupção ou falta de permissões apenas desabilitam a referência.
timer_eta_history() {
    python3 - "$1" "${ETA_HISTORY_FILE:-}" "$TIMER_ETA_KEY" "$TIMER_ETA_WORKSPACE" \
        "${TIMER_ETA_PLAN[*]}" <<'PY'
import fcntl, json, os, pathlib, re, stat, statistics, sys, tempfile, time
action, filename, key, workspace, plan_text = sys.argv[1:]
plan = plan_text.split()
path = pathlib.Path(filename)
if not path.is_absolute() or '..' in path.parts or path.parent == pathlib.Path('/'):
    raise ValueError('path de histórico inseguro')
for ancestor in list(path.parents)[::-1]:
    if ancestor.is_symlink():
        raise ValueError('diretório symlink')
    if ancestor.exists() and ancestor.stat().st_mode & stat.S_IWOTH:
        # /tmp sticky é permitido para fixtures/diretórios privados filhos.
        if not ancestor.stat().st_mode & stat.S_ISVTX or ancestor == path.parent:
            raise ValueError('diretório gravável por terceiros')
if action == 'save':
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
info = path.parent.stat()
if info.st_uid != os.geteuid() or info.st_mode & 0o022:
    raise ValueError('diretório de histórico não privado')
directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    fcntl.flock(directory_fd, (fcntl.LOCK_EX if action == 'save' else fcntl.LOCK_SH) | fcntl.LOCK_NB)
    history = {'schema': 1, 'profiles': {}}
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    except FileNotFoundError:
        pass
    else:
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022 or info.st_size > 2 * 1024 * 1024:
                raise ValueError('histórico inseguro')
            history = json.load(stream)
    if history.get('schema') != 1 or not isinstance(history.get('profiles'), dict) or len(history['profiles']) > 32:
        raise ValueError('histórico inválido')
    def valid_sample(sample):
        if not isinstance(sample, dict) or set(sample.get('steps', {})) != set(plan):
            return False
        return (all(type(v) is int and 0 <= v <= 86400000 for v in sample['steps'].values())
                and isinstance(sample.get('operations'), dict)
                and len(sample['operations']) <= 128
                and all(isinstance(k, str) and len(k) <= 256 and k.split('/', 1)[0] in plan
                        and '/' in k and not any(ord(c) < 32 or c == '|' for c in k)
                        and type(v) is int and 0 <= v <= 86400000
                        for k, v in sample['operations'].items()))
    for profile_key, profile in history['profiles'].items():
        if not re.fullmatch('[0-9a-f]{64}', profile_key) or not isinstance(profile, dict):
            raise ValueError('perfil inválido')
        if type(profile.get('updated')) is not int or not isinstance(profile.get('samples'), list) or not 1 <= len(profile['samples']) <= 5:
            raise ValueError('amostras inválidas')
        if not all(valid_sample(sample) for sample in profile['samples']):
            raise ValueError('amostra inválida')
    if action == 'load':
        samples = history['profiles'].get(key, {}).get('samples', [])
        if samples:
            for step in plan:
                print('step|%s|%d' % (step, statistics.median(s['steps'][step] for s in samples)))
            # Só usa operações presentes em todas as amostras comparáveis.
            common = set.intersection(*(set(s['operations']) for s in samples))
            for operation in sorted(common):
                print('operation|%s|%d' % (operation, statistics.median(s['operations'][operation] for s in samples)))
    elif action == 'save':
        steps = {}
        for line in (pathlib.Path(workspace) / 'steps').read_text().splitlines():
            step, duration = line.split('|')
            if step in steps:
                raise ValueError('etapa duplicada')
            steps[step] = int(duration)
        operations = {}
        repeated = set()
        for line in (pathlib.Path(workspace) / 'operations').read_text().splitlines():
            step, label, duration = line.split('|')
            operation = step + '/' + label
            # Labels repetidos não identificam uma ocorrência sem ambiguidade.
            # Nesse caso, conserva apenas a referência da fase inteira.
            if operation in operations:
                operations.pop(operation)
                repeated.add(operation)
            elif operation not in repeated:
                operations[operation] = int(duration)
        sample = {'steps': steps, 'operations': operations}
        if not valid_sample(sample):
            raise ValueError('instalação incompleta')
        samples = history['profiles'].get(key, {}).get('samples', [])
        history['profiles'][key] = {'updated': int(time.time()), 'samples': (samples + [sample])[-5:]}
        history['profiles'] = dict(sorted(history['profiles'].items(), key=lambda item: item[1]['updated'], reverse=True)[:32])
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix='.eta-history-', dir=path.parent)
            with os.fdopen(fd, 'w') as stream:
                json.dump(history, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            os.fsync(directory_fd)
        finally:
            if temporary is not None and os.path.exists(temporary):
                os.unlink(temporary)
finally:
    os.close(directory_fd)
PY
}

timer_eta_prepare() {
    TIMER_ETA_BASE_STEPS=(); TIMER_ETA_BASE_OPERATIONS=()
    TIMER_ETA_FAILED=0; TIMER_ETA_COMPLETE=0; TIMER_ETA_KEY=""
    [ "${ETA_HISTORY_ENABLED:-0}" = 1 ] && [ "${INSTALL_EXECUTION_MODE:-}" = real ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    TIMER_ETA_KEY=$(timer_eta_context 2>/dev/null) || { TIMER_ETA_KEY=""; return 0; }
    TIMER_ETA_WORKSPACE=$(mktemp -d /tmp/pmjs-eta.XXXXXX) || return 0
    if ! { : > "$TIMER_ETA_WORKSPACE/operations"; : > "$TIMER_ETA_WORKSPACE/steps"; }; then
        timer_eta_cleanup
        return 0
    fi
    local kind="" name="" duration=""
    if timer_eta_history load > "$TIMER_ETA_WORKSPACE/baseline" 2>/dev/null; then
        while IFS='|' read -r kind name duration; do
            [[ "$duration" =~ ^[0-9]+$ ]] || continue
            case "$kind" in
                step) TIMER_ETA_BASE_STEPS["$name"]=$duration ;;
                operation) TIMER_ETA_BASE_OPERATIONS["$name"]=$duration ;;
            esac
        done < "$TIMER_ETA_WORKSPACE/baseline"
    fi
    if (( ${#TIMER_ETA_BASE_STEPS[@]} > 0 )); then
        log_info "ETA global: referência aproximada de instalações concluídas comparáveis."
    else
        log_info "ETA global: sem histórico comparável; calculando até obter referência."
    fi
}

timer_eta_record_operation() {
    local label=$1 milliseconds=$2
    [ -n "${TIMER_ETA_WORKSPACE:-}" ] && [ -n "${TIMER_CURRENT_STEP:-}" ] || return 0
    [[ "$milliseconds" =~ ^[0-9]+$ ]] || return 0
    label=${label//$'\n'/ }; label=${label//|/-}
    printf '%s|%s|%s\n' "$TIMER_CURRENT_STEP" "$label" "$milliseconds" >> "$TIMER_ETA_WORKSPACE/operations" 2>/dev/null || true
}

timer_eta_finish() {
    if [ -n "${TIMER_ETA_WORKSPACE:-}" ] && [ "$TIMER_ETA_FAILED" = 0 ] &&
       [ "${INSTALL_EXECUTION_MODE:-}" = real ] && [ "${INSTALL_BOOT_READY:-0}" = 1 ]; then
        if timer_eta_history save >/dev/null 2>&1; then
            TIMER_ETA_COMPLETE=1
            log_info "ETA global: histórico atualizado após instalação real concluída."
        else
            log_warning "ETA global: histórico não pôde ser atualizado; instalação não afetada."
        fi
    fi
    timer_eta_cleanup
}

# Retorna segundos ou um estado explícito. Não calcula percentual global.
timer_eta_estimate() {
    local current=$1 elapsed=$2 label=${3:-} operation_elapsed=${4:-0} measured=${5:-} result=${6:-running}
    local step="" seen=0 future=0 remaining=0 completed_base=0 completed_actual=0 outside=0
    local recorded_step="" recorded_label="" duration=0 operation=""
    TIMER_ETA_REMAINING=""; TIMER_ETA_STATUS="calculando..."
    [ "$result" != failed ] || { TIMER_ETA_STATUS="operação falhou"; return 0; }
    [[ "$elapsed" =~ ^[0-9]+$ && "$operation_elapsed" =~ ^[0-9]+$ ]] || return 0
    [ -n "$current" ] || return 0
    for step in "${TIMER_ETA_PLAN[@]}"; do
        if [ "$step" = "$current" ]; then seen=1; fi
        [ "$seen" = 1 ] || continue
        [[ "${TIMER_ETA_BASE_STEPS[$step]:-}" =~ ^[0-9]+$ ]] || return 0
        [ "$step" = "$current" ] || future=$((future + TIMER_ETA_BASE_STEPS[$step]))
    done
    [ "$seen" = 1 ] || return 0
    if [ -f "${TIMER_ETA_WORKSPACE:-}/operations" ]; then
        while IFS='|' read -r recorded_step recorded_label duration; do
            [ "$recorded_step" = "$current" ] || continue
            [[ "$duration" =~ ^[0-9]+$ ]] || continue
            operation="$current/$recorded_label"
            # Uma operação sem referência conserva o fallback por tempo da fase.
            [[ "${TIMER_ETA_BASE_OPERATIONS[$operation]:-}" =~ ^[0-9]+$ ]] || continue
            completed_actual=$((completed_actual + duration))
            completed_base=$((completed_base + TIMER_ETA_BASE_OPERATIONS[$operation]))
        done < "$TIMER_ETA_WORKSPACE/operations"
    fi
    remaining=$((TIMER_ETA_BASE_STEPS[$current] - completed_base - elapsed * 1000 + completed_actual))
    operation="$current/$label"
    if [ "$result" = running ] && [[ "$measured" =~ ^[0-9]+$ && "${TIMER_ETA_BASE_OPERATIONS[$operation]:-}" =~ ^[0-9]+$ ]]; then
        outside=$((elapsed * 1000 - completed_actual - operation_elapsed))
        (( outside >= 0 )) || outside=0
        remaining=$((TIMER_ETA_BASE_STEPS[$current] - completed_base - TIMER_ETA_BASE_OPERATIONS[$operation] - outside))
        (( remaining >= 0 )) || remaining=0
        remaining=$((remaining + measured * 1000))
    fi
    if (( remaining <= 0 )); then
        TIMER_ETA_STATUS="recalculando..."
        return 0 # Não mascarar estouro da fase com a previsão das fases futuras.
    fi
    if [[ "$measured" =~ ^[0-9]+$ ]] && [ "$result" = running ]; then
        (( remaining >= measured * 1000 )) || remaining=$((measured * 1000))
    fi
    TIMER_ETA_REMAINING=$(((future + remaining + 999) / 1000))
    TIMER_ETA_STATUS="aproximado (histórico)"
}

timer_eta_smooth() {
    local remaining=$1
    [[ "$remaining" =~ ^[0-9]+$ ]] || { TIMER_ETA_SMOOTHED=""; return 0; }
    if [[ "${TIMER_ETA_SMOOTHED:-}" =~ ^[0-9]+$ ]]; then
        TIMER_ETA_SMOOTHED=$(((TIMER_ETA_SMOOTHED * 3 + remaining + 2) / 4))
    else
        TIMER_ETA_SMOOTHED=$remaining
    fi
}

# Taxa EWMA em bytes/unidades por segundo; ETA somente apos aquecimento.
timer_progress_reset() {
    TIMER_PROGRESS_LAST_DONE=0
    TIMER_PROGRESS_LAST_MS=0
    TIMER_PROGRESS_RATE=0
    TIMER_PROGRESS_SAMPLES=0
    TIMER_PROGRESS_PERCENT=""
    TIMER_PROGRESS_ETA=""
}

timer_progress_update() {
    local done=$1 total=$2 milliseconds=$3 result=${4:-running} delta=0 rate=0 remaining=0
    TIMER_PROGRESS_PERCENT=""
    TIMER_PROGRESS_ETA=""
    [[ "$done" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$milliseconds" =~ ^[0-9]+$ ]] || return 1
    (( total > 0 )) || return 0
    (( done <= total )) || done=$total
    TIMER_PROGRESS_PERCENT=$((done * 100 / total))
    if [ "$result" = success ]; then
        TIMER_PROGRESS_PERCENT=100
        TIMER_PROGRESS_ETA=0
        return 0
    fi
    # EOF/read-ahead nao significa que o consumidor terminou/teve sucesso.
    (( TIMER_PROGRESS_PERCENT < 100 )) || TIMER_PROGRESS_PERCENT=99
    [ "$result" = running ] || return 0
    if (( done < TIMER_PROGRESS_LAST_DONE || milliseconds < TIMER_PROGRESS_LAST_MS )); then
        timer_progress_reset
        return 0
    fi
    delta=$((milliseconds - TIMER_PROGRESS_LAST_MS))
    if (( delta >= 1000 )); then
        rate=$(((done - TIMER_PROGRESS_LAST_DONE) * 1000 / delta))
        if (( TIMER_PROGRESS_SAMPLES == 0 )); then
            TIMER_PROGRESS_RATE=$rate
        else
            TIMER_PROGRESS_RATE=$(((TIMER_PROGRESS_RATE * 3 + rate) / 4))
        fi
        TIMER_PROGRESS_SAMPLES=$((TIMER_PROGRESS_SAMPLES + 1))
        TIMER_PROGRESS_LAST_DONE=$done
        TIMER_PROGRESS_LAST_MS=$milliseconds
    fi
    if (( milliseconds >= 5000 && TIMER_PROGRESS_SAMPLES >= 3 &&
          TIMER_PROGRESS_RATE > 0 && done > 0 && done < total )); then
        remaining=$((total - done))
        TIMER_PROGRESS_ETA=$(((remaining + TIMER_PROGRESS_RATE - 1) / TIMER_PROGRESS_RATE))
    fi
}

timer_progress_publish() {
    local token=$1 label=$2 kind=$3 done=$4 total=$5 milliseconds=$6 result=$7 started=$8
    local temporary=""
    if [ "$result" = success ]; then timer_eta_record_operation "$label" "$milliseconds"; fi
    [ "${TIMER_LIVE_ACTIVE:-0}" -eq 1 ] && [ -f "${TIMER_LIVE_STATE_FILE:-}" ] || return 0
    label=${label//$'\n'/ }; label=${label//|/-}
    temporary=$(mktemp "${TIMER_LIVE_STATE_FILE}.progress.tmp.XXXXXX") || return 0
    if ! printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$token" "$label" "$kind" "$done" "$total" "$milliseconds" "$result" "$started" > "$temporary" ||
       ! mv -f -- "$temporary" "${TIMER_LIVE_STATE_FILE}.progress"; then
        rm -f -- "$temporary"
        return 0 # Falha da telemetria nao muda o resultado da operacao.
    fi
}

timer_progress_indeterminate() {
    timer_progress_publish "${BASHPID}-${RANDOM}" "$1" C 0 0 0 running "$(timer_now)"
}

# Um unico leitor: o filho recebe o archive como stdin regular e compartilha
# a open file description com o supervisor. lseek consulta offset, nao le dados.
# Mantido neste modulo para nao exigir um novo arquivo no snapshot da Live.
timer_archive_run() {
    local archive=$1 label=$2 kind=$3 state="" status=0
    shift 3
    if [ "${TIMER_LIVE_ACTIVE:-0}" -eq 1 ]; then state=$TIMER_LIVE_STATE_FILE; fi
    if ! command -v python3 >/dev/null 2>&1; then
        timer_progress_indeterminate "$label (sem medicao)"
        "$@" < "$archive"
        return $?
    fi
    python3 - "$archive" "$label" "$kind" "$state" "${TIMER_ETA_WORKSPACE:-}" "${TIMER_CURRENT_STEP:-}" "$@" <<'PY' || status=$?
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

archive, label, kind, state, eta_workspace, eta_step, *command = sys.argv[1:]
token = uuid.uuid4().hex
label = label.replace('|', '-').replace('\n', ' ')
started_wall = int(time.time())
started = time.monotonic()
child = None
pending_signal = 0
metric_available = True

def interrupted(signum, frame):
    global pending_signal
    pending_signal = signum
    if child is not None:
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, interrupted)

def publish(done, total, result):
    if result == 'success' and eta_workspace and eta_step:
        try:
            fd = os.open(os.path.join(eta_workspace, 'operations'),
                         os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
            with os.fdopen(fd, 'w') as output:
                output.write(f'{eta_step}|{label}|{int((time.monotonic() - started) * 1000)}\n')
        except OSError:
            pass
    if not state or not os.path.isfile(state):
        return
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix='.progress-', dir=os.path.dirname(state))
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            measured_kind = kind if metric_available else 'C'
            output.write(f'{token}|{label}|{measured_kind}|{done}|{total}|'
                         f'{int((time.monotonic() - started) * 1000)}|{result}|{started_wall}\n')
        os.replace(temporary, state + '.progress')
    except OSError:
        pass # Apenas feedback; nunca mascarar erro do archive/consumidor.
    finally:
        try:
            if temporary is not None:
                os.unlink(temporary)
        except FileNotFoundError:
            pass
        except OSError:
            pass

def position(fd, total):
    global metric_available
    try:
        return min(os.lseek(fd, 0, os.SEEK_CUR), total)
    except OSError:
        metric_available = False
        return 0 # Falha de medicao: consumidor continua, UI indeterminada.

try:
    fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb', buffering=0) as source:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
            raise ValueError('archive nao regular ou vazio')
        total = info.st_size
        publish(0, total, 'running')
        child = subprocess.Popen(command, stdin=source, start_new_session=True)
        if pending_signal:
            interrupted(pending_signal, None)
        while child.poll() is None:
            publish(position(fd, total), total, 'running')
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            if pending_signal and child.poll() is None:
                # Um consumidor que ignore TERM nao pode permanecer orfao.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        status = 128 + pending_signal if pending_signal else child.returncode
        if status < 0:
            status = 128 - status
        if pending_signal:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        publish(position(fd, total), total,
                'success' if status == 0 else 'failed')
        sys.exit(status)
except (OSError, ValueError) as error:
    if child is not None and child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
    print(f'Falha no consumidor do archive: {error}', file=sys.stderr)
    publish(0, 0, 'failed')
    sys.exit(1)
PY
    return "$status"
}

timer_now() {
    date +%s
}

timer_reset() {
    timer_live_stop "cleanup antes de reiniciar o timer" || true
    timer_eta_cleanup
    TIMER_ETA_BASE_STEPS=(); TIMER_ETA_BASE_OPERATIONS=()
    TIMER_ETA_KEY=""; TIMER_ETA_FAILED=0; TIMER_ETA_COMPLETE=0
    timer_progress_reset
    TIMER_TOTAL_START=0
    TIMER_TOTAL_DURATION=0
    TIMER_CURRENT_STEP=""
    TIMER_CURRENT_START=0
    TIMER_STEP_ORDER=()
    TIMER_STEP_LABELS=()
    TIMER_STEP_DURATIONS=()
}

timer_terminal_size() {
    local size=""
    local rows=""
    local columns=""

    if command -v tput >/dev/null 2>&1; then
        rows=$(tput lines </dev/tty 2>/dev/null || true)
        columns=$(tput cols </dev/tty 2>/dev/null || true)
    fi
    if ! [[ "$rows" =~ ^[0-9]+$ ]] || ! [[ "$columns" =~ ^[0-9]+$ ]]; then
        size=$(stty size </dev/tty 2>/dev/null || true)
        rows=${size%% *}
        columns=${size##* }
    fi
    [[ "$rows" =~ ^[0-9]+$ ]] || return 1
    [[ "$columns" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$rows" "$columns"
}

timer_live_publish_state() {
    local temporary=""
    local label=""

    [ "$TIMER_LIVE_ACTIVE" -eq 1 ] || return 0
    [ -n "$TIMER_LIVE_STATE_FILE" ] || return 1
    if [ -n "$TIMER_CURRENT_STEP" ]; then
        label="${TIMER_STEP_LABELS[$TIMER_CURRENT_STEP]:-Aguardando próxima etapa}"
    else
        label="Aguardando próxima etapa"
    fi
    label=${label//$'\n'/ }
    label=${label//|/-}
    temporary=$(mktemp "${TIMER_LIVE_STATE_FILE}.tmp.XXXXXX") || return 1
    if ! printf '%s|%s|%s|%s\n' \
        "$TIMER_CURRENT_STEP" "$label" "$TIMER_CURRENT_START" "$TIMER_TOTAL_START" \
        > "$temporary" ||
       ! mv -f -- "$temporary" "$TIMER_LIVE_STATE_FILE"; then
        rm -f -- "$temporary"
        return 1
    fi
}

timer_live_worker() {
    local parent_pid="$1"
    local state_file="$2"
    local rows="$3"
    local columns="$4"
    local scroll_bottom=$((rows - 7))
    local step_id=""
    local label=""
    local step_start=0
    local total_start=0
    local now=0
    local step_elapsed=0
    local total_elapsed=0
    local cleanup_reason="encerramento normal"
    local token="" previous_token="" progress_label="" kind="" done=0 total=0 milliseconds=0 result="" started=0
    local progress_text="indeterminado" eta_text="não disponível" filled=0 empty=0 bar="" footer=""
    local global_text="calculando..." previous_step="" phase_elapsed=0
    TIMER_ETA_SMOOTHED=""
    timer_progress_reset

    timer_live_worker_cleanup() {
        local row=0

        if exec 9<>/dev/tty 2>/dev/null; then
            printf '\0337\033[r' >&9
            for row in $((rows - 5)) $((rows - 4)) $((rows - 3)) $((rows - 2)) $((rows - 1)) "$rows"; do
                printf '\033[%s;1H\033[2K' "$row" >&9
            done
            printf '\0338\033[?25h' >&9
            exec 9>&-
        fi
        log_info "Timer ao vivo: encerrado por $cleanup_reason."
    }

    trap 'cleanup_reason="cleanup/sinal"; exit 0' INT TERM HUP
    trap timer_live_worker_cleanup EXIT

    exec 9<>/dev/tty 2>/dev/null || {
        cleanup_reason="falha não fatal ao abrir /dev/tty"
        return 0
    }
    printf '\033[?25l\033[1;%sr\033[%s;1H' "$scroll_bottom" "$scroll_bottom" >&9
    : > "${state_file}.ready"

    while kill -0 "$parent_pid" 2>/dev/null; do
        if IFS='|' read -r step_id label step_start total_start < "$state_file" 2>/dev/null; then
            now=$(timer_now)
            [[ "$step_start" =~ ^[0-9]+$ ]] || step_start=$now
            [[ "$total_start" =~ ^[0-9]+$ ]] || total_start=$now
            (( step_start > 0 && step_start <= now )) || step_start=$now
            (( total_start > 0 && total_start <= now )) || total_start=$now
            step_elapsed=$((now - step_start))
            phase_elapsed=$step_elapsed
            total_elapsed=$((now - total_start))
            kind=C; result=running; milliseconds=0; progress_label=""
            TIMER_PROGRESS_ETA=""
            progress_text="indeterminado"; eta_text="não disponível"
            if [ -f "${state_file}.progress" ] && IFS='|' read -r token progress_label kind done total milliseconds result started < "${state_file}.progress"; then
                if [ "$token" != "$previous_token" ]; then timer_progress_reset; previous_token=$token; fi
                label=$progress_label
                if [[ "$started" =~ ^[0-9]+$ ]]; then
                    step_elapsed=$((now - started))
                    (( step_elapsed >= 0 )) || step_elapsed=0
                fi
                if [ "$kind" != C ] && timer_progress_update "$done" "$total" "$milliseconds" "$result" && [ -n "$TIMER_PROGRESS_PERCENT" ]; then
                    filled=$((TIMER_PROGRESS_PERCENT / 5)); empty=$((20 - filled))
                    printf -v bar '%*s' "$filled" ''; bar=${bar// /#}
                    printf -v footer '%*s' "$empty" ''; footer=${footer// /-}
                    progress_text="[$bar$footer] ${TIMER_PROGRESS_PERCENT}%"
                    [ "$kind" != B ] || progress_text+=" (aprox.)"
                    eta_text="calculando..."
                    if [ -n "$TIMER_PROGRESS_ETA" ]; then eta_text="~$(timer_format_duration "$TIMER_PROGRESS_ETA")"; fi
                    if [ "$result" = running ] && (( done >= total )); then eta_text="finalizando..."; fi
                fi
                [ "$result" != failed ] || eta_text="operação falhou"
            fi
            timer_eta_estimate "$step_id" "$phase_elapsed" "$progress_label" "$milliseconds" "$TIMER_PROGRESS_ETA" "$result"
            global_text=$TIMER_ETA_STATUS
            if [ "$step_id" != "$previous_step" ]; then TIMER_ETA_SMOOTHED=""; previous_step=$step_id; fi
            if [ -n "$TIMER_ETA_REMAINING" ]; then
                timer_eta_smooth "$TIMER_ETA_REMAINING"
                global_text="~$(timer_format_duration "$TIMER_ETA_SMOOTHED") (aprox.)"
            else
                TIMER_ETA_SMOOTHED=""
            fi
            label=${label:0:$((columns - 7))}
            footer="Restante da etapa: $eta_text"; footer=${footer:0:$columns}
            progress_text=${progress_text:0:$((columns - 11))}
            global_text="Restante da instalação: $global_text"; global_text=${global_text:0:$columns}
            printf '\0337\033[%s;1H\033[2KEtapa: %s\033[%s;1H\033[2KProgresso: %s\033[%s;1H\033[2KDecorrido etapa: %s\033[%s;1H\033[2KDecorrido total: %s\033[%s;1H\033[2K%s\033[%s;1H\033[2K%s\0338' \
                "$((rows - 5))" "$label" "$((rows - 4))" "$progress_text" \
                "$((rows - 3))" "$(timer_format_duration "$step_elapsed")" \
                "$((rows - 2))" "$(timer_format_duration "$total_elapsed")" "$((rows - 1))" "$footer" "$rows" "$global_text" >&9
        fi
        sleep 1
    done
    cleanup_reason="cleanup após encerramento do processo principal"
}

timer_live_start() {
    local size=""
    local rows=0
    local columns=0
    local attempt=0

    [ "$TIMER_LIVE_ACTIVE" -eq 0 ] || return 0
    if [ ! -t 1 ] || [ ! -t 2 ] || [ "${TERM:-dumb}" = dumb ]; then
        return 0 # Redirecionamento/logs: nenhuma atualizacao ou escape ANSI.
    fi
    if [ ! -c /dev/tty ] || ! { : </dev/tty; } 2>/dev/null; then
        log_warning "Timer ao vivo: /dev/tty indisponível; recurso desabilitado sem interromper a instalação."
        return 0
    fi
    size=$(timer_terminal_size) || {
        log_warning "Timer ao vivo: não foi possível obter o tamanho do terminal; recurso desabilitado."
        return 0
    }
    read -r rows columns <<< "$size"
    if [ "$rows" -lt 14 ] || [ "$columns" -lt 50 ]; then
        log_warning "Timer ao vivo: terminal pequeno (${rows}x${columns}); recurso desabilitado."
        return 0
    fi

    TIMER_LIVE_STATE_DIR=$(mktemp -d /tmp/pmjs-timer-live.XXXXXX) || {
        log_warning "Timer ao vivo: falha não fatal ao criar arquivo de estado."
        return 0
    }
    TIMER_LIVE_STATE_FILE="${TIMER_LIVE_STATE_DIR}/state"
    TIMER_LIVE_ACTIVE=1
    timer_live_publish_state || {
        rm -f -- "$TIMER_LIVE_STATE_FILE"
        rmdir -- "$TIMER_LIVE_STATE_DIR" 2>/dev/null || true
        TIMER_LIVE_STATE_DIR=""
        TIMER_LIVE_STATE_FILE=""
        TIMER_LIVE_ACTIVE=0
        log_warning "Timer ao vivo: falha não fatal ao publicar estado inicial."
        return 0
    }
    timer_live_worker "$$" "$TIMER_LIVE_STATE_FILE" "$rows" "$columns" \
        >/dev/null 2>&1 &
    TIMER_LIVE_PID=$!
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [ -e "${TIMER_LIVE_STATE_FILE}.ready" ] && break
        kill -0 "$TIMER_LIVE_PID" 2>/dev/null || break
        sleep 0.05
    done
    if [ ! -e "${TIMER_LIVE_STATE_FILE}.ready" ]; then
        log_warning "Timer ao vivo: falha não fatal ao reservar a região do terminal."
        timer_live_stop "falha na inicialização" || true
        return 0
    fi
    log_info "Timer ao vivo iniciado com PID $TIMER_LIVE_PID."
}

timer_live_stop() {
    local reason="${1:-encerramento normal}"
    local pid="${TIMER_LIVE_PID:-}"
    local safe_state=1

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    if [ "$TIMER_LIVE_ACTIVE" -eq 1 ]; then
        log_info "Timer ao vivo: encerramento solicitado ($reason)."
    fi
    if [ -n "${TIMER_LIVE_STATE_DIR:-}" ]; then
        if ! [[ "$TIMER_LIVE_STATE_DIR" =~ ^/tmp/pmjs-timer-live\.[A-Za-z0-9]+$ &&
                "$TIMER_LIVE_STATE_FILE" == "$TIMER_LIVE_STATE_DIR/state" &&
                -d "$TIMER_LIVE_STATE_DIR" && ! -L "$TIMER_LIVE_STATE_DIR" && -O "$TIMER_LIVE_STATE_DIR" ]]; then
            safe_state=0
            log_warning "Timer: workspace inconsistente; nenhum arquivo de estado removido."
        fi
    fi
    if [ "$safe_state" -eq 1 ] && [ -n "$TIMER_LIVE_STATE_FILE" ]; then
        rm -f -- "$TIMER_LIVE_STATE_FILE" "${TIMER_LIVE_STATE_FILE}.ready" "${TIMER_LIVE_STATE_FILE}.progress"
    fi
    if [ "$safe_state" -eq 1 ] && [ -n "${TIMER_LIVE_STATE_DIR:-}" ]; then
        if ! rmdir -- "$TIMER_LIVE_STATE_DIR"; then
            log_warning "Timer: workspace temporario nao vazio; mantido para cleanup seguro: $TIMER_LIVE_STATE_DIR"
        fi
    fi
    TIMER_LIVE_PID=""
    TIMER_LIVE_STATE_FILE=""
    TIMER_LIVE_STATE_DIR=""
    TIMER_LIVE_ACTIVE=0
}

timer_total_start() {
    TIMER_TOTAL_START=$(timer_now)
    log_info "Timer total iniciado."
}

timer_total_stop() {
    local now=0

    [ "$TIMER_TOTAL_START" -gt 0 ] || return 1
    now=$(timer_now)
    TIMER_TOTAL_DURATION=$((now - TIMER_TOTAL_START))
    log_info "Timer total finalizado em $TIMER_TOTAL_DURATION segundo(s)."
}

timer_step_start() {
    local step_id="$1"
    local label="$2"

    if [ -n "$TIMER_CURRENT_STEP" ]; then
        log_warning "Timer: etapa $TIMER_CURRENT_STEP ainda estava ativa; encerrando antes de iniciar $step_id."
        timer_step_stop "$TIMER_CURRENT_STEP" || true
    fi

    TIMER_CURRENT_STEP="$step_id"
    TIMER_CURRENT_START=$(timer_now)
    TIMER_STEP_LABELS["$step_id"]="$label"
    TIMER_STEP_ORDER+=("$step_id")
    log_info "Timer da etapa iniciado: $label."
    if [ -n "${TIMER_LIVE_STATE_FILE:-}" ]; then rm -f -- "${TIMER_LIVE_STATE_FILE}.progress"; fi
    if [ "$TIMER_LIVE_ACTIVE" -eq 1 ]; then
        log_info "Timer ao vivo: troca de etapa para $label."
        timer_live_publish_state || {
            log_warning "Timer ao vivo: falha não fatal ao atualizar a etapa."
            timer_live_stop "falha de publicação" || true
        }
    fi
}

timer_step_stop() {
    local step_id="$1"
    local now=0
    local duration=0

    [ "$TIMER_CURRENT_STEP" = "$step_id" ] || return 1
    now=$(timer_now)
    duration=$((now - TIMER_CURRENT_START))
    TIMER_STEP_DURATIONS["$step_id"]="$duration"
    log_info "Timer da etapa finalizado: ${TIMER_STEP_LABELS[$step_id]} em $duration segundo(s)."
    TIMER_CURRENT_STEP=""
    TIMER_CURRENT_START=0
    timer_live_publish_state || true
}

timer_run_step() {
    local step_id="$1"
    local label="$2"
    local status=0
    shift 2

    timer_step_start "$step_id" "$label"
    "$@" || status=$?
    timer_step_stop "$step_id" || true
    if [ -n "${TIMER_ETA_WORKSPACE:-}" ]; then
        printf '%s|%s\n' "$step_id" "$((${TIMER_STEP_DURATIONS[$step_id]:-0} * 1000))" >> "$TIMER_ETA_WORKSPACE/steps" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then
        TIMER_ETA_FAILED=1
        timer_live_stop "cleanup após falha na etapa $label" || true
        timer_eta_cleanup
    fi
    return "$status"
}

timer_format_duration() {
    local total_seconds="${1:-0}"
    local hours=0
    local minutes=0
    local seconds=0

    hours=$((total_seconds / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if [ "$hours" -gt 0 ]; then
        printf '%02dh %02dm %02ds' "$hours" "$minutes" "$seconds"
    elif [ "$minutes" -gt 0 ]; then
        printf '%02dm %02ds' "$minutes" "$seconds"
    else
        printf '%02ds' "$seconds"
    fi
}

timer_show_summary() {
    local step_id=""
    local label=""
    local duration=0

    echo
    echo "Tempos da instalação:"
    for step_id in "${TIMER_STEP_ORDER[@]}"; do
        label="${TIMER_STEP_LABELS[$step_id]}"
        duration="${TIMER_STEP_DURATIONS[$step_id]:-0}"
        printf '  %-28s %s\n' "$label:" "$(timer_format_duration "$duration")"
    done
    printf '  %-28s %s\n' "Total:" "$(timer_format_duration "$TIMER_TOTAL_DURATION")"

    log_info "Resumo de tempos da instalação:"
    for step_id in "${TIMER_STEP_ORDER[@]}"; do
        log_info "Timer resumo: ${TIMER_STEP_LABELS[$step_id]}=${TIMER_STEP_DURATIONS[$step_id]:-0}s."
    done
    log_info "Timer resumo: total=${TIMER_TOTAL_DURATION}s."
}
