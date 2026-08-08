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
- Login is delegated to installed vendor CLIs. Cappy never asks for or parses passwords or authorization codes. The Claude adapter reads the selected OAuth credential in its isolated process solely to request usage and refresh an expiring token; token material never crosses the adapter protocol or enters Cappy state or logs.
- Adapter and vendor subprocesses receive an allowlisted environment. Unrelated shell credentials and API-key variables are not inherited.
- New-account enrollment reserves its final managed configuration path before vendor login because some credential stores namespace secrets by absolute path. It enters the ledger only after the adapter verifies authentication; failure, cancellation, duplicate identity, or app-server restart discards the untracked directory and asks the adapter to remove provider-managed credentials.
- Preserving a discovered CLI account requires a fresh isolated provider login. The request is bound to the displayed provider and email, and the resulting provider identity must match; a CLI switch or wrong browser account fails closed and removes the untracked credential slot.
- Removal never deletes a provider account. It deletes isolated credentials only when the stored path exactly matches Cappy's managed profile layout; default CLI connections cannot be removed or used as Cappy login targets.
- Adapter responses must match the requested profile ID, provider ID, and contract version.
- Snapshot fields and meter arrays are bounded. Arbitrary adapter `details` are removed before persistence or UI delivery.
- A failed refresh retains the last known reading and marks it stale instead of replacing it with misleading empty data.
- External adapter manifests require an absolute executable owned by the current user and reject group/world-writable executables.
- External manifests are size-bounded and validated at runtime against the same provider-ID, argument, and environment limits documented by the schema. Symlinked executables are resolved before use.
- Claude configuration is not modified to install hooks or status-line commands.
- Public profile RPC responses omit provider configuration paths; only the app server and the selected adapter receive them.
- Provider stable account/organization IDs are retained only for local deduplication and removed from client-facing snapshots.
- The menu app keeps the last acknowledged CLI email and whether it was preserved in local app preferences solely to distinguish first discovery from a later CLI account change. It does not store tokens or use this preference to authorize preservation.

## Trust boundaries and limitations

Adapter processes provide crash isolation, not an OS sandbox. A malicious executable running as the user may read other user-accessible files regardless of Cappy. Install only trusted adapters. Future hardening can add signed manifests and sandboxed helper bundles.

The current app bundle is not hardened with the macOS App Sandbox because it must discover and launch separately installed vendor CLIs and let those CLIs use their own configuration directories and browser login flows. Source-built releases are ad-hoc signed; distributors should use Developer ID signing, hardened runtime review, and notarization.

Sanitized state includes local account metadata such as provider, label, email or organization, plan name, and quota readings. It is not credential material, but it is private and therefore stored with restrictive permissions.

Any process already running as the same macOS user can potentially access the socket or state files and request app-server actions. Cappy does not defend against a fully compromised user session.

Claude does not publish a supported standalone machine-readable quota polling command. Cappy calls the same private OAuth usage path used by the installed Claude Code client. This provides server-side limits—including Team and Enterprise limits—without sending a prompt or scraping terminal UI, but it is an undocumented compatibility surface and may change without notice. Requests are restricted to hard-coded Anthropic HTTPS origins, redirects are rejected, responses are size-bounded, and only normalized meter fields are cached. If the call fails, Cappy keeps the last normalized reading and marks it stale.

On macOS, Claude Code stores OAuth credentials in Keychain services scoped to the configuration directory and grants access to Apple's `/usr/bin/security` helper. Cappy derives only the selected profile's service name and uses that same helper to read the bounded item. Rotated documents use the helper's hexadecimal-data mode, matching Claude Code and avoiding the 128-byte limit of interactive password input. Updates preserve the item's Keychain metadata and use optimistic comparison so a concurrent Claude Code refresh wins instead of being overwritten.

During a credential rotation, the hexadecimal document is necessarily present in the short-lived `security` helper's argument list because that tool has no unbounded stdin-data mode. Cappy clients never receive it, but a local process able to inspect that helper during the brief rotation window could observe it. This is a limitation inherited from Claude Code's credential-writing mechanism; a process already running as the same user can also ask the unlocked Keychain for the item and is outside Cappy's threat boundary.

Login subprocesses still depend on the vendor opening its browser callback successfully. An active job can be reattached and cancelled from the menu, expires after ten minutes, and terminates the provider process tree so a failed localhost callback cannot wedge the profile. Headless/device-code UX and richer redacted progress are planned improvements.

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
| UI rereads cache but never refreshes | Five-minute client refresh plus stale aging |
| Failed signup leaves phantom accounts | Untracked stable-path enrollment and commit-after-verification |
| Repeated signup creates duplicates | Provider/label reservation plus authenticated identity comparison; one default/managed pair is allowed only during explicit preservation and coalesced in the UI |
| Account removal risks deleting vendor defaults | Exact managed-path validation; default connections reject removal and direct login |
| CLI account changes during preservation | Displayed email binding plus post-login provider identity comparison |
| Third-party Swift plugin destabilizes daemon | Language-neutral out-of-process adapters |
| A second daemon replaces the live Unix socket | Single-instance file lock before binding |
| Adapter output fills a pipe and deadlocks refresh | Concurrent bounded stdout/stderr draining and hard timeouts |
| Manifest provider ID traverses outside managed storage | Runtime schema validation before registration |
| Profile removal fails after the ledger was already updated | Atomic move-to-staging, ledger commit, then cleanup |
| UI clients learn local provider paths | Path-free `ProfileSummary` RPC model |
| Exported shell secrets reach every adapter | Allowlisted subprocess environment |
| Concurrent requests can start two logins for one profile | Atomic per-profile login reservation |
| Failed localhost callback blocks every later login | Reattachable job, visible cancellation, bounded lifetime, and process-tree termination |
| A provider can stream an unbounded response | Bounded adapter output and Codex protocol buffers |
| Oversized adapter input exhausts client memory | One-megabyte bounded stdin parsing |
| Private Claude usage only reflects this Mac | Server-side OAuth usage rather than local response events |
| Claude Team quota is treated as unsupported | Plan-neutral dynamic OAuth bucket discovery |
| Managed Claude login breaks after enrollment | Stable absolute config path from login through ledger commit |
| Interactive Keychain writes truncate the OAuth document | Provider-compatible `security -X` data writes plus a long-value regression check |

## Remaining roadmap risks

- Add signed adapter packages and optional sandbox profiles.
- Prefer opaque provider account IDs when vendors expose them; current deduplication uses the already-sanitized identity fields in snapshots.
- Add a structured Codex browser/device-code login UI rather than the CLI fallback.
- Add a redacted interactive login console for Claude callback failures.
- Add launch-at-login management and a WidgetKit/App Group snapshot bridge.

## Reporting a vulnerability

Do not include live credentials, auth files, or private account snapshots in a public issue. Use GitHub's private vulnerability-reporting feature if it is enabled for the published repository. Otherwise, contact the maintainer privately before sharing sensitive reproduction material.
