#!/usr/bin/env bash
#
# Starts the selected model on OVMS for the Hermes + OVMS Local Workshop (Linux).
#
# Usage:
#   ./start-ovms-local-workshop.sh [--model NAME] [--wait-seconds N] [--port N] [--target-device Auto|GPU|CPU]
#
set -euo pipefail

MODEL=""
WAIT_SECONDS=2700
PORT=8000
TARGET_DEVICE="Auto"

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --target-device) TARGET_DEVICE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--model NAME] [--wait-seconds N] [--port N] [--target-device Auto|GPU|CPU]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || [ "$WAIT_SECONDS" -lt 30 ] || [ "$WAIT_SECONDS" -gt 10800 ]; then
    echo "--wait-seconds must be between 30 and 10800" >&2
    exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    echo "--port must be between 1024 and 65535" >&2
    exit 1
fi
case "$TARGET_DEVICE" in
    Auto|GPU|CPU) ;;
    *) echo "--target-device must be one of: Auto, GPU, CPU" >&2; exit 1 ;;
esac

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVMS_EXE="$WORKSHOP_ROOT/ovms/ovms"
if [ ! -x "$OVMS_EXE" ] && [ -x "$WORKSHOP_ROOT/ovms/bin/ovms" ]; then
    OVMS_EXE="$WORKSHOP_ROOT/ovms/bin/ovms"
fi
MODEL_REPOSITORY_PATH="$WORKSHOP_ROOT/models"
CACHE_DIRECTORY="$WORKSHOP_ROOT/.ovcache"
STATE_DIR="$WORKSHOP_ROOT/.state"
MODEL_STATE_PATH="$STATE_DIR/selected-model.json"
MODEL_CONFIG_PATH="$WORKSHOP_ROOT/model-config.json"
LOG_DIR="$WORKSHOP_ROOT/logs"
PID_FILE="$STATE_DIR/ovms-server.pid"
SERVER_INFO_FILE="$STATE_DIR/ovms-server.json"
MODELS_URL="http://127.0.0.1:$PORT/v1/models"

log_warn() { echo -e "\033[0;33mWARNING: $1\033[0m" >&2; }
log_ok() { echo -e "\033[0;32m[OK] $1\033[0m"; }

write_atomic_file() {
    local target="$1"
    local content="$2"
    local tmp="$target.tmp-$$"
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$target"
}

if [ ! -f "$MODEL_CONFIG_PATH" ]; then
    echo "Model configuration is missing: $MODEL_CONFIG_PATH" >&2
    exit 1
fi

if [ -z "$MODEL" ] && [ -f "$MODEL_STATE_PATH" ]; then
    MODEL="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('model',''))" "$MODEL_STATE_PATH" 2>/dev/null || true)"
fi
if [ -z "$MODEL" ]; then MODEL="qwen3.5-27b"; fi

if ! python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    configs = json.load(f)
sys.exit(0 if sys.argv[2] in configs else 1)
" "$MODEL_CONFIG_PATH" "$MODEL"; then
    AVAILABLE="$(python3 -c "import json,sys; print(', '.join(json.load(open(sys.argv[1])).keys()))" "$MODEL_CONFIG_PATH")"
    echo "Unsupported model '$MODEL'. Choose one of: $AVAILABLE" >&2
    exit 1
fi

read_json_field() {
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)[sys.argv[2]]
val = data[sys.argv[3]]
print(val if isinstance(val, str) else json.dumps(val))
" "$MODEL_CONFIG_PATH" "$MODEL" "$1"
}

SOURCE_MODEL="$(read_json_field SourceModel)"
TOOL_PARSER="$(read_json_field ToolParser)"
REASONING_PARSER="$(read_json_field ReasoningParser)"
MODEL_ALIAS="${SOURCE_MODEL##*/}"
mapfile -t EXTRA_ARGS < <(python3 -c "
import json
with open('$MODEL_CONFIG_PATH') as f:
    data = json.load(f)['$MODEL']
for item in data.get('ExtraArgs', []):
    print(item)
")

test_workshop_endpoint() {
    local models_json
    models_json="$(curl -fsS --max-time 10 "$MODELS_URL" 2>/dev/null || true)"
    [ -n "$models_json" ] || return 1
    python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    ids = [item.get('id') for item in data.get('data', [])]
    sys.exit(0 if sys.argv[2] in ids else 1)
except Exception:
    sys.exit(1)
" "$models_json" "$MODEL_ALIAS"
}

save_selected_model_state() {
    mkdir -p "$STATE_DIR"
    write_atomic_file "$MODEL_STATE_PATH" "$(python3 -c "
import json, datetime
print(json.dumps({'model': '$MODEL', 'source_model': '$SOURCE_MODEL', 'saved_at': datetime.datetime.now().astimezone().isoformat()}))
")"
}

if [ ! -x "$OVMS_EXE" ]; then
    echo "ovms is missing: $OVMS_EXE. Run install-ovms-local-workshop.sh first." >&2
    exit 1
fi

if [ "$TARGET_DEVICE" = "Auto" ]; then
    if command -v lspci >/dev/null 2>&1 && lspci | grep -qi "VGA.*Intel\|Display.*Intel"; then
        TARGET_DEVICE="GPU"
    else
        TARGET_DEVICE="CPU"
        log_warn "No Intel GPU was detected; starting OVMS on CPU."
    fi
fi

# A previous run that timed out (e.g. a slow model download) can leave ovms
# running in the background even after this script has exited. Clean up any
# such leftover before proceeding, unless it's actually serving already.
if ! test_workshop_endpoint; then
    for stale_pid in $(pgrep -f "^$OVMS_EXE" 2>/dev/null || true); do
        log_warn "Stopping a leftover ovms process (PID $stale_pid) from a previous run that never finished starting."
        kill -9 "$stale_pid" 2>/dev/null || true
    done
fi

if test_workshop_endpoint; then
    save_selected_model_state
    LISTENER_PID="$(ss -ltnp 2>/dev/null | awk -v port=":$PORT" '$4 ~ port {print $0}' | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
    if [ -n "$LISTENER_PID" ]; then
        write_atomic_file "$PID_FILE" "$LISTENER_PID"
    fi
    log_ok "$MODEL is already available at http://127.0.0.1:$PORT/v1"
    exit 0
fi

if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :$PORT )" 2>/dev/null | grep -q ":$PORT"; then
    echo "Port $PORT is already in use. Close that application and run this script again." >&2
    exit 1
