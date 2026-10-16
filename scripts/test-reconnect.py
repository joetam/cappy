#!/usr/bin/env python3
"""Exercise the real server with isolated, path-scoped fake vendor credentials."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

REPO = Path(__file__).resolve().parents[1]
ACCOUNT = {"email": "work@example.com", "stableID": "work-org", "organization": "Work"}

ADAPTER = r'''
import json, sys, time
from pathlib import Path
root = Path(__file__).parent
if len(sys.argv) > 1:
    target = Path(sys.argv[1])
    identity = json.loads((root / "browser.json").read_text())
    while (root / "pause-login").exists(): time.sleep(.02)
    (target / "credential.json").write_text(json.dumps(identity))
    sys.exit(0)
r = json.load(sys.stdin)
p = r.get("profile", {})
path = Path(p.get("configPath", "/nonexistent"))
op = r["operation"]
result = {"protocolVersion": 1, "ok": True, "warnings": []}
if op == "describe":
    result["provider"] = {"id": "anthropic-claude", "displayName": "Claude"}
elif op == "prepareLogin":
    with (root / "login-paths").open("a") as f: f.write(str(path) + "\n")
    result["loginCommand"] = {"executable": sys.executable, "arguments": [__file__, str(path)], "environment": {}, "requiresPTY": False}
elif op == "refresh":
    credential = path / "credential.json"
    identity = json.loads(credential.read_text()) if credential.exists() else None
    if (path / "pause-refresh").exists():
        (root / "refresh-started").touch()
        while (path / "pause-refresh").exists(): time.sleep(.02)
    expired = (path / "expired").exists()
    snapshot = {"contractVersion": 1, "profileID": p["id"], "profileLabel": p["label"],
        "provider": {"id": p["providerID"], "displayName": "Claude"},
        "authenticationState": "expired" if expired else ("authenticated" if identity is not None else "unauthenticated"),
        "meters": [], "observedAt": "2026-10-16T12:00:00Z", "freshness": "unavailable" if expired else "fresh"}
    if identity is not None and not expired: snapshot["identity"] = identity
    result["snapshot"] = snapshot
elif op == "removeManagedCredentials":
    (path / "credential.json").unlink(missing_ok=True)
print(json.dumps(result))
'''

with tempfile.TemporaryDirectory(prefix="cappy-reconnect-", dir="/tmp") as tmp:
    root = Path(tmp)
    state = root / "state"
    adapters = root / "adapters"
    adapters.mkdir()
    adapter = adapters / "quota-adapter-claude"
    adapter.write_text(f"#!{sys.executable}\n" + ADAPTER)
    adapter.chmod(0o700)
    log = (root / "server.log").open("w+")
    server = None

    def until(predicate):
        for _ in range(400):
            result = predicate()
            if result:
                return result
            time.sleep(.025)
        raise AssertionError("Timed out")

    def start():
        global server
        server = subprocess.Popen([str(REPO / ".build/debug/quota-appserver")],
            env={**os.environ, "CAPPY_STATE_DIR": str(state), "CAPPY_ADAPTER_DIR": str(adapters)}, stdout=log, stderr=log)
        until(lambda: (state / "appserver.sock").exists() or server.poll() is not None)
        assert server.poll() is None
        result("refresh.all")  # Drain startup refreshes before capturing test baselines.

    def stop():
        if server and server.poll() is None:
            server.terminate()
            server.wait(timeout=10)
        (state / "appserver.sock").unlink(missing_ok=True)

    def rpc(method, **params):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(15)
            connection.connect(str(state / "appserver.sock"))
            connection.sendall((json.dumps({"jsonrpc": "2.0", "id": "test", "method": method, "params": params}) + "\n").encode())
            with connection.makefile("r") as reader:
                return json.loads(reader.readline())

    def result(method, **params):
        response = rpc(method, **params)
        assert "error" not in response or response["error"] is None, response
        return response["result"]

    def terminal(job):
        def check():
            status = result("login.status", jobID=job["id"])
            return status if status["state"] not in ("running", "verifying") else None
        return until(check)

    def browser(identity):
        (adapters / "browser.json").write_text(json.dumps(identity))

    def ledger():
        return json.loads((state / "state.json").read_text())

    def profile():
        return next(p for p in ledger()["profiles"] if p["id"] == profile_id)

    def snapshot():
        return ledger()["snapshots"][profile_id]

    def reconnect():
        return result("profile.login", profileID=profile_id)

    try:
        start()
        browser(ACCOUNT)
        enrolled = result("profile.enroll", providerID="anthropic-claude", label="My work account")
        assert terminal(enrolled)["state"] == "succeeded"
        profile_id = enrolled["profileID"]
        original = profile()
        original_path = Path(original["configPath"])
        original_credential = (original_path / "credential.json").read_bytes()
        assert original["accountBinding"]
        assert "accountBinding" not in next(p for p in result("profile.list") if p["id"] == profile_id)

        # Expiry clears the current identity but cannot erase the reconnect binding.
        (original_path / "expired").touch()
        assert result("refresh.profile", profileID=profile_id)["authenticationState"] == "expired"
        assert snapshot().get("identity") is None
        stop()
        start()
        assert profile()["accountBinding"] == original["accountBinding"]
        before = snapshot()

        # Wrong browser email, same email in another org, and missing identity all fail.
        for identity in [{**ACCOUNT, "email": "personal@example.com"}, {**ACCOUNT, "stableID": "personal-org"}, {}]:
            browser(identity)
            status = terminal(reconnect())
            assert status["state"] == "failed", status
            assert "different account or organization" in status["message"]
            assert profile() == original
            assert snapshot() == before
            assert (original_path / "credential.json").read_bytes() == original_credential
            assert list(original_path.parent.iterdir()) == [original_path]

        # Repeated clicks share the same job. Cancel does not replace credentials.
        browser(ACCOUNT)
        (adapters / "pause-login").touch()
        job = reconnect()
        assert reconnect()["id"] == job["id"]
        cancelled_path = Path((adapters / "login-paths").read_text().splitlines()[-1])
        assert cancelled_path != original_path
        assert result("login.cancel", jobID=job["id"])["state"] == "cancelled"
        until(lambda: not cancelled_path.exists())
        (adapters / "pause-login").unlink()
        assert profile() == original and snapshot() == before

        # Same verified account succeeds, preserving ID, label, order, and staged path.
        browser({**ACCOUNT, "email": "  WORK@EXAMPLE.COM  "})
        ids_before = [p["id"] for p in result("profile.list")]
        assert terminal(reconnect())["state"] == "succeeded"
        new_path = Path(profile()["configPath"])
        assert new_path != original_path and not original_path.exists()
        assert new_path == Path((adapters / "login-paths").read_text().splitlines()[-1])
        assert profile()["label"] == original["label"]
        assert [p["id"] for p in result("profile.list")] == ids_before
        assert snapshot()["authenticationState"] == "authenticated"
        stop()
        start()
        assert new_path.exists()  # Orphan cleanup must retain the new credential path.

        # A credential switched outside the login flow also cannot rebind the entry.
        (new_path / "credential.json").write_text(json.dumps({**ACCOUNT, "email": "wrong@example.com"}))
        rejected = result("refresh.profile", profileID=profile_id)
        assert rejected["authenticationState"] == "expired"
        assert rejected.get("identity") is None and not rejected["meters"]
        assert profile()["accountBinding"] == original["accountBinding"]
        browser(ACCOUNT)
        assert terminal(reconnect())["state"] == "succeeded"

        # An in-flight read of old credentials cannot overwrite a committed reconnect.
        saved_path = Path(profile()["configPath"])
        (saved_path / "expired").touch()
        (saved_path / "pause-refresh").touch()
        with ThreadPoolExecutor(max_workers=1) as pool:
            refresh = pool.submit(result, "refresh.profile", profileID=profile_id)
            until(lambda: (adapters / "refresh-started").exists())
            job = reconnect()
            until(lambda: result("login.status", jobID=job["id"])["state"] == "verifying")
            (saved_path / "pause-refresh").unlink()
            assert refresh.result()["authenticationState"] == "expired"
            assert terminal(job)["state"] == "succeeded"
        assert snapshot()["authenticationState"] == "authenticated"
        assert Path(profile()["configPath"]) != saved_path

        # Existing verified profiles migrate, even after a custom display-name change.
        stop()
        data = ledger()
        next(p for p in data["profiles"] if p["id"] == profile_id).pop("accountBinding")
        (state / "state.json").write_text(json.dumps(data))
        start()
        assert profile()["accountBinding"] == original["accountBinding"]

        # Removal during login cannot resurrect the connection or strand credentials.
        (adapters / "pause-login").touch()
        job = reconnect()
        draft_path = Path((adapters / "login-paths").read_text().splitlines()[-1])
        saved_path = Path(profile()["configPath"])
        result("profile.remove", profileID=profile_id)
        until(lambda: not draft_path.exists())
        assert not saved_path.exists()
        assert terminal(job)["state"] == "cancelled"
        assert not any(p["id"] == profile_id for p in result("profile.list"))
        (adapters / "pause-login").unlink()

        # Unknown legacy identity must not be guessed from an email-like label.
        legacy = result("profile.add", providerID="anthropic-claude", label="work@example.com")
        response = rpc("profile.login", profileID=legacy["id"])
        assert "no verified identity" in response["error"]["message"]
        print("reconnect: account/org mismatch, expiry/restart, cancellation, path promotion, migration, and removal passed")
    except BaseException:
        log.flush()
        log.seek(0)
        print(log.read(), file=sys.stderr)
        raise
    finally:
        stop()
        log.close()
