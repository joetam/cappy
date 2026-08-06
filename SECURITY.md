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
- Login is delegated to installed vendor CLIs. Cappy neither asks for nor parses passwords, access tokens, refresh tokens, or authorization codes.
- Adapter and vendor subprocesses receive an allowlisted environment. Unrelated shell credentials and API-key variables are not inherited.
- New-account enrollment uses a private staging directory. It enters the ledger only after the adapter verifies authentication; failure, cancellation, duplicate identity, or app-server restart discards the staging data.
- Removal never deletes a provider account. It deletes isolated credentials only when the stored path exactly matches Cappy's managed profile layout; default `~/.codex` and `~/.claude` directories are only detached and are never deleted.
- Adapter responses must match the requested profile ID, provider ID, and contract version.
- Snapshot fields and meter arrays are bounded. Arbitrary adapter `details` are removed before persistence or UI delivery.
- A failed refresh retains the last known reading and marks it stale instead of replacing it with misleading empty data.
- External adapter manifests require an absolute executable owned by the current user and reject group/world-writable executables.
- External manifests are size-bounded and validated at runtime against the same provider-ID, argument, and environment limits documented by the schema. Symlinked executables are resolved before use.
- Existing Claude status-line commands are preserved rather than silently overwritten.
- Public profile RPC responses omit provider configuration paths; only the app server and the selected adapter receive them.
- Provider stable account/organization IDs are retained only for local deduplication and removed from client-facing snapshots.

## Trust boundaries and limitations

Adapter processes provide crash isolation, not an OS sandbox. A malicious executable running as the user may read other user-accessible files regardless of Cappy. Install only trusted adapters. Future hardening can add signed manifests and sandboxed helper bundles.

The current app bundle is not hardened with the macOS App Sandbox because it must discover and launch separately installed vendor CLIs and let those CLIs use their own configuration directories and browser login flows. Source-built releases are ad-hoc signed; distributors should use Developer ID signing, hardened runtime review, and notarization.

Sanitized state includes local account metadata such as provider, label, email or organization, plan name, and quota readings. It is not credential material, but it is private and therefore stored with restrictive permissions.

Any process already running as the same macOS user can potentially access the socket or state files and request app-server actions. Cappy does not defend against a fully compromised user session.

Claude Code's interactive `/usage` view can obtain quota internally, but Claude does not publish a standalone machine-readable quota polling command. Cappy uses Claude's documented status-line payload and only receives fresh quota after Claude Code publishes that payload for the profile. Claude currently documents status-line rate-limit fields for Pro and Max subscriptions only, so Team and Enterprise accounts can show identity and plan without quota bars. Cappy does not call Claude's private OAuth usage endpoint or scrape its terminal UI.

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
| Existing Claude status line gets clobbered | Preserve and warn; automatic install only for empty profiles |
| UI rereads cache but never refreshes | Five-minute client refresh plus stale aging |
| Failed signup leaves phantom accounts | Transactional staging and commit-after-verification |
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

## Remaining roadmap risks

- Add signed adapter packages and optional sandbox profiles.
- Prefer opaque provider account IDs when vendors expose them; current deduplication uses the already-sanitized identity fields in snapshots.
- Add a structured Codex browser/device-code login UI rather than the CLI fallback.
- Add a redacted interactive login console for Claude callback failures.
- Add launch-at-login management and a WidgetKit/App Group snapshot bridge.

## Reporting a vulnerability

Do not include live credentials, auth files, or private account snapshots in a public issue. Use GitHub's private vulnerability-reporting feature if it is enabled for the published repository. Otherwise, contact the maintainer privately before sharing sensitive reproduction material.
