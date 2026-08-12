#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
TEST_STATE_DIR="$(mktemp -d /tmp/cappy-naming-test.XXXXXX)"
TEST_ADAPTER_DIR="$(mktemp -d /tmp/cappy-naming-adapters.XXXXXX)"
SERVER_LOG="$(mktemp /tmp/cappy-naming-server.XXXXXX)"
SERVER_PID=""

cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )) && [[ -f "$SERVER_LOG" ]]; then
        print -u2 "profile-naming: server log follows"
        sed -n '1,160p' "$SERVER_LOG" >&2
    fi
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    [[ "$TEST_STATE_DIR" == /tmp/cappy-naming-test.* ]] && /bin/rm -r -- "$TEST_STATE_DIR"
    [[ "$TEST_ADAPTER_DIR" == /tmp/cappy-naming-adapters.* ]] && /bin/rm -r -- "$TEST_ADAPTER_DIR"
    [[ "$SERVER_LOG" == /tmp/cappy-naming-server.* ]] && /bin/rm -- "$SERVER_LOG"
    return $exit_code
}
trap cleanup EXIT

rpc() {
    local method="$1"
    local params="$2"
    jq -nc --arg method "$method" --argjson params "$params" \
        '{jsonrpc:"2.0",id:"test",method:$method,params:$params}' \
        | nc -U "$TEST_STATE_DIR/appserver.sock"
}

wait_for_job() {
    local job_id="$1"
    local response=""
    for _ in {1..80}; do
        response="$(rpc login.status "{\"jobID\":\"$job_id\"}")"
        case "$(jq -er '.result.state' <<<"$response")" in
            succeeded|failed|cancelled) print -r -- "$response"; return ;;
        esac
        sleep 0.05
    done
    print -u2 "profile-naming: login job did not finish"
    exit 1
}

FAKE_ADAPTER="$TEST_ADAPTER_DIR/quota-adapter-codex"
cp "$REPO_DIR/scripts/fixtures/quota-adapter-codex-naming" "$FAKE_ADAPTER"
chmod 0700 "$FAKE_ADAPTER"

CAPPY_STATE_DIR="$TEST_STATE_DIR" \
CAPPY_ADAPTER_DIR="$TEST_ADAPTER_DIR" \
    "$REPO_DIR/.build/debug/quota-appserver" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in {1..40}; do
    [[ -S "$TEST_STATE_DIR/appserver.sock" ]] && break
    sleep 0.05
done
[[ -S "$TEST_STATE_DIR/appserver.sock" ]]

explicit_response="$(rpc profile.enroll '{"providerID":"openai-codex","label":"Work"}')"
explicit_job="$(jq -er '.result.id' <<<"$explicit_response")"
explicit_status="$(wait_for_job "$explicit_job")"
[[ "$(jq -er '.result.state' <<<"$explicit_status")" == "succeeded" ]]
explicit_profile_id="$(jq -er '.result.profileID' <<<"$explicit_status")"
[[ "$(jq -er '.result.message' <<<"$explicit_status")" == *"Connected Work through Cappy"* ]]

rpc profile.add '{"providerID":"openai-codex","label":"auto@example.com"}' >/dev/null
rpc profile.add '{"providerID":"openai-codex","label":"auto@example.com (2)"}' >/dev/null

automatic_response_one="$(rpc profile.enroll '{"providerID":"openai-codex"}')"
automatic_response_two="$(rpc profile.enroll '{"providerID":"openai-codex"}')"
automatic_job_one="$(jq -er '.result.id' <<<"$automatic_response_one")"
automatic_job_two="$(jq -er '.result.id' <<<"$automatic_response_two")"
automatic_status_one="$(wait_for_job "$automatic_job_one")"
automatic_status_two="$(wait_for_job "$automatic_job_two")"
[[ "$(jq -er '.result.state' <<<"$automatic_status_one")" == "succeeded" ]]
[[ "$(jq -er '.result.state' <<<"$automatic_status_two")" == "succeeded" ]]

automatic_profile_id="$(jq -er '.result.profileID' <<<"$automatic_status_one")"
profiles_response="$(rpc profile.list '{}')"
automatic_labels="$(
    jq -r '[.result[] | select(.providerID == "openai-codex" and (.label | startswith("auto@example.com"))) | .label] | sort | join("|")' \
        <<<"$profiles_response"
)"
[[ "$automatic_labels" == "auto@example.com|auto@example.com (2)|auto@example.com (3)|auto@example.com (4)" ]]

snapshots_response="$(rpc snapshot.list '{}')"
automatic_profile_label="$(jq -er --arg id "$automatic_profile_id" '.result[] | select(.profileID == $id) | .profileLabel' <<<"$snapshots_response")"
[[ "$automatic_profile_label" == "auto@example.com (3)" || "$automatic_profile_label" == "auto@example.com (4)" ]]

rename_response="$(rpc profile.rename "{\"profileID\":\"$automatic_profile_id\",\"label\":\"Personal\"}")"
[[ "$(jq -er '.result.label' <<<"$rename_response")" == "Personal" ]]
renamed_snapshot="$(rpc snapshot.list '{}')"
[[ "$(jq -er --arg id "$automatic_profile_id" '.result[] | select(.profileID == $id) | .profileLabel' <<<"$renamed_snapshot")" == "Personal" ]]

duplicate_rename="$(rpc profile.rename "{\"profileID\":\"$automatic_profile_id\",\"label\":\"Work\"}")"
[[ "$(jq -er '.error.message' <<<"$duplicate_rename")" == *"already exists for this provider"* ]]
default_rename="$(rpc profile.rename '{"profileID":"codex-default","label":"Renamed default"}')"
[[ "$(jq -er '.error.message' <<<"$default_rename")" == *"Only connections through Cappy"* ]]

rpc profile.add '{"providerID":"openai-codex","label":"Codex account"}' >/dev/null
rpc profile.add '{"providerID":"openai-codex","label":"Codex account (2)"}' >/dev/null
touch "$TEST_STATE_DIR/omit-email"
fallback_response="$(rpc profile.enroll '{"providerID":"openai-codex"}')"
fallback_job="$(jq -er '.result.id' <<<"$fallback_response")"
fallback_status="$(wait_for_job "$fallback_job")"
[[ "$(jq -er '.result.state' <<<"$fallback_status")" == "succeeded" ]]
[[ "$(jq -er '.result.message' <<<"$fallback_status")" == *"Connected Codex account (3) through Cappy"* ]]

[[ -n "$explicit_profile_id" ]]
print "profile-naming: all checks passed"
