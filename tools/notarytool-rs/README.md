# notarytool-rs

`notarytool-rs` is a cross-platform Rust client for Apple's Notary API. It
replaces the API-key-authenticated upload and status portions of Xcode's
`notarytool`; it does not sign software or staple tickets. Signing and stapling
remain macOS operations.

Production releases normally use Xcode Cloud. The only exception is the 0.9.1
Developer ID certificate bridge documented in `docs/build-release.md`: its
already-signed App and locally packaged DMG may be notarized with this tool.
The exception expires after 0.9.1 and does not authorize rebuilding or
re-signing the accepted App.

The implementation follows Apple's documented workflow:

1. Sign a short-lived App Store Connect JWT with ES256.
2. Create a submission with the exact artifact name and SHA-256.
3. Upload the same bytes with the temporary Amazon S3 credentials.
4. Query or wait for the result and download the developer log.

Temporary S3 credentials, JWTs, and private-key contents are never printed or
written to state. A submission ID is durably stored before upload starts.

## Build

Rust 1.82 or newer is required:

```bash
cd tools/notarytool-rs
cargo build --release --locked
```

Generate and commit `Cargo.lock` before the first distributable build:

```bash
cargo generate-lockfile
cargo test --locked
cargo clippy --all-targets --locked -- -D warnings
```

## Credentials

Create an App Store Connect API key with access to the Notary API. Keep the
downloaded `.p8` file private (`0600` or `0400` on Unix). Team keys use an
issuer ID:

```bash
export APPLE_NOTARY_KEY_ID='YOUR_KEY_ID'
export APPLE_NOTARY_ISSUER_ID='YOUR_ISSUER_UUID'
export APPLE_NOTARY_PRIVATE_KEY='/absolute/path/AuthKey_YOUR_KEY_ID.p8'
```

For an App Store Connect individual API key, omit the issuer and pass
`--individual-key` (or set `APPLE_NOTARY_INDIVIDUAL_KEY=true`).

## Commands

Submit and wait:

```bash
notarytool-rs submit ./MihomoBox-0.9.1-macos.zip --wait
```

The default state path is `<artifact>.notary.json`. It is an append-only JSON
Lines journal, so the last complete record survives a process interruption. If
the process exits after Apple creates the submission, the ID is still
available there. Resume polling without creating a duplicate:

```bash
notarytool-rs resume --state ./MihomoBox-0.9.1-macos.zip.notary.json
```

Other operations:

```bash
notarytool-rs history
notarytool-rs info SUBMISSION_UUID
notarytool-rs wait SUBMISSION_UUID --timeout 30m
notarytool-rs log SUBMISSION_UUID --output notarization-log.json
```

Use `--output-format json` for automation. S3 Transfer Acceleration is enabled
by default, matching Apple's documented example. Set `--no-s3-acceleration`
only when diagnosing an upload path. The initial signing region defaults to
`us-east-1`; an S3 `x-amz-bucket-region` response is followed and re-signed.

## Recovery contract

- An existing state file blocks a new submission for the same invocation.
- `resume` never uploads or creates a submission.
- If the state says upload was incomplete, `resume` asks Apple for the actual
  status and refuses to invent or persist expired S3 credentials.
- If notarization is `Invalid` or `Rejected`, fetch the developer log and make
  a new signed artifact rather than deleting the state.

## Official references

- <https://developer.apple.com/documentation/notaryapi>
- <https://developer.apple.com/documentation/notaryapi/submitting-software-for-notarization-over-the-web>
- <https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests>
