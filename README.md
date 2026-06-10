# Envora Runtime Packages

Envora Runtime Packages is the dedicated binary asset repository for Envora.

This repository stores prebuilt runtime packages, checksums, and release notes
for runtimes and developer toolchains consumed by the main
[`Simoon-F/envora`](https://github.com/Simoon-F/envora) application.

The goal is to keep application releases and binary asset releases separate:

- `envora` publishes the desktop app, source code, roadmap, and docs.
- `envora-runtime-packages` publishes runtime binaries and related metadata.

## What Lives Here

- Precompiled runtime archives
- Checksum files such as `.sha256`
- Release-specific packaging notes
- Build and publish workflow definitions
- Runtime manifests for discovery and integrity checks

## Naming Convention

Release tags:

```text
{runtime}-{version}
```

Examples:

```text
php-8.4.8
node-22.16.0
go-1.24.5
```

Asset filenames:

```text
{runtime}-{version}-{platform}-{arch}.{ext}
```

Examples:

```text
php-8.4.8-macos-arm64.tar.gz
php-8.4.8-macos-x86_64.tar.gz
node-22.16.0-windows-x64.zip
go-1.24.5-linux-x86_64.tar.gz
```

Recommended companion assets:

```text
{filename}.sha256
{runtime}-{version}-manifest.json
```

## Current Scope

Current and near-term targets:

- PHP prebuilt packages for macOS
- Packaging conventions for future runtimes and toolchains

PHP packages should include common official extensions as loadable `.so`
modules wherever possible. Envora can then enable or disable those modules from
the desktop UI based on each project's needs, while keeping the default
`php.ini` conservative.

Planned expansion:

- Node.js
- Rust
- Go
- Java
- npm
- pnpm
- yarn

## Repository Structure

```text
.
├── assets/               # Runtime config templates bundled into packages
├── docs/                 # Release and packaging documentation
├── scripts/              # Runtime build, package, verify, and manifest scripts
└── .github/workflows/    # Build and publish workflows
```

This repository may stay intentionally light in source code and heavy in release
assets, workflow automation, and packaging notes.

## PHP Package Pipeline

The PHP macOS workflow is split into explicit stages:

```text
scripts/php/build-php-macos.sh
scripts/php/package-macos-runtime.sh
scripts/php/verify-macos-runtime.sh
scripts/php/write-manifest.sh
```

Packages are published only after verification passes. Verification checks that
the packaged runtime can start, common extensions are present and loadable, and
Mach-O dependencies no longer reference Homebrew paths such as `/opt/homebrew`
or `/usr/local`.

## Relationship To Envora

The main Envora application downloads runtime assets from this repository's
GitHub Releases. Runtime discovery should use the release manifest whenever
possible. For example, a PHP release includes:

```text
php-{version}-manifest.json
```

The manifest contains platform-specific URLs, checksums, minimum macOS version,
and packaged extension names.

## Publishing Principles

- Keep app releases and runtime releases independent
- Use predictable tags and filenames
- Prefer reproducible automated builds
- Ship checksums with every binary asset
- Document platform-specific packaging differences

## License

This repository should follow the same licensing direction as the main Envora
project unless stated otherwise.
