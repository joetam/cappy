#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
TEST_STATE_DIR="$(mktemp -d /tmp/cappy-preserve-test.XXXXXX)"
TEST_ADAPTER_DIR="$(mktemp -d /tmp/cappy-preserve-adapters.XXXXXX)"
SERVER_LOG="$(mktemp /tmp/cappy-preserve-server.XXXXXX)"
SERVER_PID=""

cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )) && [[ -f "$SERVER_LOG" ]]; then
        print -u2 "account-preservation: server log follows"
        sed -n '1,160p' "$SERVER_LOG" >&2
    fi
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    [[ "$TEST_STATE_DIR" == /tmp/cappy-preserve-test.* ]] && /bin/rm -r -- "$TEST_STATE_DIR"
    [[ "$TEST_ADAPTER_DIR" == /tmp/cappy-preserve-adapters.* ]] && /bin/rm -r -- "$TEST_ADAPTER_DIR"
    [[ "$SERVER_LOG" == /tmp/cappy-preserve-server.* ]] && /bin/rm -- "$SERVER_LOG"
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
    print -u2 "account-preservation: login job did not finish"
    exit 1
}

FAKE_ADAPTER="$TEST_ADAPTER_DIR/quota-adapter-codex"
cat >"$FAKE_ADAPTER" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail
request="$(<&0)"
operation="$(jq -r '.operation' <<<"$request")"
profile_id="$(jq -r '.profile.id // ""' <<<"$request")"
profile_label="$(jq -r '.profile.label // ""' <<<"$request")"
provider_id="openai-codex"

case "$operation" in
    describe)
        jq -nc --arg provider "$provider_id" \
            '{protocolVersion:1,ok:true,provider:{id:$provider,displayName:"Codex"},warnings:[]}'
        ;;
    refresh)
        email="current@example.com"
        [[ "$profile_label" == "Wrong account" ]] && email="wrong@example.com"
        jq -nc \
            --arg profile "$profile_id" \
            --arg label "$profile_label" \
            --arg provider "$provider_id" \
            --arg email "$email" \
            '{
                protocolVersion:1,
                ok:true,
                snapshot:{
                    contractVersion:1,
                    profileID:$profile,
                    provider:{id:$provider,displayName:"Codex"},
                    profileLabel:$label,
                    authenticationState:"authenticated",
                    identity:{email:$email},
                    meters:[],
                    observedAt:"2026-08-08T12:00:00Z",
                    freshness:"fresh"
                },
                warnings:[]
            }'
        ;;
    prepareLogin)
        jq -nc '{
            protocolVersion:1,
            ok:true,
            loginCommand:{executable:"/usr/bin/true",arguments:[],environment:{},requiresPTY:false},
            warnings:[]
        }'
        ;;
    configure|removeManagedCredentials)
        jq -nc '{protocolVersion:1,ok:true,warnings:[]}'
        ;;
esac
SCRIPT
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

refresh_response="$(rpc refresh.profile '{"profileID":"codex-default"}')"
[[ "$(jq -er '.result.identity.email' <<<"$refresh_response")" == "current@example.com" ]]

login_response="$(rpc profile.login '{"profileID":"codex-default"}')"
[[ "$(jq -er '.error.message' <<<"$login_response")" == *"detected automatically"* ]]
remove_response="$(rpc profile.remove '{"profileID":"codex-default"}')"
[[ "$(jq -er '.error.message' <<<"$remove_response")" == *"cannot be removed"* ]]

switched_response="$(rpc profile.enroll '{
    "providerID":"openai-codex",
    "label":"Current",
    "sourceProfileID":"codex-default",
    "expectedSourceEmail":"someone-else@example.com"
}')"
[[ "$(jq -er '.error.message' <<<"$switched_response")" == *"account changed"* ]]

preserve_response="$(rpc profile.enroll '{
    "providerID":"openai-codex",
    "label":"Codex",
    "sourceProfileID":"codex-default",
    "expectedSourceEmail":"current@example.com"
}')"
preserve_job="$(jq -er '.result.id' <<<"$preserve_response")"
preserve_status="$(wait_for_job "$preserve_job")"
[[ "$(jq -er '.result.state' <<<"$preserve_status")" == "succeeded" ]]
[[ "$(jq -er '.result.message' <<<"$preserve_status")" == *"Kept Codex"* ]]

profiles_response="$(rpc profile.list '{}')"
[[ "$(jq '[.result[] | select(.isManaged == true)] | length' <<<"$profiles_response")" == "1" ]]
[[ "$(jq '[.result[] | select(.id == "codex-default" and .isDefault == true)] | length' <<<"$profiles_response")" == "1" ]]

duplicate_response="$(rpc profile.enroll '{
    "providerID":"openai-codex",
    "label":"Duplicate",
    "sourceProfileID":"codex-default",
    "expectedSourceEmail":"current@example.com"
}')"
duplicate_job="$(jq -er '.result.id' <<<"$duplicate_response")"
duplicate_status="$(wait_for_job "$duplicate_job")"
[[ "$(jq -er '.result.state' <<<"$duplicate_status")" == "failed" ]]
[[ "$(jq -er '.result.message' <<<"$duplicate_status")" == *"already tracked"* ]]

wrong_response="$(rpc profile.enroll '{
    "providerID":"openai-codex",
    "label":"Wrong account",
    "sourceProfileID":"codex-default",
    "expectedSourceEmail":"current@example.com"
}')"
wrong_job="$(jq -er '.result.id' <<<"$wrong_response")"
wrong_status="$(wait_for_job "$wrong_job")"
[[ "$(jq -er '.result.state' <<<"$wrong_status")" == "failed" ]]
[[ "$(jq -er '.result.message' <<<"$wrong_status")" == *"different account"* ]]

final_profiles="$(rpc profile.list '{}')"
[[ "$(jq '[.result[] | select(.isManaged == true)] | length' <<<"$final_profiles")" == "1" ]]

print "account-preservation: all checks passed"
