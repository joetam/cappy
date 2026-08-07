#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
TEST_STATE_DIR="$(mktemp -d /tmp/cappy-reorder-test.XXXXXX)"
TEST_ADAPTER_DIR="$(mktemp -d /tmp/cappy-reorder-adapters.XXXXXX)"
SERVER_LOG="$(mktemp /tmp/cappy-reorder-server.XXXXXX.log)"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    [[ "$TEST_STATE_DIR" == /tmp/cappy-reorder-test.* ]] && /bin/rm -r -- "$TEST_STATE_DIR"
    [[ "$TEST_ADAPTER_DIR" == /tmp/cappy-reorder-adapters.* ]] && /bin/rm -r -- "$TEST_ADAPTER_DIR"
    [[ "$SERVER_LOG" == /tmp/cappy-reorder-server.*.log ]] && /bin/rm -- "$SERVER_LOG"
}
trap cleanup EXIT

start_server() {
    CAPPY_STATE_DIR="$TEST_STATE_DIR" CAPPY_ADAPTER_DIR="$TEST_ADAPTER_DIR" \
        "$REPO_DIR/.build/debug/quota-appserver" >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    for _ in {1..40}; do
        [[ -S "$TEST_STATE_DIR/appserver.sock" ]] && return
        sleep 0.05
    done
    print -u2 "quota-reorder-selftest: app server did not start"
    exit 1
}

stop_server() {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    [[ -S "$TEST_STATE_DIR/appserver.sock" ]] && /bin/rm -- "$TEST_STATE_DIR/appserver.sock"
}

quota() {
    CAPPY_STATE_DIR="$TEST_STATE_DIR" CAPPY_ADAPTER_DIR="$TEST_ADAPTER_DIR" \
        "$REPO_DIR/.build/debug/quota" "$@"
}

first_profile_id() {
    quota profiles | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -n 1
}

start_server
[[ "$(first_profile_id)" == "codex-default" ]]

if invalid_output="$(quota reorder codex-default 2>&1)"; then
    print -u2 "quota-reorder-selftest: partial order was accepted"
    exit 1
fi
[[ "$invalid_output" == *"every tracked profile exactly once"* ]]
[[ "$(first_profile_id)" == "codex-default" ]]

quota reorder claude-default codex-default >/dev/null
[[ "$(first_profile_id)" == "claude-default" ]]

stop_server
start_server
[[ "$(first_profile_id)" == "claude-default" ]]

print "quota-reorder-selftest: all checks passed"
