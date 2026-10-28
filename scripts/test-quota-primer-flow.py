#!/usr/bin/env python3
"""Run the real Mac AppModel and adapters with a fake CLI, never live accounts."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parent.parent
BIN = REPO / ".build/debug"
FAKE_CODEX = r'''#!/usr/bin/env python3
import json, pathlib, sys, time
root = pathlib.Path(__file__).parent
anchor = root / "fake-provider-anchor"
if sys.argv[1] == "exec":
    for flag in ["--json", "--ephemeral", "--ignore-user-config", "--cd"]:
        assert flag in sys.argv, flag
    with (root / "primer-requests").open("a") as f:
        f.write("completed\n")
    anchor.write_text(str(int(time.time()) + 604800))
    print(json.dumps({"type":"thread.started", "thread_id":"00000000-0000-4000-8000-000000000001"}))
    print(json.dumps({"type":"turn.started"}))
    print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"CAPPY_QUOTA_PRIMER_ACK_V1"}}))
    print(json.dumps({"type":"turn.completed", "usage":{"input_tokens":101,"output_tokens":13}}))
elif sys.argv[1] == "app-server":
    for line in sys.stdin:
        r = json.loads(line)
        if "id" not in r: continue
        method = r["method"]
        if method == "initialize": result = {}
        elif method == "account/read":
            result = {"account":{"type":"chatgpt", "email":"primer-fixture@example.com", "planType":"pro"}}
        elif method == "account/rateLimits/read":
            reset = int(anchor.read_text()) if anchor.exists() else int(time.time()) + 604800
            used = 1 if anchor.exists() else 0
            result = {"rateLimitsByLimitId":{"codex":{"limitId":"codex", "primary":{"usedPercent":used,"windowDurationMins":10080,"resetsAt":reset}}}}
        else: raise AssertionError(method)
        print(json.dumps({"id":r["id"], "result":result}), flush=True)
else: raise AssertionError(sys.argv)
'''


with tempfile.TemporaryDirectory(prefix="cappy-primer-flow-test-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    cli = root / "codex-fixture"
    cli.write_text(FAKE_CODEX)
    cli.chmod(0o700)
    # Disable the unrelated provider before server startup; the real Codex
    # adapter is intentionally used, but its vendor executable is the fixture.
    profiles = [
        {"id": "codex-default", "providerID": "openai-codex", "label": "Codex",
         "configPath": str(root / "codex-profile"), "isManaged": False,
         "isDefault": True, "isEnabled": True, "createdAt": "2026-10-01T00:00:00Z"},
        {"id": "claude-default", "providerID": "anthropic-claude", "label": "Claude",
         "configPath": str(root / "claude-profile"), "isManaged": False,
         "isDefault": True, "isEnabled": False, "createdAt": "2026-10-01T00:00:00Z"},
    ]
    (root / "state.json").write_text(json.dumps({"contractVersion": 1, "profiles": profiles, "snapshots": {}}))
    (root / "state.json").chmod(0o600)
    env = dict(os.environ, CAPPY_STATE_DIR=str(root), CAPPY_CODEX_PATH=str(cli), CAPPY_ADAPTER_DIR=str(BIN))
    with (root / "server.log").open("w+") as log:
        server = subprocess.Popen([str(BIN / "quota-appserver")], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while not (root / "appserver.sock").exists():
                if server.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise RuntimeError("Fixture server did not start: " + log.read())
                time.sleep(0.05)
            subprocess.run([str(BIN / "CappyMenu"), "--self-test-quota-primer"], env=env, check=True, timeout=40)
            assert (root / "primer-requests").read_text().splitlines() == ["completed"], "duplicate primer sent"
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
