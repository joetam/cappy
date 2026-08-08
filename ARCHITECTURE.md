# Architecture

Cappy has four independently testable layers:

```text
┌──────────────────────────────────────────────────────────┐
│ UI clients                                                │
│ macOS menu + desktop overlay · quota CLI · future TUI    │
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
│ codex app-server · claude CLI/OAuth usage · future APIs   │
└───────────────────────────────────────────────────────────┘
```

## Contract principles

1. The UI never receives provider payloads. It renders `AccountSnapshot` and `[QuotaMeter]` only.
2. A profile is a committed credential slot, not an account identity. The identity behind a slot can change after a later vendor login.
3. Enrollment is transactional. `profile.enroll` creates an untracked slot at its final stable configuration path; only a verified login commits it to the profile ledger. When preserving a discovered CLI account, the request is bound to the displayed email and the managed login must resolve to the same provider identity. Failed, cancelled, wrong-account, duplicate, and app-server-abandoned enrollments are discarded.
4. Meters are arrays, not fixed primary/secondary fields. A provider can add any number of account-, model-, credit-, or spend-scoped meters without changing the app-server API.
5. Every meter declares its unit, scope, window, reset, status, provenance, and presentation priority.
6. Unsupported values survive normalization as `unknown`; adapters must not silently drop new provider buckets.
7. Dates cross process boundaries as ISO-8601 values and fractions use the closed interval `0...1`.

## Components

### QuotaContracts

The only model imported by every layer. `AccountSnapshot` includes authentication state, identity, subscription plan, freshness, and an arbitrary array of `QuotaMeter` values.

### CappyClientState

A credential-free client helper for classifying a default CLI identity as first-seen, unchanged, or changed. Its executable self-test covers the onboarding and account-change state transitions without launching a provider CLI.

### QuotaProviderKit

Defines Adapter Protocol v1, manifest loading, safe executable discovery, process execution, local RPC, and standard filesystem locations. It contains no Codex or Claude normalization logic.

### QuotaBuiltins

Pure provider normalizers. They accept provider JSON and return contract models. The Claude normalizer dynamically discovers OAuth usage buckets; the Codex normalizer iterates every `rateLimitsByLimitId` entry and both windows.

### Provider adapter executables

Adapters are one-shot executables that read one JSON request from stdin and write one JSON response to stdout. stderr is diagnostic-only. Process isolation contains crashes and allows adapters to be written in any language, while the language-neutral protocol prevents Swift ABI coupling.

### quota-appserver

Owns the local Unix socket, committed-profile ledger, enrollment transactions, snapshot cache, adapter validation, and login job orchestration. It rejects mismatched profile/provider identities, duplicate managed provider/label pairs, and duplicate managed authenticated identities. An explicit preservation transaction may pair one discovered default connection with one managed copy of the same identity. The server also bounds strings and meter counts, strips arbitrary meter details, and retains the last good snapshot on transient failure.

### Clients

The menu app, its optional floating desktop overlay, and the CLI use the same JSON-RPC methods. The two macOS views share one client model and app-server connection, so showing the overlay does not create another server or refresh loop. The UI remains intentionally thin and can be replaced by a TUI or another local client without loading provider code. The profile ledger’s array order is canonical, so reordering from any client is reflected everywhere. Client-facing profile summaries omit provider configuration paths, and client-facing snapshots omit provider stable IDs; full profiles and deduplication identifiers stay inside the app-server/adapter boundary.

The menu client remembers the last explicitly acknowledged default-CLI identity for each provider in local app preferences. A previously unseen provider identity triggers the contextual first-discovery choice; a different identity for an acknowledged provider triggers a one-time account-change notice. This preference affects explanation and onboarding only—the current default identity still comes from a freshly observed provider snapshot, and all preservation security checks remain server-side.

## App-server RPC v1

Transport: newline-delimited JSON-RPC 2.0 over the user-only Unix socket `appserver.sock`.

| Method | Purpose |
|---|---|
| `system.ping` | Contract and health check |
| `provider.list` | Installed provider descriptors |
| `profile.list` | Path-free credential-slot summaries, never credentials |
| `profile.reorder` | Persist the provider-neutral account order used by every client |
| `profile.add` | Create an isolated managed slot |
| `profile.enroll` | Stage a slot, run vendor login, and commit only after authentication and any requested discovered-identity match |
| `profile.remove` | Remove a managed slot and its isolated credentials; default CLI connections reject removal |
| `profile.configure` | Ask the adapter to install non-secret integration support |
| `profile.login` | Start or reattach to a vendor login job for an existing managed profile; default CLI connections reject login |
| `login.status` | Poll a login job |
| `login.cancel` | Cancel a job; staged enrollments are discarded |
| `snapshot.list` | Return sanitized cached account snapshots |
| `refresh.profile` | Refresh one slot through its adapter |
| `refresh.all` | Refresh every slot |

## Adding a provider

Add an executable and a manifest under `~/Library/Application Support/Cappy/adapters`. The daemon must be restarted to reload manifests. Details and examples are in [docs/adapter-protocol-v1.md](docs/adapter-protocol-v1.md).
