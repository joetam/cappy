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
IFS= read -r limits_request
[[ "$initialized" == *'"method":"initialized"'* ]]
[[ "$account_request" == *'"method":"account/read"'* ]]
[[ "$limits_request" == *'"method":"account/rateLimits/read"'* ]]

echo '{"id":1,"result":{"account":{"type":"chatgpt","email":"fixture@example.com","planType":"pro"},"requiresOpenaiAuth":true}}'
sleep 0.1
echo '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000}}}}}'
SCRIPT
chmod 0700 "$FAKE_CODEX"

REQUEST='{"context":{},"operation":"refresh","profile":{"configPath":"/tmp/cappy-codex-handshake","createdAt":"2026-08-07T00:00:00Z","id":"codex-default","isDefault":true,"isManaged":false,"label":"Codex","providerID":"openai-codex"},"protocolVersion":1}'

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

echo "codex-handshake: override, inherited PATH, and login-shell PATH checks passed"
