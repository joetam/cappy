#!/bin/zsh
set -euo pipefail

REPO_DIR="${0:A:h:h}"
ADAPTER="$REPO_DIR/.build/debug/quota-adapter-codex"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

FAKE_CODEX="$TEST_DIR/codex"
cat > "$FAKE_CODEX" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

[[ "${1:-}" == "app-server" ]]
IFS= read -r initialize
[[ "$initialize" == *'"method":"initialize"'* ]]

# A conforming client waits here. The previous Cappy adapter had already
# queued all remaining requests before initialization was acknowledged.
if IFS= read -r -t 0.2 early_request; then
    echo '{"id":0,"error":{"message":"request arrived before initialization completed"}}'
    exit 0
fi

echo '{"id":0,"result":{"serverInfo":{"name":"fake-codex"}}}'
IFS= read -r initialized
IFS= read -r account_request
[[ "$initialized" == *'"method":"initialized"'* ]]
[[ "$account_request" == *'"method":"account/read"'* ]]
[[ "$account_request" == *'"refreshToken":false'* ]]

echo '{"id":1,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
IFS= read -r limits_request
[[ "$limits_request" == *'"method":"account/rateLimits/read"'* ]]

sleep 0.1
echo '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000}}}}}'
SCRIPT
chmod 0700 "$FAKE_CODEX"

EXPIRED_CODEX="$TEST_DIR/codex-expired"
cat > "$EXPIRED_CODEX" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

[[ "${1:-}" == "app-server" ]]
IFS= read -r initialize
echo '{"id":0,"result":{"serverInfo":{"name":"fake-codex"}}}'
IFS= read -r initialized
IFS= read -r account_request
[[ "$account_request" == *'"refreshToken":false'* ]]
echo '{"id":1,"result":{"account":{"type":"chatgpt","email":"expired@example.com","planType":"prolite"},"requiresOpenaiAuth":true}}'
IFS= read -r limits_request
echo '{"id":2,"error":{"code":-32603,"message":"failed to fetch codex rate limits: 401 Unauthorized; token_expired"}}'
IFS= read -r refresh_request
[[ "$refresh_request" == *'"id":3'* ]]
[[ "$refresh_request" == *'"refreshToken":true'* ]]
echo '{"id":3,"error":{"code":-32603,"message":"failed to refresh token: 401 Unauthorized; token_expired"}}'
SCRIPT
chmod 0700 "$EXPIRED_CODEX"

RECOVERED_CODEX="$TEST_DIR/codex-recovered"
cat > "$RECOVERED_CODEX" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

[[ "${1:-}" == "app-server" ]]
IFS= read -r initialize
echo '{"id":0,"result":{"serverInfo":{"name":"fake-codex"}}}'
IFS= read -r initialized
IFS= read -r account_request
[[ "$account_request" == *'"refreshToken":false'* ]]
echo '{"id":1,"result":{"account":{"type":"chatgpt","email":"recovered@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
IFS= read -r limits_request
echo '{"id":2,"error":{"code":-32603,"message":"failed to fetch codex rate limits: 401 Unauthorized; token_expired"}}'
IFS= read -r refresh_request
[[ "$refresh_request" == *'"id":3'* ]]
[[ "$refresh_request" == *'"refreshToken":true'* ]]
echo '{"id":3,"result":{"account":{"type":"chatgpt","email":"recovered@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
IFS= read -r retry_request
[[ "$retry_request" == *'"id":4'* ]]
[[ "$retry_request" == *'"method":"account/rateLimits/read"'* ]]
echo '{"id":4,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":300,"resetsAt":1800000000}}}}}'
SCRIPT
chmod 0700 "$RECOVERED_CODEX"

PRIMER_CODEX="$TEST_DIR/codex-primer"
cat > "$PRIMER_CODEX" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

