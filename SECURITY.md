# Security and adversarial review

## Security goals

- Provider credentials remain in provider-owned storage.
- No network listener is exposed by Cappy.
- UIs receive sanitized quota state, not tokens or raw provider responses.
- One broken adapter cannot corrupt daemon memory or crash another adapter.
- A provider cannot accidentally bind a reading to the wrong credential slot.

## Implemented controls

- The app server binds an `0600` Unix-domain socket under a `0700` state directory.
- A process lock prevents multiple app-server instances from replacing each other's socket or racing state writes. Socket peers must have the same effective user ID, I/O is bounded and timed out, and `SIGPIPE` is disabled.
- State and meter-cache files use `0600`; managed profile directories use `0700`.
- Vendor executables receive `CODEX_HOME` or `CLAUDE_CONFIG_DIR` only for isolated profiles. Default slots leave the environment unset so vendor Keychain behavior is unchanged.
- Login is delegated to installed vendor CLIs. Cappy never asks for or parses passwords or authorization codes. The Claude adapter reads the selected OAuth credential in its isolated process solely to request usage and refresh an expiring token; token material never crosses the adapter protocol or enters Cappy state, logs, or process arguments.
- Adapter and vendor subprocesses receive an allowlisted environment. Unrelated shell credentials and API-key variables are not inherited.
- New-account enrollment reserves its final managed configuration path before vendor login because some credential stores namespace secrets by absolute path. It enters the ledger only after the adapter verifies authentication; failure, cancellation, duplicate identity, or app-server restart discards the untracked directory and asks the adapter to remove provider-managed credentials.
- Removal never deletes a provider account. It deletes isolated credentials only when the stored path exactly matches Cappy's managed profile layout; default `~/.codex` and `~/.claude` directories are only detached and are never deleted.
- Adapter responses must match the requested profile ID, provider ID, and contract version.
- Snapshot fields and meter arrays are bounded. Arbitrary adapter `details` are removed before persistence or UI delivery.
- A failed refresh retains the last known reading and marks it stale instead of replacing it with misleading empty data.
- External adapter manifests require an absolute executable owned by the current user and reject group/world-writable executables.
- External manifests are size-bounded and validated at runtime against the same provider-ID, argument, and environment limits documented by the schema. Symlinked executables are resolved before use.
- Claude configuration is not modified to install a status-line command. Existing legacy hooks are left untouched, and their normalized readings can remain as last-known fallback state.
- Public profile RPC responses omit provider configuration paths; only the app server and the selected adapter receive them.
- Provider stable account/organization IDs are retained only for local deduplication and removed from client-facing snapshots.

## Trust boundaries and limitations

Adapter processes provide crash isolation, not an OS sandbox. A malicious executable running as the user may read other user-accessible files regardless of Cappy. Install only trusted adapters. Future hardening can add signed manifests and sandboxed helper bundles.

The current app bundle is not hardened with the macOS App Sandbox because it must discover and launch separately installed vendor CLIs and let those CLIs use their own configuration directories and browser login flows. Source-built releases are ad-hoc signed; distributors should use Developer ID signing, hardened runtime review, and notarization.

Sanitized state includes local account metadata such as provider, label, email or organization, plan name, and quota readings. It is not credential material, but it is private and therefore stored with restrictive permissions.

Any process already running as the same macOS user can potentially access the socket or state files and request app-server actions. Cappy does not defend against a fully compromised user session.

Claude does not publish a supported standalone machine-readable quota polling command. Cappy calls the same private OAuth usage path used by the installed Claude Code client. This provides server-side limits—including Team and Enterprise limits—without sending a prompt or scraping terminal UI, but it is an undocumented compatibility surface and may change without notice. Requests are restricted to hard-coded Anthropic HTTPS origins, redirects are rejected, responses are size-bounded, and only normalized meter fields are cached. If the call fails, Cappy uses its last normalized reading or a legacy status-line cache.

On macOS, Claude Code stores OAuth credentials in Keychain services scoped to the configuration directory. Cappy derives only the selected profile's service name, invokes the system `security` helper with a hard timeout, and supplies rotated credential data through stdin rather than command-line arguments. Refresh-token writes use optimistic comparison so a concurrent Claude Code refresh wins instead of being overwritten.

Login subprocesses currently depend on the vendor opening its browser callback successfully. Headless/device-code UX and bounded, redacted login progress are planned improvements.

External adapter manifests are loaded at app-server startup. Adding or removing one currently requires restarting the app server.

## Adversarial findings resolved during implementation

| Finding | Resolution |
|---|---|
| Fixed primary/secondary bars cannot represent new model limits | Arbitrary typed meter arrays |
| Provider JSON leaking into UI couples every client | Normalization occurs only in adapters |
| Default config environment can select a different Keychain namespace | Default slots never inject override variables |
| Transient adapter errors erase good readings | Last-known-good state is retained and marked stale |
| Adapter can return another profile's snapshot | Profile/provider/version validation |
| New provider keys disappear silently | Dynamic iteration and unknown-key preservation |
| Existing Claude status line gets clobbered | No status-line installation; legacy caches are fallback-only |
| UI rereads cache but never refreshes | Five-minute client refresh plus stale aging |
| Failed signup leaves phantom accounts | Untracked stable-path enrollment and commit-after-verification |
| Repeated signup creates duplicates | Provider/label reservation plus authenticated identity comparison |
| Account removal risks deleting vendor defaults | Exact managed-path validation; default profiles are detach-only |
| Third-party Swift plugin destabilizes daemon | Language-neutral out-of-process adapters |
| A second daemon replaces the live Unix socket | Single-instance file lock before binding |
| Adapter output fills a pipe and deadlocks refresh | Concurrent bounded stdout/stderr draining and hard timeouts |
| Manifest provider ID traverses outside managed storage | Runtime schema validation before registration |
| Profile removal fails after the ledger was already updated | Atomic move-to-staging, ledger commit, then cleanup |
| UI clients learn local provider paths | Path-free `ProfileSummary` RPC model |
| Exported shell secrets reach every adapter | Allowlisted subprocess environment |
| Concurrent requests can start two logins for one profile | Atomic per-profile login reservation |
| A provider can stream an unbounded response | Bounded adapter output and Codex protocol buffers |
| Oversized status-line payload exhausts client memory | One-megabyte bounded stdin parsing |
| A partial rename hides existing account state | State-file-aware legacy-directory selection |
| Private Claude usage only reflects this Mac | Server-side OAuth usage rather than local response events |
| Claude Team quota is treated as unsupported | Plan-neutral dynamic OAuth bucket discovery |
| Managed Claude login breaks after enrollment | Stable absolute config path from login through ledger commit |
| OAuth tokens leak through argv or app state | System Keychain helper, stdin-only writes, and adapter-local memory |

## Remaining roadmap risks

- Add signed adapter packages and optional sandbox profiles.
- Prefer opaque provider account IDs when vendors expose them; current deduplication uses the already-sanitized identity fields in snapshots.
- Add a structured Codex browser/device-code login UI rather than the CLI fallback.
- Add a redacted interactive login console for Claude callback failures.
- Add launch-at-login management and a WidgetKit/App Group snapshot bridge.

## Reporting a vulnerability

Do not include live credentials, auth files, or private account snapshots in a public issue. Use GitHub's private vulnerability-reporting feature if it is enabled for the published repository. Otherwise, contact the maintainer privately before sharing sensitive reproduction material.
