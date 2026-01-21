#!/bin/bash
#
# log_sbom.sh - Print SBOM contents to CircleCI output for logging/debugging
#
# Supports two modes:
# 1. Directory mode (sbom_dir): Logs all SBOM files in a directory with auto-detected formats
# 2. Path mode (sbom_path): Logs specific file(s) with explicit format (supports wildcards)
#

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
PRETTY="${PARAM_PRETTY}"
SBOM_DIR=$(circleci env subst "${PARAM_SBOM_DIR}")
SBOM_FORMAT=$(circleci env subst "${PARAM_SBOM_FORMAT}")
SBOM_PATH=$(circleci env subst "${PARAM_SBOM_PATH}")

# Print command parameters for debugging purposes.
echo "Running SBOM logger with the following parameters:"
echo "  PRETTY: ${PRETTY}"
echo "  SBOM_DIR: ${SBOM_DIR}"
echo "  SBOM_FORMAT: ${SBOM_FORMAT}"
echo "  SBOM_PATH: ${SBOM_PATH}"
echo ""

# Helper function to determine if a file is JSON-based from its extension
is_json_file() {
  local file="$1"
  case "${file}" in
    *.json) return 0 ;;
    *) return 1 ;;
  esac
}

# Helper function to log a single SBOM file
log_sbom_file() {
  local file="$1"
  local is_json="$2"

  echo "=== $(basename "$file") ==="

  if [[ "${is_json}" == "true" && "${PRETTY:-0}" == "1" ]]; then
    if command -v jq &> /dev/null; then
      jq '.' "$file" | head -100
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
    echo "ERROR: Directory '${SBOM_DIR}' does not exist"
    exit 1
  fi

  echo "Logging SBOMs from directory: ${SBOM_DIR}"
  echo ""

  # List directory contents
  echo "Directory contents:"
  ls -la "${SBOM_DIR}/"
  echo ""

  # Find and log all SBOM files (JSON and XML)
  found_files=0
  for sbom in "${SBOM_DIR}"/*.spdx.json "${SBOM_DIR}"/*.cdx.json "${SBOM_DIR}"/*.syft.json "${SBOM_DIR}"/*.github.json "${SBOM_DIR}"/*.cdx.xml "${SBOM_DIR}"/*.spdx; do
    if [[ -f "$sbom" ]]; then
      found_files=$((found_files + 1))
      if is_json_file "$sbom"; then
        log_sbom_file "$sbom" "true"
      else
        log_sbom_file "$sbom" "false"
      fi
    fi
  done

  if [[ $found_files -eq 0 ]]; then
    echo "No SBOM files found in ${SBOM_DIR}"
  else
    echo "Logged ${found_files} SBOM file(s)"
  fi

  exit 0
fi

# Path mode: log specific file(s) with explicit format
if [[ -z "${SBOM_PATH}" ]]; then
  echo "ERROR: Either sbom_dir or sbom_path must be provided"
  exit 1
fi

# Determine if the format is JSON-based
is_json="false"
if [[ "${SBOM_FORMAT}" == *"json"* ]]; then
  is_json="true"
fi

# Log files matching the path pattern (supports wildcards)
# shellcheck disable=SC2086
for file in ${SBOM_PATH}; do
  if [[ -f "$file" ]]; then
    log_sbom_file "$file" "$is_json"
  else
    echo "WARNING: File not found: $file"
  fi
done
