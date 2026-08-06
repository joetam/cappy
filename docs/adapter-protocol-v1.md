# Adapter Protocol v1

An adapter is an executable implementing a one-request/one-response JSON protocol over stdio.

## Manifest

Place a JSON manifest in `~/Library/Application Support/Cappy/adapters`. An upgraded installation still using the pre-Cappy state directory reads `~/Library/Application Support/QuotaBar/adapters` instead:

```json
{
  "protocolVersion": 1,
  "providerID": "example-provider",
  "displayName": "Example",
  "executable": "/absolute/path/to/quota-adapter-example",
  "arguments": [],
  "environment": {}
}
```

Provider IDs are stable lowercase identifiers. Built-in IDs cannot be overridden by external manifests.

## Request

```json
{
  "protocolVersion": 1,
  "operation": "refresh",
  "profile": {
    "id": "example-default",
    "providerID": "example-provider",
    "label": "Example",
    "configPath": "/path/to/provider/config",
    "isManaged": false,
    "isDefault": true,
    "createdAt": "2026-08-05T12:00:00Z"
  },
  "context": {
    "quotaCachePath": "/path/to/sanitized/cache.json",
    "clientExecutablePath": "/path/to/quota"
  }
}
```

Operations:

- `describe`: return a `ProviderDescriptor`.
- `refresh`: authenticate through provider-owned state and return an `AccountSnapshot`.
- `prepareLogin`: return a `LoginCommand`; never return credentials.
- `configure`: install optional non-secret integration support without replacing existing user configuration silently.

## Response

```json
{
  "protocolVersion": 1,
  "ok": true,
  "snapshot": {
    "contractVersion": 1,
    "profileID": "example-default",
    "provider": { "id": "example-provider", "displayName": "Example" },
    "profileLabel": "Example",
    "authenticationState": "authenticated",
    "subscription": { "planName": "Pro" },
    "meters": [],
    "observedAt": "2026-08-05T12:00:00Z",
    "freshness": "fresh"
  },
  "warnings": []
}
```

Adapter stdout must contain only the response JSON. Diagnostics belong on stderr and must never contain tokens.

The app server launches adapters with a restricted environment: common process, locale, proxy, certificate, and the documented `CAPPY_STATE_DIR`, `CAPPY_ADAPTER_DIR`, `CAPPY_CODEX_PATH`, and `CAPPY_CLAUDE_PATH` variables are retained, while unrelated exported credentials are not forwarded. The corresponding pre-Cappy `QUOTABAR_*` names remain accepted for compatibility. Put required non-secret configuration in the manifest `environment` object. Adapters remain trusted user-installed executables, not an OS sandbox.

## Meter rules

- Preserve every provider bucket that has quota semantics, even when its name is unknown.
- IDs are stable within a provider and profile.
- `usedFraction` is `0...1`; the daemon clamps it defensively.
- `resetsAt` is an ISO-8601 date.
- `scope.kind` is extensible; current values include `account`, `model-family`, and `credits`.
- Meter `source` names the provider interface used to obtain it.
- The adapter suggests `priority`; the UI may adapt presentation but must not merge semantically different meters.
- Never place secrets or raw provider payloads in `details`.
