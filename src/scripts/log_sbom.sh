#!/bin/bash
#
# log_sbom.sh - Print SBOM contents to the step log for logging/debugging
#
# Supports two modes:
# 1. Directory mode (sbom_dir): Logs all SBOM files in a directory
# 2. File mode (sbom_file): Logs specific file(s), space-separated (supports wildcards)
#
# In both modes, a file is treated as JSON when its name ends in .json.
#

set -euo pipefail

# Expands environment variables in a parameter value with the CircleCI CLI,
# reading it on stdin. Without the CLI (GitHub Actions, local runs), the value
# is used as is.
subst() {
  if command -v circleci >/dev/null 2>&1; then
    printf '%s' "$1" | circleci env subst
  else
    printf '%s' "$1"
  fi
}

SBOM_DIR=$(subst "${PARAM_SBOM_DIR}")
SBOM_FILE=$(subst "${PARAM_SBOM_FILE}")

# CircleCI passes a boolean parameter as 1 or 0, and a GitHub Action input as
# true or false.
case "${PARAM_PRETTY}" in
  1 | true) PRETTY=1 ;;
  0 | false) PRETTY=0 ;;
  *)
    echo "ERROR: pretty must be true or false, not '${PARAM_PRETTY}'." >&2
    exit 1
    ;;
esac

# Print command parameters for debugging purposes.
echo "Running SBOM logger with the following parameters:"
echo "  PRETTY: ${PRETTY}"
echo "  SBOM_DIR: ${SBOM_DIR}"
echo "  SBOM_FILE: ${SBOM_FILE}"
echo ""

# Helper function to determine if a file is JSON-based from its extension
is_json_file() {
  local file="$1"
  case "${file}" in
    *.json) return 0 ;;
    *) return 1 ;;
  esac
}

# Helper function to log a single SBOM file, detecting JSON from its extension
log_sbom_file() {
  local file="$1"
  local is_json="false"
  if is_json_file "${file}"; then
    is_json="true"
  fi

  echo "=== $(basename "$file") ==="

  if [[ "${is_json}" == "true" && "${PRETTY}" == "1" ]]; then
    if command -v jq &> /dev/null; then
      # head stops reading after 100 lines, which kills jq with SIGPIPE, and jq
      # fails on a file that isn't valid JSON. Neither stops the log.
      { jq '.' "$file" || true; } | head -100
    else
      head -100 "$file"
    fi
  elif [[ "${is_json}" == "true" ]]; then
    head -100 "$file"
  else
    cat "$file"
  fi

  echo ""
}

# Directory mode: log all SBOM files in the directory
if [[ -n "${SBOM_DIR}" ]]; then
  if [[ ! -d "${SBOM_DIR}" ]]; then
    echo "ERROR: Directory '${SBOM_DIR}' does not exist" >&2
    exit 1
  fi

  echo "Logging SBOMs from directory: ${SBOM_DIR}"
  echo ""

  # List directory contents
  echo "Directory contents:"
  ls -la "${SBOM_DIR}/"
  echo ""

  # Suffixes match generate_sbom.sh. template writes a generic .txt file, so it is
  # only logged when the caller passes sbom_file.
  sbom_suffixes=(
    ".spdx.json"
    ".cdx.json"
    ".syft.json"
    ".github.json"
    ".cdx.xml"
    ".spdx"
    ".syft.txt"
    ".purls.txt"
  )
  found_files=0
  # Include hidden files, e.g. the SBOM generated for a dir:.venv source.
  shopt -s dotglob
  for suffix in "${sbom_suffixes[@]}"; do
    for sbom in "${SBOM_DIR}"/*"${suffix}"; do
      if [[ -f "$sbom" ]]; then
        found_files=$((found_files + 1))
        log_sbom_file "$sbom"
      fi
    done
  done

  if [[ $found_files -eq 0 ]]; then
    echo "No SBOM files found in ${SBOM_DIR}"
  else
    echo "Logged ${found_files} SBOM file(s)"
  fi

  exit 0
fi

# File mode: log specific file(s)
if [[ -z "${SBOM_FILE}" ]]; then
  echo "ERROR: Either sbom_dir or sbom_file must be provided" >&2
  exit 1
fi

# Split on spaces and expand wildcards, so several files or globs can be given
# shellcheck disable=SC2086
for file in ${SBOM_FILE}; do
  if [[ -f "$file" ]]; then
    log_sbom_file "$file"
  else
    echo "WARN: File not found: $file" >&2
  fi
done