[[ "${1:-}" == "exec" ]]
ARGUMENTS="$(printf '%s\n' "$@")"
[[ "$ARGUMENTS" == *"--ephemeral"* ]]
[[ "$ARGUMENTS" == *"--json"* ]]
[[ "$ARGUMENTS" == *"--ignore-user-config"* ]]
[[ "$ARGUMENTS" == *"--cd"* ]]
[[ "$ARGUMENTS" == *"--sandbox"* ]]
[[ "$ARGUMENTS" == *"read-only"* ]]
[[ "$ARGUMENTS" == *"CAPPY_QUOTA_PRIMER_NO_OP_V1"* ]]
[[ "$ARGUMENTS" != *"--ask-for-approval"* ]]
if [[ "$0" == *"-managed" ]]; then
    [[ "${CODEX_HOME:-}" == "/tmp/cappy-codex-handshake" ]]
else
    [[ -z "${CODEX_HOME:-}" ]]
fi
case "${CAPPY_PRIMER_FIXTURE:-success}" in
    empty) exit 0 ;;
    nonzero) exit 1 ;;
    failed) echo '{"type":"turn.failed","error":{"message":"fixture failure"}}'; exit 0 ;;
    malformed) echo 'not JSON'; exit 0 ;;
    missing-usage)
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"CAPPY_QUOTA_PRIMER_ACK_V1"}}'
        echo '{"type":"turn.completed"}'; exit 0 ;;
    wrong-ack)
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"unrelated response"}}'
        echo '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":10}}'; exit 0 ;;
    missing-completion)
        echo '{"type":"item.completed","item":{"type":"agent_message","text":"CAPPY_QUOTA_PRIMER_ACK_V1"}}'; exit 0 ;;
esac
echo '{"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000001"}'
echo '{"type":"turn.started"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"CAPPY_QUOTA_PRIMER_ACK_V1"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":10}}'
SCRIPT
chmod 0700 "$PRIMER_CODEX"

REQUEST='{"context":{},"operation":"refresh","profile":{"configPath":"/tmp/cappy-codex-handshake","createdAt":"2026-08-07T00:00:00Z","id":"codex-default","isDefault":true,"isManaged":false,"label":"Codex","providerID":"openai-codex"},"protocolVersion":1}'
PRIMER_REQUEST='{"context":{},"operation":"primeQuota","profile":{"configPath":"/tmp/cappy-codex-handshake","createdAt":"2026-08-07T00:00:00Z","id":"codex-default","isDefault":true,"isManaged":false,"label":"Codex","providerID":"openai-codex"},"protocolVersion":1}'

verify_response() {
    swift - "$1" <<'SWIFT'
import Foundation

guard CommandLine.arguments.count == 2,
    let data = CommandLine.arguments[1].data(using: .utf8),
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    object["ok"] as? Bool == true,
    let snapshot = object["snapshot"] as? [String: Any],
    snapshot["authenticationState"] as? String == "authenticated",
    let meters = snapshot["meters"] as? [[String: Any]],
    meters.contains(where: { $0["id"] as? String == "codex.primary" })
else {
    FileHandle.standardError.write(Data("Codex handshake regression test failed\n".utf8))
    exit(1)
}
SWIFT
}

verify_expired_response() {
    swift - "$1" <<'SWIFT'
import Foundation

guard CommandLine.arguments.count == 2,
    let data = CommandLine.arguments[1].data(using: .utf8),
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    object["ok"] as? Bool == true,
    let snapshot = object["snapshot"] as? [String: Any],
    snapshot["authenticationState"] as? String == "expired",
    snapshot["freshness"] as? String == "unavailable",
    snapshot["message"] as? String == "Codex sign-in expired. Sign in again.",
    let identity = snapshot["identity"] as? [String: Any],
    identity["email"] as? String == "expired@example.com"
else {
    FileHandle.standardError.write(Data("Codex expired-auth regression test failed\n".utf8))
    exit(1)
}
SWIFT
}

# Explicit override resolution.
RESPONSE="$(CAPPY_CODEX_PATH="$FAKE_CODEX" "$ADAPTER" <<< "$REQUEST")"
verify_response "$RESPONSE"

# Resolution from the PATH inherited by the GUI process.
RESPONSE="$(env -u CAPPY_CODEX_PATH PATH="$TEST_DIR:/usr/bin:/bin" "$ADAPTER" <<< "$REQUEST")"
verify_response "$RESPONSE"

