# Cappy

Cappy shows Codex and Claude limits across all your accounts in one macOS menu bar app.

https://github.com/user-attachments/assets/6ad3a65e-f143-43f0-af98-509913b9f9de

## Why this exists

Cappy answers a simple question: which account can I use next? It shows what's left and when each limit resets, without signing in and out to check.

- Uses existing CLI sign-ins. When a sign-in is needed, Cappy opens the provider's normal login flow. There is no Cappy account, and Cappy never asks for a password or pasted token. Extra accounts stay in separate CLI profiles.
- No hosted backend, telemetry, or analytics. Usage requests go straight to OpenAI or Anthropic, and cached readings stay on your Mac.
- Cappy is built around a local app server. Provider adapters sit behind it, and every client uses the same API. New providers and interfaces—widgets, TUIs, or anything else—can be added without rewriting the account and quota logic.

## Install

Cappy currently supports Apple silicon on macOS 14 or newer. Install the Codex or Claude Code CLI for each provider you want to track.

### Homebrew

Install Cappy from its Homebrew tap:

```sh
brew install --cask joetam/tap/cappy
```

### Direct download

Download `Cappy-<version>-macos-arm64.zip` from the [latest release](https://github.com/joetam/cappy/releases/latest), unzip it, and move `Cappy.app` to Applications.

### First launch

Current builds are ad-hoc signed and not yet notarized. If macOS blocks Cappy the first time:

1. Try to open Cappy, then click **Done** in the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security** and click **Open Anyway** next to Cappy.
4. Confirm by clicking **Open**.

macOS saves this exception, so later launches open normally. See [Apple's instructions](https://support.apple.com/102445) for more detail.

### Build from source

Install the Swift 6 command-line toolchain, then run:

```sh
make test
make app
open "build/Cappy.app"
```

## Accounts

On launch, Cappy checks the accounts currently signed into the default Codex and Claude CLIs. Signed-out CLI connections stay out of the quota dashboard. When Cappy first discovers a signed-in account, it explains two choices:

- **Keep this account available** signs into a separate local profile, after verifying the same identity, so the account remains in Cappy when the CLI switches.
- **Use current CLI sign-in** requires no login, but the connection follows whichever account is currently signed into that provider CLI.

Cappy remembers that choice for the detected identity. If the provider CLI later changes accounts, Cappy shows a one-time notice naming the newly detected account and whether the previous account remains available separately.

Use **Edit Accounts** to see accounts available independently in Cappy alongside current CLI sign-ins. In **Add Account**, choose a provider first. If that provider has a current CLI sign-in, Cappy explicitly offers to use it as-is, keep it available, or sign in with a different account. Failed, cancelled, wrong-account, and duplicate managed sign-ins are discarded.

Removing an account added to Cappy also removes its isolated local sign-in data. Current CLI connections cannot be removed or signed into through Cappy; they are detected automatically. Neither action deletes a provider account or modifies the default CLI configuration.

Cappy opens at login by default. Right-click its menu bar icon to turn this off or open **Edit Accounts**.

## How it works

```mermaid
flowchart LR
    UI["Menu bar · CLI · custom clients"] <-->|"JSON-RPC over a user-only Unix socket"| SERVER["Cappy app server"]
    SERVER <-->|"provider-agnostic usage contract"| ADAPTERS["Provider adapters"]
    ADAPTERS --> CODEX["Codex app server"]
    ADAPTERS --> CLAUDE["Claude CLI and usage service"]
    SERVER <--> STATE[("local state")]
```

Adapters translate each provider's response into the same data shape. Clients do not need provider-specific code.

## Command line

The command-line client is inside the app bundle:

```sh
CAPPY_CLI="/Applications/Cappy.app/Contents/Helpers/quota"

"$CAPPY_CLI" status
"$CAPPY_CLI" add claude Work
"$CAPPY_CLI" help
```

For a source build, use `build/Cappy.app/Contents/Helpers/quota` instead.

## Local data and credentials

Cappy keeps its account list and cached readings in:

```text
~/Library/Application Support/Cappy/
```

Managed CLI profiles also live under that folder. Cappy only observes the provider-owned defaults in `~/.codex`, `~/.claude`, and the corresponding macOS Keychain entries.

Tokens are not added to Cappy's account list or cache, and the app server and UI never receive them. The Claude adapter reads the selected token to fetch usage and writes any refresh back to the same credential store. The Codex adapter gets usage from the installed Codex app server.

The local app server listens on a user-only Unix socket, not a TCP port. See [SECURITY.md](SECURITY.md) for the full security model.

## Provider support

### General

- Shows the account identity and plan name when available.
- Builds bars from the quota buckets returned by the provider.
- Keeps the last good reading and marks it stale if a refresh fails.

### Codex

- Uses the installed Codex app server under the selected `CODEX_HOME`.
- Reads account-wide and model-specific limits, secondary windows, usage credits, and rate-limit resets when returned.

### Claude

- Uses `claude auth status --json` for account details and Claude Code's private `/api/oauth/usage` endpoint for limits.
- Reads session, weekly, model, feature, spend, and credit limits for Pro, Max, Team, and Enterprise accounts when returned. The private endpoint is undocumented and may change.

Provider interfaces can change. Automated fixtures and contract tests cover the response shapes Cappy currently supports.

Cappy is an independent project and is not affiliated with Anthropic or OpenAI. Claude, Claude Code, Codex, and related names are trademarks of their respective owners.

Cappy is available under the [MIT License](LICENSE). Provider marks are excluded as described in [third-party notices](THIRD_PARTY_NOTICES.md).

More detail: [architecture](ARCHITECTURE.md) · [security](SECURITY.md) · [adapter protocol](docs/adapter-protocol-v1.md)
