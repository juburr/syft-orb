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
Hosts below were determined from the Syft v1.52.0 source (the orb's default version). The Syft, GitHub, registry and package-ecosystem endpoints listed use outbound HTTPS (port 443); distribution package mirrors (see below) use whatever scheme the executor's package sources specify, which is often plain HTTP.

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

- Container images referenced by name are pulled from their registry, plus that registry's auth and blob hosts. For Docker Hub (including unqualified names such as `ubuntu:latest`) that is `registry-1.docker.io`, `auth.docker.io` and `production.cloudflare.docker.com`. `docker-archive:`, `oci-archive:` and `oci-dir:` sources need no network.
- For RPM and DEB sources, if `rpm2archive` or `dpkg-deb` is missing, the orb installs it with `apt-get`, `dnf` or `yum`, which contacts the distribution mirrors configured in the executor image, using their configured scheme (Ubuntu images commonly use `http://archive.ubuntu.com`). `cimg/base` ships `dpkg-deb` but not `rpm`.
- If a Go toolchain is on `PATH` and a `go.mod` is in scope, Syft runs `go list`, which can download missing modules through `GOPROXY` (`proxy.golang.org`, possibly redirecting to `storage.googleapis.com`) and check them against `GOSUMDB` (`sum.golang.org`) when `go.sum` lacks their hashes, regardless of `enrich`. Set `SYFT_GOLANG_USE_PACKAGES_LIB=false` (or `GOPROXY=off`) to prevent this. `cimg/base` has no Go toolchain.
- Syft's start-up update check (`toolbox-data.anchore.io`) is disabled for scans run through `syft/generate_sbom` and the `syft/sbom` job, which set `SYFT_CHECK_FOR_APP_UPDATE=false` since the orb pins the version (a value you set yourself takes precedence). If you run `syft` directly after `syft/install`, set `SYFT_CHECK_FOR_APP_UPDATE=false` in your job to avoid the request.

### Disconnected builds
`enrich: none` is the disconnected-build setting: the orb passes `--enrich none` to Syft, which also overrides an `enrich` list in a config file or `.syft.yaml`. Per-ecosystem network settings in a config file (for example `javascript.search-remote-licenses: true` or `java.use-network: true`) still take precedence over `--enrich`, so leave them unset. For a build with no egress at all, also:

- provide `syft` in the executor image and use the `syft/generate_sbom` command in your own job instead of `syft/install` or the `syft/sbom` job;
- scan local sources only (`dir:`, `file:`, `docker-archive:`, `oci-archive:`, `oci-dir:`, or an image already in the local daemon via `docker:`);
- set `SYFT_GOLANG_USE_PACKAGES_LIB=false` if the executor has a Go toolchain.
