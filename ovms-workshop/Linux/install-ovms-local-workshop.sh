#!/usr/bin/env bash
#
# Hermes + OVMS Local Workshop -- Easy Installation (Linux)
#
# Usage:
#   ./install-ovms-local-workshop.sh [--model NAME] [--port N] [--wait-seconds N]
#                                     [--skip-hermes-install] [--do-not-start-server]
#
set -euo pipefail

MODEL=""
WAIT_SECONDS=2700
PORT=8000
SKIP_HERMES_INSTALL=false
DO_NOT_START_SERVER=false

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --skip-hermes-install) SKIP_HERMES_INSTALL=true; shift ;;
        --do-not-start-server) DO_NOT_START_SERVER=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--model NAME] [--port N] [--wait-seconds N] [--skip-hermes-install] [--do-not-start-server]"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="hermes-ovms-workshop-linux-x64-intel-v1.0.0"
INSTALL_ROOT="$HOME/OVMS-Local-Workshop/$PACKAGE_NAME"
LOG_DIR="$INSTALL_ROOT/logs"
OVMS_DIR="$INSTALL_ROOT/ovms"
OVMS_EXE="$OVMS_DIR/ovms"
STATE_DIR="$INSTALL_ROOT/.state"
MODEL_STATE_PATH="$STATE_DIR/selected-model.json"
MODEL_CONFIG_PATH="$SCRIPT_DIR/model-config.json"
OVMS_VERSION=""
OVMS_URL=""
OVMS_EXPECTED_SHA256=""
OVMS_TARBALL=""
OVMS_VERSION_PATH="$STATE_DIR/ovms-version.txt"
INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"
INSTALLER_PATH="/tmp/hermes-install-$$.sh"
TRANSCRIPT_PATH=""

log_step() {
    echo ""
    echo -e "\033[0;36m[$1/6] $2\033[0m"
}

log_ok() { echo -e "\033[0;32m[OK] $1\033[0m"; }
log_warn() { echo -e "\033[0;33mWARNING: $1\033[0m" >&2; }
log_err() { echo -e "\033[0;31m$1\033[0m" >&2; }

cleanup() {
    rm -f "$OVMS_TARBALL" "$INSTALLER_PATH"
}
trap cleanup EXIT

require_json_value() {
    # Model names can themselves contain dots (e.g. qwen3.5-27b), so model and
    # field are taken as separate args rather than a single dotted path.
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)[sys.argv[2]][sys.argv[3]]
print(data if isinstance(data, str) else json.dumps(data))
" "$1" "$2" "$3"
}

if [ ! -f "$MODEL_CONFIG_PATH" ]; then
    log_err "Model configuration is missing: $MODEL_CONFIG_PATH"
    exit 1
fi

SAVED_MODEL=""
if [ -z "$MODEL" ] && [ -f "$MODEL_STATE_PATH" ]; then
    SAVED_MODEL="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('model',''))" "$MODEL_STATE_PATH" 2>/dev/null || true)"
fi
if [ -z "$MODEL" ]; then
    MODEL="${SAVED_MODEL:-qwen3.8-27b}"
fi

if ! python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    configs = json.load(f)
sys.exit(0 if sys.argv[2] in configs else 1)
" "$MODEL_CONFIG_PATH" "$MODEL"; then
    AVAILABLE="$(python3 -c "import json,sys; print(', '.join(json.load(open(sys.argv[1])).keys()))" "$MODEL_CONFIG_PATH")"
    log_err "Unsupported model '$MODEL'. Choose one of: $AVAILABLE"
    exit 1
fi

SOURCE_MODEL="$(require_json_value "$MODEL_CONFIG_PATH" "$MODEL" "SourceModel")"
TOOL_PARSER="$(require_json_value "$MODEL_CONFIG_PATH" "$MODEL" "ToolParser")"
REASONING_PARSER="$(require_json_value "$MODEL_CONFIG_PATH" "$MODEL" "ReasoningParser")"
MODEL_ALIAS="${SOURCE_MODEL##*/}"

get_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

