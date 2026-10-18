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

# Generate SHA-512 checksums (linux amd64 + arm64) for a new syft version
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - Reusable CircleCI commands
  - `install.yml` - Installs syft binary with caching and checksum verification
  - `generate_sbom.yml` - Generates SBOM from various sources
  - `log_sbom.yml` - Displays SBOM contents in build logs
- `jobs/generate_sbom.yml` - `generate_sbom` job (same name as the command it runs) combining optional workspace attach (`attach_workspace_at`) + install + generate (SPDX and CycloneDX) + optional logging + persist
- `scripts/` - Shell implementations called by commands
- `examples/example.yml` - Usage documentation

### Key Implementation Details

**`scripts/install.sh`**: Installs the linux amd64 or arm64 syft build (from `uname -m`) from GitHub releases with SHA-512 checksum verification. It follows the layout every juburr orb's install.sh shares: a tool definition (asset names, URLs, archive member, version command), a shared install logic block that must stay identical across the orbs, and a checksum table keyed `"<version>/<arch>"`. Three verification modes: `false`, `known_versions`, `strict` (default, fails before downloading an unlisted version). `tests/install_test.sh` is the install contract test shared by the orbs; `src/scripts/install_hash.sh -v <version>` prints new table entries after checking the release's signed checksums (needs cosign).

**`scripts/generate_sbom.sh`**: Core SBOM generation logic with:
- Smart basename extraction for auto-generated filenames
- Wildcard expansion for package file paths
- RPM extraction via `rpm2archive | tar` (supports 4GB+ files)
- DEB extraction via `dpkg-deb`
- Automatic tool installation if missing (rpm, dpkg)
- Extraction scratch files from `mktemp`, removed by the script's single EXIT trap whether the scan passes or fails

**`scripts/log_sbom.sh`**: Logs every SBOM in `sbom_dir`, or the space-separated files/globs in `sbom_file`. In both modes a file is JSON when its name ends in `.json` (there is no format parameter); JSON is pretty-printed with jq and cut off after 100 lines.

### CI Pipeline (`.circleci/`)

- `config.yml` - Main pipeline: lint, pack, review, shellcheck, and the `tests/` scripts
- `test-deploy.yml` - Comprehensive test suite with:
  - Command tests (7 scenarios)
  - RPM package tests (builds test packages for RHEL 7/8/9/10)
  - DEB package tests (builds test packages for Ubuntu focal/jammy/noble)
  - Full job integration tests

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as in `VALUE=$(printf '%s' "${PARAM_VALUE}" | circleci env subst)`. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail`. No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset (`CIRCLE_*`, `TMPDIR`, optional env vars). `PARAM_*` values the command YAML always sets are read directly, so CI steps that run a script directly must set every one of them. Under `-e`/`pipefail`, watch `grep -q` or `head` ending a pipeline early (SIGPIPE) and tools whose failure the old code ignored.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. `tests/generate_sbom_test.sh` runs generate_sbom.sh on its empty-array paths.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${NAME_LIB}"`, `"${NAME_SCRIPT}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh` to lint shell scripts
- Run `bash tests/env_subst_test.sh` to check how scripts call `circleci env subst`
- Run `bash tests/shell_conventions_test.sh` to check the shell conventions
- Run `circleci orb validate` to validate the orb structure
