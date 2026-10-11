<div align="center">
  <img align="center" width="250" src="assets/logos/syft-orb-256px.png?v=2" alt="Syft Orb">
  <h1>CircleCI Syft Orb</h1>
  <i>A CircleCI orb for streamlining Syft integration and SBOM generation.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/syft-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/syft-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/syft-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/syft-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/syft-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This unofficial Syft orb facilitates the installation and execution of Syft within CircleCI pipelines, primarily for generating Software Bill of Materials (SBOMs) for container images, RPM packages, and DEB packages. Contributions are welcome.

## Installation
Use the installation command to add the `syft` binary to your CircleCI job:

```yaml
orbs:
  syft: juburr/syft-orb@latest

jobs:
  sbom_generation:
    docker:
      - image: cimg/base:current-22.04
    steps:
      - syft/install
```

### Checksum verification
The installer checks the SHA-512 checksum of the downloaded `syft` binary against a lookup table built into this orb. By default it fails closed: if the requested `version` has no checksum in the table, the install fails before anything is downloaded.

| `verify_checksums` | Behaviour |
| --- | --- |
| `strict` (default) | Verify the binary; fail if the version has no known checksum. |
| `known_versions` | Verify known versions; install unknown versions **without** verification. |
| `false` | Skip verification entirely (not recommended). |

The same parameter is available on the `syft/sbom` job.

> **Upgrading to v0.10.0:** the default changed from `known_versions` to `strict`. If you pin a Syft `version` that is newer than this orb release knows about, the install now fails instead of installing an unverified binary. Upgrade the orb to a release that includes that version, or opt out explicitly:
>
> ```yaml
> - syft/install:
>     version: "1.99.0"
>     verify_checksums: known_versions
> ```

### Supported platforms
The installer detects the executor's platform with `uname` and downloads the matching Syft build:

| `uname -m` | Syft build |
| --- | --- |
| `x86_64` | `linux_amd64` |
| `aarch64` / `arm64` | `linux_arm64` |

Any other architecture, or a non-Linux executor, is a hard error. Checksums are recorded per version and architecture; Linux arm64 builds exist from Syft 0.28.0 onward. The install cache key includes the architecture, so amd64 and arm64 jobs never share a cached binary.

To run the `syft/sbom` job on arm64, pick an Arm resource class (the default `cimg/base` image is multi-arch):

```yaml
- syft/sbom:
    source: "dir:."
    resource_class: arm.medium
```

## Quick Start with the SBOM Job
The simplest way to generate SBOMs is using the `syft/sbom` job, which handles installation and generation in one step. By default, it produces both SPDX and CycloneDX formats:

```yaml
workflows:
  main:
    jobs:
      - syft/sbom:
          source: "gcr.io/distroless/static:latest"
```

You can customize the output formats:

```yaml
- syft/sbom:
    source: "dir:."
    output_formats: "spdx-json,cyclonedx-json,syft-json"
```

## Container Image SBOMs
Generate SBOMs for container images using the `generate_sbom` command. Output filenames are auto-generated based on the source, and you can produce multiple formats in a single scan:

```yaml
 - syft/generate_sbom:
     source: ghcr.io/myorganization/customapp:1.0.0
     output_formats: "spdx-json,cyclonedx-json"
```

This produces `sboms/customapp-1.0.0.spdx.json` and `sboms/customapp-1.0.0.cdx.json`.

## Rust Binaries (cargo-auditable)
Binaries built with [`cargo auditable build`](https://github.com/rust-secure-code/cargo-auditable) embed their resolved crate list. Syft's `cargo-auditable-binary-cataloger` reads it with the default settings for `file:`, `dir:` and container image sources, so no extra parameters are needed:

```yaml
- syft/generate_sbom:
    source: file:target/release/myapp
    output_formats: "spdx-json,cyclonedx-json"
- syft/generate_sbom:
    source: ghcr.io/myorganization/myapp:1.0.0
```

A binary built with plain `cargo build` carries no dependency data, so its SBOM will not list any crates; scan the `Cargo.lock` with a `dir:` source instead.

## RPM SBOMs
For RPM packages, this orb enhances scanning by unpacking the RPM contents using `rpm2archive`. This approach produces more comprehensive results by scanning individual files rather than treating the RPM as a single unit, often revealing dependencies and vulnerabilities that would otherwise remain undetected.

```yaml
 - syft/generate_sbom:
     source: ./rpms/customapp*.el9.x86_64.rpm
     output_formats: spdx-json
```

## DEB SBOMs
For Debian packages, the orb extracts contents using `dpkg-deb` before scanning, providing the same comprehensive analysis as RPM packages:

```yaml
 - syft/generate_sbom:
     source: ./debs/myapp_*_amd64.deb
     output_formats: spdx-json
```
