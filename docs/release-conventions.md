# Release Conventions

This repository publishes binary assets for Envora runtime and toolchain
management.

## Release URL Format

```text
https://github.com/Simoon-F/envora-runtime-packages/releases/download/{tag}/{filename}
```

## Tag Format

```text
{runtime}-{version}
```

Examples:

```text
php-8.4.8
node-22.16.0
rust-1.89.0
```

## Filename Format

```text
{runtime}-{version}-{platform}-{arch}.{ext}
```

Examples:

```text
php-8.4.8-macos-arm64.tar.gz
php-8.4.8-macos-x86_64.tar.gz
node-22.16.0-windows-x64.zip
java-21.0.7-linux-x86_64.tar.gz
```

## Companion Assets

Each release should include:

- Binary archives
- `.sha256` checksum files
- `{runtime}-{version}-manifest.json`
- Short release notes

Optional future assets:

- signature files
- SBOM or provenance artifacts

## Platform Labels

Recommended platform tokens:

- `macos`
- `windows`
- `linux`

Recommended architecture tokens:

- `arm64`
- `x86_64`
- `x64` when required by upstream Windows naming conventions

## Notes

- Prefer one release tag per runtime version.
- Keep filenames stable over time.
- Avoid mixing application assets into this repository.
- Keep source code for the desktop application in `Simoon-F/envora`.
