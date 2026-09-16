#!/usr/bin/env bash
#
# Stops the OVMS server started by start-ovms-local-workshop.sh (Linux).
#
# Usage:
#   ./stop-ovms-local-workshop.sh [--port N]
#
set -euo pipefail

PORT=8000
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 [--port N]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

WORKSHOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_EXE="$WORKSHOP_ROOT/ovms/ovms"
if [ ! -x "$EXPECTED_EXE" ] && [ -x "$WORKSHOP_ROOT/ovms/bin/ovms" ]; then
    EXPECTED_EXE="$WORKSHOP_ROOT/ovms/bin/ovms"
fi
PID_FILE="$WORKSHOP_ROOT/.state/ovms-server.pid"
SERVER_INFO_FILE="$WORKSHOP_ROOT/.state/ovms-server.json"

is_expected_server_process() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    local exe_path
    exe_path="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [ -n "$exe_path" ] && [ "$exe_path" = "$(readlink -f "$EXPECTED_EXE")" ]
}

SERVER_PID=""
if [ -f "$PID_FILE" ]; then
    CANDIDATE_PID="$(cat "$PID_FILE" | tr -d '[:space:]')"
    if is_expected_server_process "$CANDIDATE_PID"; then
        SERVER_PID="$CANDIDATE_PID"
    fi
fi

if [ -z "$SERVER_PID" ] && command -v ss >/dev/null 2>&1; then
    LISTENER_PID="$(ss -ltnp 2>/dev/null | awk -v port=":$PORT" '$4 ~ port' | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
    if is_expected_server_process "$LISTENER_PID"; then
        SERVER_PID="$LISTENER_PID"
    fi
fi

if [ -z "$SERVER_PID" ]; then
    rm -f "$PID_FILE" "$SERVER_INFO_FILE"
    echo "No running ovms belonging to this workshop package was found."
    exit 0
fi

kill "$SERVER_PID"
for _ in $(seq 1 20); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "OVMS process $SERVER_PID did not exit after 10 seconds." >&2
    exit 1
fi
sleep 1
rm -f "$PID_FILE" "$SERVER_INFO_FILE"
echo -e "\033[0;32m[OK] Workshop ovms process $SERVER_PID stopped.\033[0m"