write_atomic_file() {
    local target="$1"
    local content="$2"
    local tmp="$target.tmp-$$"
    printf '%s' "$content" > "$tmp"
    mv -f "$tmp" "$target"
}

save_selected_model_state() {
    mkdir -p "$STATE_DIR"
    write_atomic_file "$MODEL_STATE_PATH" "$(python3 -c "
import json, datetime
print(json.dumps({'model': '$MODEL', 'source_model': '$SOURCE_MODEL', 'saved_at': datetime.datetime.now().astimezone().isoformat()}))
")"
}

test_free_disk_space() {
    local available_kb
    available_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
    local available_gb=$((available_kb / 1024 / 1024))
    local required_gb=40
    if [ "$available_gb" -lt "$required_gb" ]; then
        log_err "At least ${required_gb} GB of free space is required (currently ${available_gb} GB available)."
        exit 1
    fi
    echo "  - Free disk space: ${available_gb} GB"
}

test_uv_installed() {
    if command -v uv >/dev/null 2>&1; then
        echo "  - uv (astral-sh) found"
        return 0
    fi
    log_warn "uv was not found on PATH; installing via the official installer..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    if ! command -v uv >/dev/null 2>&1; then
        log_err "uv was installed but is not on PATH in this session. Open a new terminal and re-run setup."
        exit 1
    fi
    echo "  - uv installed"
}

invoke_download_with_retry() {
    local url="$1"
    local out_file="$2"
    local max_attempts=6
    local attempt
    for attempt in $(seq 1 "$max_attempts"); do
        if curl -fL --retry 0 --connect-timeout 20 --max-time 120 \
            -A "Linux-Local-Workshop-Installer/$OVMS_VERSION" \
            -o "$out_file" "$url"; then
            return 0
        fi
        rm -f "$out_file"
        if [ "$attempt" -eq "$max_attempts" ]; then
            log_err "Download failed after $max_attempts attempts: $url"
            exit 1
        fi
        local delay=$((5 * attempt))
        if [ "$delay" -gt 30 ]; then delay=30; fi
        log_warn "Download attempt $attempt of $max_attempts failed. Retrying in ${delay}s."
        sleep "$delay"
    done
}

