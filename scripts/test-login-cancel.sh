#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
TEST_STATE_DIR="$(mktemp -d /tmp/cappy-login-test.XXXXXX)"
SERVER_LOG="$(mktemp /tmp/cappy-login-server.XXXXXX.log)"
SERVER_PID=""
LOGIN_PIDS=()

cleanup() {
    for pid in $LOGIN_PIDS; do
        kill "$pid" 2>/dev/null || true
    done
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    [[ "$TEST_STATE_DIR" == /tmp/cappy-login-test.* ]] && /bin/rm -r -- "$TEST_STATE_DIR"
    [[ "$SERVER_LOG" == /tmp/cappy-login-server.*.log ]] && /bin/rm -- "$SERVER_LOG"
}
trap cleanup EXIT

rpc() {
    local method="$1"
    local params="$2"
    jq -nc --arg method "$method" --argjson params "$params" \
        '{jsonrpc:"2.0",id:"test",method:$method,params:$params}' \
        | nc -U "$TEST_STATE_DIR/appserver.sock"
}

CAPPY_STATE_DIR="$TEST_STATE_DIR" \
CAPPY_ADAPTER_DIR="$REPO_DIR/.build/debug" \
CAPPY_CLAUDE_PATH="/usr/bin/yes" \
    "$REPO_DIR/.build/debug/quota-appserver" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in {1..40}; do
    [[ -S "$TEST_STATE_DIR/appserver.sock" ]] && break
    sleep 0.05
done
[[ -S "$TEST_STATE_DIR/appserver.sock" ]]

profile_response="$(rpc profile.add '{"providerID":"anthropic-claude","label":"Cancellation test"}')"
profile_id="$(jq -er '.result.id' <<<"$profile_response")"

first_response="$(rpc profile.login "{\"profileID\":\"$profile_id\"}")"
job_id="$(jq -er '.result.id' <<<"$first_response")"
second_response="$(rpc profile.login "{\"profileID\":\"$profile_id\"}")"
[[ "$(jq -er '.result.id' <<<"$second_response")" == "$job_id" ]]

for _ in {1..40}; do
    script_pid="$(pgrep -P "$SERVER_PID" -f '/usr/bin/script.*\/usr/bin/yes auth login --claudeai' | head -n 1 || true)"
    [[ -n "$script_pid" ]] && break
    sleep 0.05
done
[[ -n "${script_pid:-}" ]]
LOGIN_PIDS+=("$script_pid")

for _ in {1..40}; do
    provider_pid="$(pgrep -P "$script_pid" | head -n 1 || true)"
    [[ -n "$provider_pid" ]] && break
    sleep 0.05
done
[[ -n "${provider_pid:-}" ]]
LOGIN_PIDS+=("$provider_pid")

cancel_response="$(rpc login.cancel "{\"jobID\":\"$job_id\"}")"
[[ "$(jq -er '.result.state' <<<"$cancel_response")" == "cancelled" ]]

for _ in {1..40}; do
    if ! kill -0 "$script_pid" 2>/dev/null && ! kill -0 "$provider_pid" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
! kill -0 "$script_pid" 2>/dev/null
! kill -0 "$provider_pid" 2>/dev/null

status_response="$(rpc login.status "{\"jobID\":\"$job_id\"}")"
[[ "$(jq -er '.result.state' <<<"$status_response")" == "cancelled" ]]

print "login-cancel: all checks passed"
