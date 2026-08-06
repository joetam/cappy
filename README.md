# Cappy

Cappy is a local, privacy-conscious quota monitor for coding subscriptions. It ships as a macOS menu-bar app, a local app server, a terminal client, and isolated provider adapters.

This is an independent project and is not affiliated with, endorsed by, or sponsored by Anthropic or OpenAI. Claude, Claude Code, Codex, and related names are trademarks of their respective owners.

![Cappy menu-bar preview](docs/preview.png)

The current adapters support:

- Codex account identity, plan name, every dynamic `rateLimitsByLimitId` bucket, secondary windows, usage-credit balances, and reset credits.
- Claude account identity and plan name through the official CLI, plus every dynamic status-line rate-limit key Claude Code provides. Claude currently documents this public quota feed for Pro and Max subscriptions only. Cappy does not call Claude's private OAuth usage endpoint.

## Build and run

Requirements: macOS 14 or newer and the Swift 6 command-line toolchain.

```sh
make test
make app
open "build/Cappy.app"
```

The packaged command-line client is at:

```sh
"build/Cappy.app/Contents/Helpers/quota" status
"build/Cappy.app/Contents/Helpers/quota" refresh
```

Create an isolated account profile and start the vendor-owned browser login:

```sh
"build/Cappy.app/Contents/Helpers/quota" add codex Personal
"build/Cappy.app/Contents/Helpers/quota" add claude Work
```

The new profile is committed only after the provider reports a successful sign-in. Repeating a provider/label pair or authenticating an identity that is already tracked is rejected. Failed and cancelled attempts are discarded.

Remove a tracked profile:

```sh
"build/Cappy.app/Contents/Helpers/quota" remove <profile-id>
```

For a managed profile this also removes its isolated local vendor credentials. Removing a default profile only stops tracking it; Cappy never deletes `~/.codex` or `~/.claude`, and no action deletes the remote provider account.

For an existing Claude Pro or Max profile, set up the quota status-line bridge:

```sh
"build/Cappy.app/Contents/Helpers/quota" bridge install claude-default
```

Cappy does not overwrite an existing custom or unreadable Claude settings file. Managed Claude profiles are fresh and receive the bridge automatically. The bridge does not send prompts or consume tokens; it receives quota fields when Claude Code publishes its normal status-line payload.

## Local data

Cappy stores sanitized profile metadata and snapshots in:

```text
~/Library/Application Support/Cappy/
```

Installations upgraded from the pre-Cappy build continue using `~/Library/Application Support/QuotaBar/` automatically when that legacy directory exists and the new directory does not. This preserves already configured profiles without copying provider credentials.

It does not copy provider tokens into its state. Codex and Claude remain responsible for their own credential stores and browser login flows.

There is no telemetry, analytics, cloud service, or TCP listener. The app-server and UI communicate through a user-only Unix socket. Account labels, provider identity metadata, plan names, and normalized quota readings stay on the Mac in the directory above. Adapter and vendor subprocesses receive a restricted environment so unrelated credentials exported in a terminal are not forwarded to them.

## Provider compatibility

Provider CLI interfaces can change independently of this project. The Claude adapter uses `claude auth status --json` and the documented status-line payload. The Codex adapter uses Codex's local app-server account and rate-limit methods. Cappy retains the last good snapshot and marks it stale when an adapter fails, but releases still need compatibility testing against current provider CLIs. Normalizer fixtures and contract/security invariants run in CI without accessing live accounts.

## Publishing

Generated directories (`.build/` and `build/`) and local runtime state are ignored by Git. Run `make test` before publishing. Cappy is available under the [MIT License](LICENSE); provider marks are excluded as described in [third-party notices](THIRD_PARTY_NOTICES.md).

The packaging script uses ad-hoc signing for local builds. Before distributing a prebuilt app, add an app icon and configure Developer ID signing and notarization. Neither is required for contributors building locally from source.

See [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY.md](SECURITY.md), and [docs/adapter-protocol-v1.md](docs/adapter-protocol-v1.md).
