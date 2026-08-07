# Architecture

Cappy has four independently testable layers:

```text
┌──────────────────────────────────────────────────────────┐
│ UI clients                                                │
│ MenuBarExtra · quota CLI · future WidgetKit/TUI           │
└───────────────────────┬──────────────────────────────────┘
                        │ JSON-RPC v2 / Unix socket
┌───────────────────────▼──────────────────────────────────┐
│ quota-appserver                                           │
│ profile registry · snapshot validation · cache · login jobs│
└───────────────┬───────────────────────────┬──────────────┘
                │ Adapter Protocol v1       │ sanitized state
┌───────────────▼────────────┐   ┌──────────▼──────────────┐
│ out-of-process adapters     │   │ Application Support     │
│ Codex · Claude · future     │   │ state.json · meter cache│
└───────────────┬────────────┘   └─────────────────────────┘
                │ vendor-owned interfaces
┌───────────────▼───────────────────────────────────────────┐
│ codex app-server · claude CLI/status line · future APIs   │
└───────────────────────────────────────────────────────────┘
```

## Contract principles

1. The UI never receives provider payloads. It renders `AccountSnapshot` and `[QuotaMeter]` only.
2. A profile is a committed credential slot, not an account identity. The identity behind a slot can change after a later vendor login.
3. Enrollment is transactional. `profile.enroll` creates an untracked staging slot; only a verified login commits it to the profile ledger. Failed, cancelled, duplicate, and app-server-abandoned enrollments are discarded.
4. Meters are arrays, not fixed primary/secondary fields. A provider can add any number of account-, model-, credit-, or spend-scoped meters without changing the app-server API.
5. Every meter declares its unit, scope, window, reset, status, provenance, and presentation priority.
6. Unsupported values survive normalization as `unknown`; adapters must not silently drop new provider buckets.
7. Dates cross process boundaries as ISO-8601 values and fractions use the closed interval `0...1`.

## Components

### QuotaContracts

The only model imported by every layer. `AccountSnapshot` includes authentication state, identity, subscription plan, freshness, and an arbitrary array of `QuotaMeter` values.

### QuotaProviderKit

Defines Adapter Protocol v1, manifest loading, safe executable discovery, process execution, local RPC, and standard filesystem locations. It contains no Codex or Claude normalization logic.

### QuotaBuiltins

Pure provider normalizers. They accept provider JSON and return contract models. The Claude normalizer iterates every key beneath `rate_limits`; the Codex normalizer iterates every `rateLimitsByLimitId` entry and both windows.

### Provider adapter executables

Adapters are one-shot executables that read one JSON request from stdin and write one JSON response to stdout. stderr is diagnostic-only. Process isolation contains crashes and allows adapters to be written in any language, while the language-neutral protocol prevents Swift ABI coupling.

### quota-appserver

Owns the local Unix socket, committed-profile ledger, enrollment transactions, snapshot cache, adapter validation, and login job orchestration. It rejects mismatched profile/provider identities, duplicate provider/label pairs, and duplicate authenticated identities; bounds strings and meter counts; strips arbitrary meter details; and retains the last good snapshot on transient failure.

### Clients

The menu app and CLI use the same JSON-RPC methods. The menu app is intentionally thin and can be replaced by WidgetKit, a TUI, or another local client without loading provider code. The profile ledger’s array order is canonical, so reordering from any client is reflected everywhere. Client-facing profile summaries omit provider configuration paths, and client-facing snapshots omit provider stable IDs; full profiles and deduplication identifiers stay inside the app-server/adapter boundary.

## App-server RPC v1

Transport: newline-delimited JSON-RPC 2.0 over the user-only Unix socket `appserver.sock`.

| Method | Purpose |
|---|---|
| `system.ping` | Contract and health check |
| `provider.list` | Installed provider descriptors |
| `profile.list` | Path-free credential-slot summaries, never credentials |
| `profile.reorder` | Persist the provider-neutral account order used by every client |
| `profile.add` | Create an isolated managed slot |
| `profile.enroll` | Stage a slot, run vendor login, and commit only after authentication |
| `profile.remove` | Detach a default slot or remove a managed slot and its isolated credentials |
| `profile.configure` | Ask the adapter to install non-secret integration support |
| `profile.login` | Start a vendor CLI login job |
| `login.status` | Poll a login job |
| `login.cancel` | Cancel a job and discard a staged enrollment |
| `snapshot.list` | Return sanitized cached account snapshots |
| `refresh.profile` | Refresh one slot through its adapter |
| `refresh.all` | Refresh every slot |
| `quota.ingest` | Accept a bounded status-line meter cache |

## Adding a provider

Add an executable and a manifest under `~/Library/Application Support/Cappy/adapters`. Upgraded installations that still use the pre-Cappy state directory load adapters from `~/Library/Application Support/QuotaBar/adapters`. The daemon must be restarted to reload manifests. Details and examples are in [docs/adapter-protocol-v1.md](docs/adapter-protocol-v1.md).
