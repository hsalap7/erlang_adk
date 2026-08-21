# Curated connector packages

Each connector is an independent Hex package with a one-way dependency on
`erlang_adk ~> 0.10.0`. The `_checkouts/erlang_adk` symlink used by local tests
must not be treated as published dependency metadata: `rebar3_hex` omits
checkout dependencies when it creates `rebar.lock`.

Run the complete connector release gate from the repository root:

```console
$ packages/build_connector_packages.sh
```

This is the sole supported command for offline connector package validation.
It runs warning-strict source compilation and EUnit, builds and normalizes all
four Hex archives, prints their package and documentation SHA-256 hashes,
rejects checkout leakage, and reruns compilation and EUnit from clean extracted
archives.

The package-owned normalizer reads the dependency requirement from each
package's `rebar.config`, verifies that its OTP application depends on
`erlang_adk`, recreates the archive through Hex's own `hex_tarball`
implementation, and verifies the resulting archive and checksum. It rejects
non-Hex dependency forms, version drift, and conflicting pre-existing
metadata. Do not retain or publish the intermediate tarball produced by a raw
`rebar3 hex build` while the local checkout is active.

The normalized tarballs are inspection evidence, not inputs accepted by
`rebar3 hex publish`: rebar3_hex 7.1.0 rebuilds a package during publication and
does not accept an existing tarball. Connector publication therefore remains
blocked until `erlang_adk` 0.10.0 has been published to the target Hex
repository. For an actual connector publication, first remove the package's
`_checkouts/erlang_adk`, resolve a fresh lock whose top-level `erlang_adk`
entry is a Hex package at 0.10.0, run ordinary `rebar3 hex publish`, and verify
the published release's server-side requirements. None of those external
publication steps is performed by the offline gate.
