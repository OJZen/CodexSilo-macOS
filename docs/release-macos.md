# macOS Release Workflow

## Scope
- Builds the macOS `CodexSilo.app` from `CodexSilo.xcodeproj`
- Exports a Developer ID signed `.app`
- Optionally notarizes it with `asc` or `notarytool`
- Packages a distributable zip and checksum
- Performs archive/export/signing work in a temporary directory to avoid file-provider signing issues
- Optionally creates or updates a GitHub Release

## Prerequisites
- Xcode command line tools
- A valid `Developer ID Application` certificate in the local keychain
- A matching macOS Developer ID provisioning profile for `com.alick.codexsilo`
- One notarization path configured:
  - `asc auth login`
  - or a `notarytool` keychain profile

## Recommended Flow
```bash
DEVELOPMENT_TEAM="KLU8GF65GP" \
NOTARIZE_WITH=asc \
CREATE_GITHUB_RELEASE=1 \
./scripts/release_macos.sh
```

## Notarization Backends

### `asc`
Use this when `asc auth login` is already configured:
```bash
NOTARIZE_WITH=asc ./scripts/release_macos.sh
```

### `notarytool`
Use this when a keychain profile already exists:
```bash
NOTARIZE_WITH=notarytool \
NOTARY_PROFILE="your-notary-profile" \
./scripts/release_macos.sh
```

### Skip notarization
Useful for local validation only:
```bash
NOTARIZE_WITH=skip ./scripts/release_macos.sh
```

## Useful Environment Variables
- `PROJECT_PATH`
- `SCHEME`
- `CONFIGURATION`
- `DEVELOPMENT_TEAM`
- `CODESIGN_IDENTITY`
- `SIGNING_STYLE`
- `PROVISIONING_PROFILE_SPECIFIER`
- `PRODUCT_BUNDLE_IDENTIFIER`
- `WORK_ROOT`
- `KEEP_WORK_ROOT`
- `AUTO_DETECT_PROFILE`
- `NOTARIZE_WITH`
- `NOTARY_PROFILE`
- `CREATE_GITHUB_RELEASE`
- `GITHUB_REPOSITORY`
- `GH_RELEASE_NOTES`

## Output
- Signed or notarized zip under `artifacts/macos-release/`
- SHA256 file next to the zip

## Notes
- The script uses `xcodebuild archive` and `xcodebuild -exportArchive` with `method=developer-id`.
- Archive, export, and notarization run under `${TMPDIR}` by default; set `WORK_ROOT` if you need a stable working directory.
- Default signing mode starts as `Automatic`, but the script will promote itself to `Manual` when it finds a matching `Developer ID` provisioning profile for the bundle id.
- Set `SIGNING_STYLE=Manual` only when you explicitly need to pair a named provisioning profile with the bundle id.
- Set `AUTO_DETECT_PROFILE=0` if you want to disable profile auto-resolution and keep Xcode's automatic signing behavior.
- The script keeps the exported `.app` in the temporary work root; the repo-local release artifacts intentionally contain only the distributable zip and checksum.
- When notarization succeeds, it staples the ticket and regenerates the zip as `*-macOS-notarized.zip`.
- When notarization is skipped, the output stays `*-macOS-signed.zip`.
- Set `KEEP_WORK_ROOT=1` if you want to inspect the archive or export products after the script finishes.
