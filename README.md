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

## Limiting What Gets Scanned
Directory scans pick up everything under the scan root, including build output, vendored code and dependency trees. Use `exclude`, `config` and `select_catalogers` (on both `generate_sbom` and the `syft/sbom` job) to keep an inventory focused:

```yaml
- syft/sbom:
    source: "dir:."
    exclude: "./target/**,**/node_modules/**,./ref/**"
```

- `exclude` takes comma- or newline-separated globs, each passed to syft as `--exclude`. For `dir:` and `file:` sources and extracted RPM/DEB packages, patterns are relative to the scan root and must start with `./`, `*/` or `**/` (syft rejects anything else). For container images, patterns match absolute paths inside the image, such as `/usr/share/doc/**`. Brace alternations like `./{target,ref}/**` are kept intact.
- `config` points syft at a configuration file (`--config`) for anything the orb doesn't expose. Non-empty `exclude` and `select_catalogers` parameters replace the same keys in the file rather than merging with them. Without `config`, syft still loads a `.syft.yaml` from the working directory if one exists. RPM and DEB sources are scanned from a temporary extraction directory, so path-valued settings in the file (such as `format.template.path`) should be absolute when scanning packages.
- `select_catalogers` is passed to `--select-catalogers` and adjusts the default cataloger set for the source type: `+name` adds a cataloger, `-name` or `-tag` removes catalogers, and an unprefixed tag such as `rust` keeps only the default catalogers carrying that tag (syft rejects unprefixed cataloger names). For example, `-file` skips file metadata and `+sbom-cataloger` adds the SBOM cataloger. To replace the default set entirely, set `default-catalogers` in a config file. Run `syft cataloger list` to see names and tags.

Syft already ignores JavaScript lockfiles inside `node_modules`, but it still walks those trees and catalogs other ecosystems' manifests there (for example the `Cargo.lock` that native npm packages ship), so excluding them keeps the inventory accurate and the scan fast.

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

## Info for Security Teams

### Required external access
Hosts below were determined from the Syft v1.52.0 source (the orb's default version). The default Syft, GitHub, registry and package-ecosystem endpoints listed use outbound HTTPS (port 443). Endpoints you configure yourself use whatever scheme and port they specify: a custom `GOPROXY` or Syft config URL, git registries declared in `vcpkg-configuration.json` (which may use SSH, e.g. `git@host:org/repo`), and distribution package mirrors (see below, often plain HTTP).

**Installing Syft** (`syft/install`, also run by the `syft/sbom` job). Skipped on a CircleCI cache hit.

| Host | Purpose |
| --- | --- |
| `github.com` | Syft release download (`/anchore/syft/releases/download/...`) |
| `release-assets.githubusercontent.com` | Where GitHub currently redirects release downloads |
| `objects.githubusercontent.com` | GitHub's previous redirect target for release downloads; allow it as well |

**Enrichment** (`enrich` other than `none`). Note that this orb defaults to `enrich: all`, whereas Syft on its own enables no enrichment. Requests are only made for packages that the matching catalogers actually find.

| `enrich` | Hosts contacted | Override in a Syft `config` file |
| --- | --- | --- |
| `golang` | `proxy.golang.org` (or `$GOPROXY`), which may redirect module downloads to `storage.googleapis.com`. For modules the proxy cannot serve, and for modules matching `GOPRIVATE`/`GONOPROXY`, Syft falls back to `direct`: a shallow git clone over HTTPS from the module path's host (e.g. `github.com`), so any VCS host may be contacted. | `golang.proxy`, `golang.no-proxy` |
| `java` | `repo1.maven.org` (Maven Central) | `java.maven-url` |
| `javascript` | `registry.npmjs.org` | `javascript.npm-base-url` |
| `python` | `pypi.org` | `python.pypi-base-url` |
| `vcpkg` | `github.com` (git clone of `microsoft/vcpkg`), plus any git registries declared in the project's `vcpkg-configuration.json` | `cpp.vcpkg-allow-git-clone: false` disables cloning |
| `all` | All of the above | |

**Scanning, independent of `enrich`:**

- Container images referenced by name are pulled from their registry, plus that registry's auth and blob hosts. For Docker Hub (including unqualified names such as `ubuntu:latest`) that is `registry-1.docker.io`, `auth.docker.io` and its layer CDNs `production.cloudfront.docker.com` and `production.cloudflare.docker.com`. Loading `docker-archive:`, `oci-archive:` and `oci-dir:` sources needs no network, but the enrichment above still applies to the packages found inside them.
- For RPM and DEB sources, if `rpm2archive` or `tar` (RPM) or `dpkg-deb` (DEB) is missing, the orb installs it with `apt-get`, `dnf` or `yum`, which contacts the distribution mirrors configured in the executor image, using their configured scheme (Ubuntu images commonly use `http://archive.ubuntu.com`). `cimg/base` ships `dpkg-deb` but not `rpm`.
- If a Go toolchain is on `PATH` and a `go.mod` is in scope, Syft runs `go list` for every `enrich` value except `none` (including non-Go values such as `javascript`), or whenever a config file sets `golang.use-packages-lib: true`. It can download missing modules through `GOPROXY` (`proxy.golang.org`, possibly redirecting to `storage.googleapis.com`), fall back to the module's own VCS host (any host, e.g. `github.com`) for private modules or ones the proxy cannot serve, because the default `GOPROXY` ends in `direct`, and check hashes missing from `go.sum` against `GOSUMDB` (`sum.golang.org`). With other `enrich` values, set `SYFT_GOLANG_USE_PACKAGES_LIB=false` to stop Syft from running `go list`. `cimg/base` has no Go toolchain.
- Syft's start-up update check (`toolbox-data.anchore.io`) is disabled for scans run through `syft/generate_sbom` and the `syft/sbom` job, which set `SYFT_CHECK_FOR_APP_UPDATE=false` since the orb pins the version (a value you set yourself takes precedence). If you run `syft` directly after `syft/install`, set `SYFT_CHECK_FOR_APP_UPDATE=false` in your job to avoid the request.

### Disconnected builds
`enrich: none` is the disconnected-build setting: the orb passes `--enrich none` to Syft, which also overrides an `enrich` list in a config file or `.syft.yaml`. Per-ecosystem network settings in a config file (for example `javascript.search-remote-licenses: true`, `java.use-network: true` or `golang.use-packages-lib: true`) or in the equivalent environment variables (`SYFT_JAVASCRIPT_SEARCH_REMOTE_LICENSES`, `SYFT_JAVA_USE_NETWORK`, `SYFT_GOLANG_USE_PACKAGES_LIB`, ...) still take precedence over `--enrich`, so leave them unset or set them to `false`. For a build with no egress at all, also:

- provide `syft` in the executor image and use the `syft/generate_sbom` command in your own job instead of `syft/install` or the `syft/sbom` job;
- scan local sources only (`dir:`, `file:`, `docker-archive:`, `oci-archive:`, `oci-dir:`, or an image already in the local daemon via `docker:`);
- for RPM or DEB sources, preinstall `rpm2archive` (from the `rpm` package), `tar` and `gzip`, or `dpkg-deb`, in the executor image, since the orb otherwise tries to install them from the distribution mirrors.
