# Releasing Cappy

Tags matching `v*` run the GitHub Actions release workflow. The workflow builds the Apple-silicon app, signs every executable and the app bundle with hardened runtime and a secure timestamp, submits the archive to Apple for notarization, staples the ticket, regenerates the ZIP and checksum, and publishes both files to the GitHub Release.

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

Use these neutral names in the Apple portals and local keychain:

- Certificate signing request common name: `Cappy Release Signing`
- App Store Connect team API key: `Cappy Release Notarization`
- GitHub environment: `release`

The notarization key should have the least role that successfully permits `notarytool`; start with the `Developer` role. Use a team API key because individual API keys cannot authenticate `notarytool`.

## Rotation

1. Generate the replacement credential without revoking the active credential.
2. Replace the corresponding `release` environment secrets.
3. Publish and verify one notarized test release.
4. Revoke the superseded Apple credential.

If a private key, certificate archive, or archive password may have been exposed, revoke the affected Apple credential immediately, replace every related GitHub secret, and inspect release history for unauthorized artifacts.
