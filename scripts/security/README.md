# Container supply-chain helpers

The scripts in this directory are intentionally credential-free and accept
only immutable image references for inspect/sign/attest operations.

1. `build-image.sh` requires digest-pinned build and runtime bases. Without
   `--apply` it emits a local OCI layout with BuildKit SBOM and maximum
   provenance; `--apply` is the explicit push boundary.
2. `generate-sbom.sh` writes a CycloneDX JSON SBOM with Syft.
3. `scan-sbom.sh` writes SARIF with Grype and fails at `high` by default.
4. `sign-image.sh` and `attest-provenance.sh` are dry by default. In a trusted
   release job, `--apply` invokes Cosign keyless signing/attestation using the
   job's ambient OIDC identity.

Pin Syft, Grype, Cosign, Docker Buildx, base images, and runner images in the
calling CI system. Store release evidence outside the source tree and verify
the Cosign identity/issuer policy before promotion.
