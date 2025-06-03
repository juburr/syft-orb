<div align="center">
  <img align="center" width="250" src="assets/logos/syft-orb-256px.png?v=2" alt="Syft Orb">
  <h1>CircleCI Syft Orb</h1>
  <i>A CircleCI orb for streamlining Syft integration and SBOM generation.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/syft-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/syft-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/syft-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/syft-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/syft-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This unofficial Syft orb facilitates the installation and execution of Syft within CircleCI pipelines, primarily for generating Software Bill of Materials (SBOMs) for container images and RPM packages. Contributions are welcome.

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

## Container Image SBOMs
Generate SBOMs for container images by invoking `syft` directly:

```yaml
 - syft/generate_sbom:
     source: ghcr.io/myorganization/customapp:1.0.0
     output_file: sboms/customapp.spdx.json
     output_format: spdx-json
     scope: squashed
```

## RPM SBOMs
For RPM packages, this orb enhances scanning by unpacking the RPM contents using `rpm2cpio` and `cpio`. This approach produces more comprehensive results by scanning individual files rather than treating the RPM as a single unit, often revealing dependencies and vulnerabilities that would otherwise remain undetected.

```yaml
 - syft/generate_sbom:
     source: ./workspace/rpmbuild/RPMS/x86_64/customapp*.el9.x86_64.rpm
     output_file: sboms/customapp-rpm-el9.spdx.json
     output_format: spdx-json
```
