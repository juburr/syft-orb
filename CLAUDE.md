# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb that simplifies integration of Syft (SBOM generator) into CircleCI pipelines. The orb enables generating Software Bill of Materials for container images, RPM/DEB packages, and source directories.

## Development Commands

```bash
# Validate CircleCI configuration
circleci config validate

# Pack orb from source into single file
circleci orb pack src/ > orb.yml

# Lint packed orb
circleci orb lint orb.yml

# Publish development version (requires auth)
circleci orb publish orb.yml juburr/syft-orb@dev:latest

# Generate SHA-512 checksum for new syft version
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - Reusable CircleCI commands
  - `install.yml` - Installs syft binary with caching and checksum verification
  - `generate_sbom.yml` - Generates SBOM from various sources
  - `log_sbom.yml` - Displays SBOM contents in build logs
- `jobs/sbom.yml` - Complete job combining install + generate (SPDX and CycloneDX) + optional logging
- `scripts/` - Shell implementations called by commands
- `examples/example.yml` - Usage documentation

### Key Implementation Details

**`scripts/install.sh`**: Downloads syft from GitHub releases with SHA-512 checksum verification. Maintains a checksum lookup table for 200+ versions. Three verification modes: `false`, `known_versions`, `strict`.

**`scripts/generate_sbom.sh`**: Core SBOM generation logic with:
- Smart basename extraction for auto-generated filenames
- Wildcard expansion for package file paths
- RPM extraction via `rpm2archive | tar` (supports 4GB+ files)
- DEB extraction via `dpkg-deb`
- Automatic tool installation if missing (rpm, dpkg)

**`scripts/log_sbom.sh`**: Auto-detects format from file extensions, pretty-prints JSON with jq.

### CI Pipeline (`.circleci/`)

- `config.yml` - Main pipeline: lint, pack, review, shellcheck
- `test-deploy.yml` - Comprehensive test suite with:
  - Command tests (7 scenarios)
  - RPM package tests (builds test packages for RHEL 7/8/9/10)
  - DEB package tests (builds test packages for Ubuntu focal/jammy/noble)
  - Full job integration tests

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh` to lint shell scripts
- Run `circleci orb validate` to validate the orb structure
