# Contributing

## Before opening a change

1. Run `make test` on macOS 14 or newer.
2. Run `make lint`.
3. If UI code changed, run `make app` and inspect `docs/preview.png`.
4. Do not commit `.build/`, `build/`, application-support state, provider configuration, auth files, tokens, or screenshots containing real account identity.

Provider payloads belong in adapter-specific normalizers. Keep raw payloads and credentials out of `QuotaContracts`, the app-server state, UI clients, fixtures, logs, and error messages. Fixtures must use reserved example identities such as `user@example.com`.

New adapters should be separate executables implementing [Adapter Protocol v1](docs/adapter-protocol-v1.md). Include normalization tests for unknown/dynamic meter keys and malformed input, and document whether the provider interface is public, private, or best-effort.

Security-sensitive changes should update [SECURITY.md](SECURITY.md). Do not post live credentials or private account snapshots in an issue.
