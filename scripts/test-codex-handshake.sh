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
RESPONSE="$(CAPPY_CODEX_PATH="$FAKE_CODEX" "$ADAPTER" <<< "$REQUEST")"

swift - "$RESPONSE" <<'SWIFT'
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

echo "codex-handshake: all checks passed"