resolve_ovms_release() {
    local release_location
    release_location="$(curl -sSIL --max-redirs 0 --connect-timeout 20 --max-time 60 \
        -A "Linux-Local-Workshop-Installer/latest" -o /dev/null -w '%{redirect_url}' \
        "https://github.com/openvinotoolkit/model_server/releases/latest" || true)"
    if [ -z "$release_location" ]; then
        log_err "Could not resolve the latest OVMS release from GitHub."
        exit 1
    fi
    local tag="${release_location##*/}"
    if [[ "$tag" != v[0-9]*.[0-9]*.[0-9]* ]]; then
        log_err "GitHub returned an unexpected latest OVMS release location: $release_location"
        exit 1
    fi
    OVMS_VERSION="${tag#v}"
    local asset_name="ovms_ubuntu24_${OVMS_VERSION}_python_on.tar.gz"
    OVMS_URL="https://github.com/openvinotoolkit/model_server/releases/download/v${OVMS_VERSION}/${asset_name}"
    local checksum_text
    checksum_text="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 30 \
        -A "Linux-Local-Workshop-Installer/$OVMS_VERSION" "${OVMS_URL}.sha256")" || {
        log_err "Could not retrieve the checksum for the latest OVMS archive."
        exit 1
    }
    OVMS_EXPECTED_SHA256="$(printf '%s' "$checksum_text" | awk 'match($0, /[[:xdigit:]]{64}/) {print substr($0, RSTART, 64); exit}')"
    if ! [[ "$OVMS_EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]]; then
        log_err "The latest OVMS release does not provide a valid SHA-256 checksum."
        exit 1
    fi
    OVMS_EXPECTED_SHA256="$(printf '%s' "$OVMS_EXPECTED_SHA256" | tr '[:upper:]' '[:lower:]')"
    OVMS_TARBALL="/tmp/ovms-${OVMS_VERSION}-$$.tar.gz"
}

test_external_endpoint() {
    local name="$1"
    local url="$2"
    if curl -fsSIL --connect-timeout 10 --max-time 20 -A "Linux-Local-Workshop-Installer/$OVMS_VERSION" "$url" >/dev/null 2>&1; then
        echo "  - ${name}: reachable"
        return 0
    fi
    log_warn "$name could not be reached before download."
    return 1
}

test_workshop_network() {
    local failed=0
    test_external_endpoint "GitHub release host" "$OVMS_URL" || failed=1
    test_external_endpoint "Hermes installer host" "$INSTALLER_URL" || failed=1
    test_external_endpoint "Hugging Face model host" "https://huggingface.co/$SOURCE_MODEL" || failed=1
    if [ "$failed" -ne 0 ]; then
        log_warn "One or more external endpoints failed the preflight. The installer will continue and retry downloads, but a proxy or firewall rule may need attention."
    fi
}

find_hermes_launcher() {
    # Runs inside a command substitution subshell, so 'exit' here would only
    # kill the subshell -- return non-zero instead and let the caller exit.
    for candidate in "$HOME/.local/bin/hermes" "/usr/local/bin/hermes"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    if command -v hermes >/dev/null 2>&1; then
        command -v hermes
        return 0
    fi
    return 1
}

confirm_model_download() {
    if [ ! -t 0 ]; then
        return 0
    fi
    echo ""
    echo "Model $MODEL ($SOURCE_MODEL) has not finished downloading yet."
    echo "Starting the server now will begin a large (multi-GB) download from Hugging Face."
    read -r -p "Start the server and begin the model download now? [Y/n] " response
    [ -z "$response" ] || [[ "$response" =~ ^[Yy] ]]
}

main() {
    if [ "$(uname -s)" != "Linux" ]; then
        log_err "This workshop package supports Linux only."
        exit 1
    fi
    if [ "$(uname -m)" != "x86_64" ]; then
        log_err "A 64-bit x86_64 Linux operating system is required."
        exit 1
    fi

    mkdir -p "$INSTALL_ROOT" "$LOG_DIR"
    TRANSCRIPT_PATH="$LOG_DIR/easy-install-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$TRANSCRIPT_PATH") 2>&1

    # Start/Stop scripts must live in $INSTALL_ROOT so their own script-relative
    # paths (ovms/ovms, models/, .ovcache/, .state/) resolve to the real install location
    for script_name in start-ovms-local-workshop.sh stop-ovms-local-workshop.sh model-config.json; do
        source_file="$SCRIPT_DIR/$script_name"
        dest_file="$INSTALL_ROOT/$script_name"
        if [ "$(readlink -f "$source_file")" != "$(readlink -f "$dest_file" 2>/dev/null || echo "")" ]; then
            cp -f "$source_file" "$dest_file"
            chmod +x "$dest_file" 2>/dev/null || true
        fi
    done

    resolve_ovms_release

    echo "=============================================================="
    echo " HERMES + OVMS - EASY WORKSHOP SETUP"
    echo "=============================================================="
    echo "Model: $MODEL ($SOURCE_MODEL)"
    echo "Installation folder: $INSTALL_ROOT"
    echo "Log file: $TRANSCRIPT_PATH"

    log_step 1 "Verify this computer"
    test_free_disk_space
    test_uv_installed
    if command -v lspci >/dev/null 2>&1 && lspci | grep -qi "VGA.*Intel\|Display.*Intel"; then
        echo "  - Intel GPU detected"
    else
        log_warn "No Intel GPU was detected. OVMS will still run, but on CPU only (slower)."
    fi

    log_step 2 "Download and extract OVMS $OVMS_VERSION"
    test_workshop_network
    INSTALLED_OVMS_VERSION=""
    if [ -f "$OVMS_VERSION_PATH" ]; then
        INSTALLED_OVMS_VERSION="$(cat "$OVMS_VERSION_PATH")"
    fi
    if [ -x "$OVMS_EXE" ] && [ "$INSTALLED_OVMS_VERSION" = "$OVMS_VERSION" ]; then
        log_ok "OVMS is already installed at $OVMS_EXE"
    else
        if [ -x "$OVMS_EXE" ]; then
            echo "[INFO] Updating OVMS from ${INSTALLED_OVMS_VERSION:-unknown} to $OVMS_VERSION."
        fi
        invoke_download_with_retry "$OVMS_URL" "$OVMS_TARBALL"
        ACTUAL_SHA256="$(get_sha256 "$OVMS_TARBALL")"
        if [ "$ACTUAL_SHA256" != "$OVMS_EXPECTED_SHA256" ]; then
            rm -f "$OVMS_TARBALL"
            log_err "OVMS download failed SHA-256 verification. Expected $OVMS_EXPECTED_SHA256, got $ACTUAL_SHA256."
            exit 1
        fi
        EXTRACT_ROOT="$INSTALL_ROOT/.ovms-extract-$$"
        STAGED_OVMS_DIR="$EXTRACT_ROOT/ovms"
        PREVIOUS_OVMS_DIR="$INSTALL_ROOT/ovms.previous-$$"
        rm -rf "$EXTRACT_ROOT"
        mkdir -p "$EXTRACT_ROOT"
        if ! tar xzf "$OVMS_TARBALL" -C "$EXTRACT_ROOT"; then
            rm -rf "$EXTRACT_ROOT"
            log_err "Failed to extract the OVMS archive."
            exit 1
        fi
        if [ ! -x "$STAGED_OVMS_DIR/bin/ovms" ] && [ ! -x "$STAGED_OVMS_DIR/ovms" ]; then
            rm -rf "$EXTRACT_ROOT"
            log_err "OVMS extraction did not produce an ovms binary under $STAGED_OVMS_DIR."
            exit 1
        fi
        if [ -d "$OVMS_DIR" ]; then
            mv "$OVMS_DIR" "$PREVIOUS_OVMS_DIR"
        fi
        mv "$STAGED_OVMS_DIR" "$OVMS_DIR"
        rm -rf "$PREVIOUS_OVMS_DIR" "$EXTRACT_ROOT"
        rm -f "$OVMS_TARBALL"
        write_atomic_file "$OVMS_VERSION_PATH" "$OVMS_VERSION"
        log_ok "OVMS $OVMS_VERSION extracted."
    fi
    # Ubuntu OVMS archives place the binary under ovms/bin/ovms; normalize OVMS_EXE accordingly.
    if [ ! -x "$OVMS_DIR/ovms" ] && [ -x "$OVMS_DIR/bin/ovms" ]; then
        OVMS_EXE="$OVMS_DIR/bin/ovms"
    fi

    log_step 3 "Install and verify Hermes Agent"
    if [ "$SKIP_HERMES_INSTALL" = false ]; then
        invoke_download_with_retry "$INSTALLER_URL" "$INSTALLER_PATH"
        if [ "$(stat -c%s "$INSTALLER_PATH" 2>/dev/null || stat -f%z "$INSTALLER_PATH")" -lt 10000 ]; then
            log_err "The downloaded Hermes installer is unexpectedly small."
            exit 1
        fi
        chmod +x "$INSTALLER_PATH"
        bash "$INSTALLER_PATH" --skip-setup --non-interactive
    else
        echo "Hermes installation was skipped by request. Existing installation will be validated."
    fi

    export PATH="$HOME/.local/bin:$PATH"
    if ! HERMES_LAUNCHER="$(find_hermes_launcher)"; then
        log_err "Hermes launcher was not found."
        exit 1
    fi
    HERMES_VERSION="$("$HERMES_LAUNCHER" --version)"
    echo "$HERMES_VERSION"
    log_ok "Hermes Agent is installed."

    log_step 4 "Start $MODEL on OVMS (model downloads automatically on first run)"
    START_SCRIPT="$INSTALL_ROOT/start-ovms-local-workshop.sh"
    MODEL_DIR="$INSTALL_ROOT/models/$MODEL_ALIAS"
    MODEL_ALREADY_DOWNLOADED=false
    if [ -d "$MODEL_DIR" ] && [ -n "$(find "$MODEL_DIR" -type f -print -quit 2>/dev/null)" ]; then
        MODEL_ALREADY_DOWNLOADED=true
    fi
    SKIP_SERVER_START="$DO_NOT_START_SERVER"
    if [ "$SKIP_SERVER_START" = false ] && [ "$MODEL_ALREADY_DOWNLOADED" = false ] && ! confirm_model_download; then
        echo "Model download declined. Start it later with start-ovms-local-workshop.sh."
        SKIP_SERVER_START=true
    fi
    if [ "$SKIP_SERVER_START" = false ]; then
        bash "$START_SCRIPT" --model "$MODEL" --wait-seconds "$WAIT_SECONDS" --port "$PORT"
    else
        save_selected_model_state
        echo "Server start was skipped by request."
    fi

    log_step 5 "Test the local OpenAI-compatible API"
    if [ "$SKIP_SERVER_START" = true ]; then
        echo "API test skipped because the server was not started."
    else
        CHAT_RESPONSE="$(curl -fsS --max-time 180 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$(python3 -c "
import json
print(json.dumps({'model': '$MODEL_ALIAS', 'messages': [{'role': 'user', 'content': 'In one short sentence, confirm you are working.'}], 'temperature': 0, 'max_tokens': 400}))
")" 2>/dev/null || true)"
        CHAT_CONTENT="$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data['choices'][0]['message']['content'])
except Exception:
    print('')
" "$CHAT_RESPONSE" 2>/dev/null || true)"
        if [ -z "$CHAT_CONTENT" ]; then
            log_warn "The API responded, but no answer text came back yet. This is informational only; continuing setup."
        else
            log_ok "Local chat completion returned: $CHAT_CONTENT"
        fi
    fi

    log_step 6 "Connect Hermes to the local OVMS endpoint"
    HERMES_CONFIG="$HOME/.hermes/config.yaml"
    if [ -f "$HERMES_CONFIG" ]; then
        CONFIG_BACKUP="$HERMES_CONFIG.before-easy-workshop-$(date +%Y%m%d-%H%M%S).bak"
        cp -f "$HERMES_CONFIG" "$CONFIG_BACKUP"
        echo "Existing Hermes configuration backed up to: $CONFIG_BACKUP"
    fi

    "$HERMES_LAUNCHER" config set model.provider custom
    "$HERMES_LAUNCHER" config set model.base_url "http://127.0.0.1:$PORT/v1"
    "$HERMES_LAUNCHER" config set model.default "$MODEL_ALIAS"

    PROVIDER_VALUE="$("$HERMES_LAUNCHER" config get model.provider)"
    BASE_URL_VALUE="$("$HERMES_LAUNCHER" config get model.base_url)"
    MODEL_VALUE="$("$HERMES_LAUNCHER" config get model.default)"
    if [[ "$PROVIDER_VALUE" != *custom* ]] || [[ "$BASE_URL_VALUE" != *"http://127.0.0.1:$PORT/v1"* ]] || [[ "$MODEL_VALUE" != *"$MODEL_ALIAS"* ]]; then
        log_err "Hermes configuration verification failed.
Provider: $PROVIDER_VALUE
Base URL: $BASE_URL_VALUE
Model: $MODEL_VALUE"
        exit 1
    fi

    READY_FILE="$INSTALL_ROOT/WORKSHOP_READY.txt"
    {
        echo "WORKSHOP READY"
        echo "Prepared: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "Hermes: $HERMES_VERSION"
        echo "Model: $MODEL ($SOURCE_MODEL)"
        echo "Endpoint: http://127.0.0.1:$PORT/v1"
    } > "$READY_FILE"

    echo ""
    echo -e "\033[0;32m==============================================================\033[0m"
    echo -e "\033[0;32m WORKSHOP READY\033[0m"
    echo -e "\033[0;32m==============================================================\033[0m"
    echo "Local model: $MODEL ($SOURCE_MODEL)"
    echo "Endpoint: http://127.0.0.1:$PORT/v1"
    echo ""
    echo -e "\033[0;33mStart Hermes now by entering:\033[0m"
    echo "  hermes"
}

if ! main; then
    echo ""
    echo -e "\033[0;31mSETUP STOPPED\033[0m"
    echo -e "\033[0;33mCorrect the reported prerequisite or network issue, then run the same setup again.\033[0m"
    exit 1
fi