fi

mkdir -p "$MODEL_REPOSITORY_PATH" "$CACHE_DIRECTORY" "$STATE_DIR" "$LOG_DIR"

# Hugging Face's newer "Xet" HTTP/2 CDN is more prone to mid-download stream resets
# on corporate/flaky networks than the classic download path. Disable it by default.
export HF_HUB_DISABLE_XET=1

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
STDOUT_LOG="$LOG_DIR/ovms-server-$TIMESTAMP.out.log"
STDERR_LOG="$LOG_DIR/ovms-server-$TIMESTAMP.err.log"

SERVER_ARGS=(
    --source_model "$SOURCE_MODEL"
    --model_repository_path "$MODEL_REPOSITORY_PATH"
    --rest_port "$PORT"
    --target_device "$TARGET_DEVICE"
    --task text_generation
    --cache_dir "$CACHE_DIRECTORY"
    --model_name "$MODEL_ALIAS"
    --tool_parser "$TOOL_PARSER"
    --reasoning_parser "$REASONING_PARSER"
    --log_level INFO
)
SERVER_ARGS+=("${EXTRA_ARGS[@]}")

echo "Starting $MODEL on OVMS (first run also downloads the model from Hugging Face)..."
save_selected_model_state

# The Linux OVMS release has no setupvars.sh (unlike the Windows zip); ovms
# resolves its bundled shared libraries (libtbb, libopencv_*, etc.) via
# LD_LIBRARY_PATH, and its bundled openvino/openvino_genai Python packages via
# PYTHONPATH -- without the latter, ovms silently exits right after Python
# interpreter init. Both are scoped to the child process only.
OVMS_LIB_DIR="$WORKSHOP_ROOT/ovms/lib"
OVMS_PYTHON_DIR="$OVMS_LIB_DIR/python"
nohup env \
    LD_LIBRARY_PATH="$OVMS_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    PYTHONPATH="$OVMS_PYTHON_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    "$OVMS_EXE" "${SERVER_ARGS[@]}" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
SERVER_PID=$!
disown
write_atomic_file "$PID_FILE" "$SERVER_PID"

python3 -c "
import json, datetime
print(json.dumps({
    'process_id': $SERVER_PID,
    'executable': '$OVMS_EXE',
    'model': '$MODEL',
    'source_model': '$SOURCE_MODEL',
    'alias': '$MODEL_ALIAS',
    'started_at': datetime.datetime.now().astimezone().isoformat(),
    'stdout_log': '$STDOUT_LOG',
    'stderr_log': '$STDERR_LOG',
}))
" > "$SERVER_INFO_FILE"

DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
SERVER_READY=false
STDOUT_LINES_SHOWN=0
STDERR_LINES_SHOWN=0

show_new_log_lines() {
    local log_path="$1"
    local -n lines_shown_ref="$2"
    [ -f "$log_path" ] || return 0
    local total_lines
    total_lines="$(wc -l < "$log_path" 2>/dev/null || echo 0)"
    if [ "$total_lines" -gt "$lines_shown_ref" ]; then
        tail -n "+$((lines_shown_ref + 1))" "$log_path"
        lines_shown_ref="$total_lines"
    fi
}

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    show_new_log_lines "$STDOUT_LOG" STDOUT_LINES_SHOWN
    show_new_log_lines "$STDERR_LOG" STDERR_LINES_SHOWN

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ovms exited before becoming ready." >&2
        echo "STDOUT (tail):" >&2
        tail -n 30 "$STDOUT_LOG" 2>/dev/null >&2 || true
        echo "STDERR (tail):" >&2
        tail -n 30 "$STDERR_LOG" 2>/dev/null >&2 || true
        exit 1
    fi

    if test_workshop_endpoint; then
        SERVER_READY=true
        log_ok "Local $MODEL endpoint is ready: http://127.0.0.1:$PORT/v1"
        log_ok "ovms process ID: $SERVER_PID"
        exit 0
    fi

    sleep 2
done

if [ "$SERVER_READY" = false ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    echo "Timed out waiting for $MODEL to become ready (model download can take a while on first run). Review: $STDERR_LOG" >&2
    exit 1
fi
