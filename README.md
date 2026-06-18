# Tappy (Direct Download)

The **Developer ID / direct-download** build of Tappy — the macOS menu-bar app that
plays satisfying sounds as you type.

This repository is the **non-sandboxed** distribution of Tappy, delivered as a
notarized `.dmg` outside the Mac App Store. The Mac App Store build lives in a
separate repository.

## Why a separate, non-sandboxed build?

Tappy's core feature is system-wide auditory typing feedback, implemented with a
**listen-only `CGEventTap`** (macOS **Input Monitoring**). The App Sandbox
forbids global event taps, so a sandboxed build can never obtain Input
Monitoring — macOS won't even show the permission prompt. This build therefore
ships **without** the App Sandbox so the Input Monitoring prompt appears and the
feature works.

- App Sandbox: **off** (`ENABLE_APP_SANDBOX = NO`, no `com.apple.security.app-sandbox` entitlement)
- Hardened Runtime: **on** (applied at sign time, required for notarization)
- Bundle identifier: `com.castao.tappy-direct`
- Distribution: Developer ID Application, notarized + stapled, served as `Tappy.dmg`

## Build & release

A notarized release is produced locally on a Mac with the Developer ID
certificate installed:

```bash
# Build, sign (Developer ID), and notarize the DMG in one step.
# Reads Apple credentials from build/certificates/github-secrets.env
# (or the matching environment variables).
./scripts/manual-notarized-release.sh
```

This produces:

- `build/Tappy.dmg`
- `build/Tappy.dmg.sha256`

Publish them to GitHub Releases so the website download resolves:

```bash
gh release create v1.0.6 build/Tappy.dmg build/Tappy.dmg.sha256
```

The marketing site links to `releases/latest/download/Tappy.dmg`.

## Verifying a build

```bash
# Confirm the app is NOT sandboxed:
codesign -d --entitlements :- /Applications/Tappy.app   # no app-sandbox key

# Confirm Developer ID + notarization:
codesign -dvvv /Applications/Tappy.app                  # flags=...(runtime)
spctl -a -vvv -t exec /Applications/Tappy.app           # accepted / Notarized
```

To re-trigger the Input Monitoring setup flow during testing:

```bash
./reset-tappy-permissions.command
```

## Licensing / purchases

Premium unlock uses the hosted checkout + license API at
`https://tappy-plum.vercel.app` (`DirectLicenseStore`). The custom URL scheme
`tappy://` receives the post-checkout callback. The website and purchase API are
maintained in the main `Tappy` repository.