# Resolution from the user's interactive login-shell PATH. The temporary HOME
# keeps this test isolated from the developer's real shell startup files.
SHELL_HOME="$TEST_DIR/shell-home"
mkdir -p "$SHELL_HOME/.config/fish"
SHELL_PATH_EXPORT="export PATH=\"$TEST_DIR:/usr/bin:/bin\""
printf '%s\n' "$SHELL_PATH_EXPORT" > "$SHELL_HOME/.profile"
printf '%s\n' "$SHELL_PATH_EXPORT" > "$SHELL_HOME/.bash_profile"
printf '%s\n' "$SHELL_PATH_EXPORT" > "$SHELL_HOME/.bashrc"
printf '%s\n' "$SHELL_PATH_EXPORT" > "$SHELL_HOME/.zprofile"
printf '%s\n' "$SHELL_PATH_EXPORT" > "$SHELL_HOME/.zshrc"
printf 'setenv PATH "%s:/usr/bin:/bin"\n' "$TEST_DIR" > "$SHELL_HOME/.login"
printf 'setenv PATH "%s:/usr/bin:/bin"\n' "$TEST_DIR" > "$SHELL_HOME/.cshrc"
printf 'set -gx PATH "%s" /usr/bin /bin\n' "$TEST_DIR" > "$SHELL_HOME/.config/fish/config.fish"
RESPONSE="$(env -u CAPPY_CODEX_PATH HOME="$SHELL_HOME" PATH="/usr/bin:/bin" "$ADAPTER" <<< "$REQUEST")"
verify_response "$RESPONSE"

# An expired rate-limit token is an account state, not an indefinitely pending reading.
RESPONSE="$(CAPPY_CODEX_PATH="$EXPIRED_CODEX" "$ADAPTER" <<< "$REQUEST")"
verify_expired_response "$RESPONSE"

# A refreshable expired token recovers without changing the account state.
RESPONSE="$(CAPPY_CODEX_PATH="$RECOVERED_CODEX" "$ADAPTER" <<< "$REQUEST")"
verify_response "$RESPONSE"

# The primer invocation must stay non-persistent and read-only without relying
# on CLI flags removed from current Codex releases.
RESPONSE="$(CAPPY_CODEX_PATH="$PRIMER_CODEX" "$ADAPTER" <<< "$PRIMER_REQUEST")"
[[ "$(jq -r '.ok' <<< "$RESPONSE")" == "true" ]]
[[ "$(jq -r '.message' <<< "$RESPONSE")" == *"verification is pending"* ]]
[[ "$(jq -r '.primerReceipt.inputTokens' <<< "$RESPONSE")" == "100" ]]
[[ "$(jq -r '.primerReceipt.outputTokens' <<< "$RESPONSE")" == "10" ]]

MANAGED_PRIMER_CODEX="$TEST_DIR/codex-primer-managed"
cp "$PRIMER_CODEX" "$MANAGED_PRIMER_CODEX"
MANAGED_PRIMER_REQUEST="$(jq '.profile.isDefault = false | .profile.isManaged = true' <<< "$PRIMER_REQUEST")"
RESPONSE="$(CAPPY_CODEX_PATH="$MANAGED_PRIMER_CODEX" "$ADAPTER" <<< "$MANAGED_PRIMER_REQUEST")"
[[ "$(jq -r '.ok' <<< "$RESPONSE")" == "true" ]]

# Exit zero alone must never count as an accepted primer. Bake each fixture
# into its executable because the adapter intentionally sanitizes its child env.
for fixture in empty nonzero failed malformed missing-usage wrong-ack missing-completion; do
    FIXTURE_CODEX="$TEST_DIR/codex-primer-$fixture"
    sed "s/\${CAPPY_PRIMER_FIXTURE:-success}/$fixture/" "$PRIMER_CODEX" > "$FIXTURE_CODEX"
    chmod 0700 "$FIXTURE_CODEX"
    RESPONSE="$(CAPPY_CODEX_PATH="$FIXTURE_CODEX" "$ADAPTER" <<< "$PRIMER_REQUEST")"
    [[ "$(jq -r '.ok' <<< "$RESPONSE")" == "false" ]]
done

echo "codex-handshake: refresh ordering, executable resolution, expired-auth, and primer checks passed"
