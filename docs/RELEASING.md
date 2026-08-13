# Releasing Cappy

Tags matching `v*` run the GitHub Actions release workflow. The workflow builds the Apple-silicon app, signs every executable and the app bundle with hardened runtime and a secure timestamp, submits the archive to Apple for notarization, staples the ticket, regenerates the DMG and checksum, signs a Sparkle appcast, publishes the files to the GitHub Release, and commits the matching version and checksum to the Homebrew tap. A release run is successful only after both repositories are synchronized.

## Versioning

Cappy uses semantic versions in `MAJOR.MINOR.PATCH` form. Routine fixes and incremental improvements increase only `PATCH`. A `MAJOR` or `MINOR` change requires an explicit release decision from the project owner; no workflow or script changes either component automatically.

Update both `quotaReleaseVersion` in `Sources/QuotaContracts/Models.swift` and `CFBundleShortVersionString` in `macos/Info.plist`, and increase the integer `CFBundleVersion` for every release. The packaging script rejects a tag that does not exactly match the source version.

## Release credentials

Keep credentials only in the protected GitHub Actions environment named `release`. That environment permits deployment only from tags matching `v*`. Do not commit certificate archives, private keys, passwords, key IDs, issuer IDs, team IDs, or certificate subject names.

Configure these environment secrets:

| Secret | Value |
| --- | --- |
| `MACOS_SIGNING_CERTIFICATE` | Base64-encoded PKCS#12 archive containing one Developer ID Application certificate and its private key |
| `MACOS_SIGNING_CERTIFICATE_PASSWORD` | Strong, unique password used only for that PKCS#12 archive |
| `APPLE_NOTARY_PRIVATE_KEY` | Contents of the team App Store Connect API `.p8` private key |
| `APPLE_NOTARY_KEY_ID` | Key ID for that API key |
| `APPLE_NOTARY_ISSUER_ID` | Issuer ID for the App Store Connect team |
| `SPARKLE_PRIVATE_KEY` | Base64-encoded Ed25519 private seed matching `SUPublicEDKey` in `macos/Info.plist` |
| `HOMEBREW_TAP_DEPLOY_KEY` | Private SSH deploy key with write access only to the Homebrew tap repository |

Use these neutral names in the Apple portals and local keychain:

- Certificate signing request common name: `Cappy Release Signing`
- App Store Connect team API key: `Cappy Release Notarization`
- Sparkle signing key: `Cappy Software Updates`
- Homebrew tap deploy key: `Cappy Release Homebrew Sync`
- GitHub environment: `release`

The notarization key should have the least role that successfully permits `notarytool`; start with the `Developer` role. Use a team API key because individual API keys cannot authenticate `notarytool`. Keep the Sparkle private key only in the protected release environment; the app contains only its public key. Attach the Homebrew deploy key only to the tap repository and enable write access; never reuse it for another repository or account.

## Sparkle signing key

The recovery copy of Cappy's update key is stored in the release maintainer's login Keychain under the Sparkle account `ai.upriver.cappy`. After resolving Swift packages, Sparkle's key tool is at `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. Use `--account ai.upriver.cappy -p` to print only the public key or `--account ai.upriver.cappy -x <protected-file>` to make a short-lived private-key export for restoring the `SPARKLE_PRIVATE_KEY` environment secret. Never print that export in a log or commit it.

Do not replace the public key and secret as an ordinary credential rotation. Existing installations trust the public key embedded in their current bundle; follow Sparkle's signing-key rotation procedure through an intermediate signed application update.

## Rotation

1. Generate the replacement credential without revoking the active credential.
2. Replace the corresponding `release` environment secrets.
3. Publish and verify one notarized test release.
4. Revoke the superseded Apple credential.

For the Homebrew deploy key, create a replacement key pair, add the replacement public key to the tap, replace `HOMEBREW_TAP_DEPLOY_KEY`, verify a release or authenticated dry run, and then delete the old tap deploy key.

If a private key, certificate archive, or archive password may have been exposed, revoke the affected Apple credential immediately, replace every related GitHub secret, and inspect release history for unauthorized artifacts.
