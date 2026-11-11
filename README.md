# PING.R4X

`PING.R4X` is an independent R4OS application implemented in Zig.

## Package

- Package version `0.1.4`
- Image target: `/R4OS/SOFTWARE/TERMINAL/PING.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

## API migration 0.90.69

The normal build selects SDK202, App2, R4XStart2 and platform Query2.
The exact dependencies and ordered imports belong to module.R4MF.

PING [-t] [-4|-6] address|hostname retains three default echoes and the
continuous -t mode. Hostnames default to A. -6 selects AAAA. Link-local
IPv6 requires an explicit numeric interface identity. Actual route prefix
and metric select the global IPv6 interface. Equal ambiguous routes fail
explicitly. Provider/link generation and chosen source remain bound. The
external ICMPv6 codec owns pseudoheader checksum sealing. Each attempt and
delay uses a checked finite absolute budget. Replies match addresses, ID,
sequence and all16 payload bytes. Clock changes/regression end the caller.
