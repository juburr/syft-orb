#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
SOURCE=$(circleci env subst "${PARAM_SOURCE}")
OUTPUT_FILE=$(circleci env subst "${PARAM_OUTPUT_FILE}")
OUTPUT_FORMAT=$(circleci env subst "${PARAM_OUTPUT_FORMAT}")
SCOPE=$(circleci env subst "${PARAM_SCOPE}")

# Print command parameters for debugging purposes.
echo "Running Syft scanner to generate an SBOM with parameters:"
echo "  SOURCE: ${SOURCE}"
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"
echo "  OUTPUT_FORMAT: ${OUTPUT_FORMAT}"
echo "  SCOPE: ${SCOPE}"
echo ""

# Expand SBOM filename for debugging purposes
echo "Computing absolute path for the SBOM..."
OUTPUT_FILE=$(realpath --no-symlinks "${OUTPUT_FILE}")
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"
echo ""

# RPM Handling
#
# If the source is an .rpm file, scanning it with syft will return
# a single result, treating the rpm as a single combined unit. For
# best results, extract the contents of the rpm to a temporary
# directory and scan that instead. This will allow syft to identify
# the individual files inside the RPM and include them in the SBOM.
BASE_PATH="/"
if [[ "${SOURCE}" == *.rpm ]] || [[ "${SOURCE}" == *.RPM ]]; then
  echo "Detected RPM file. Extracting contents to temporary directory..."

  # If rpm2cpio is not installed, make a best effort to install it.
  if ! command -v rpm2cpio &> /dev/null; then
    echo "rpm2cpio not found. Attempting to install..."
    if command -v dnf &> /dev/null; then
      sudo dnf install -y rpm2cpio
    elif command -v yum &> /dev/null; then
      sudo yum install -y rpm2cpio
    elif command -v apt-get &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y rpm2cpio
    else
      echo "Unable to install rpm2cpio. Please install it manually."
      exit 1
    fi
  fi

  # If cpio is not installed, make a best effort to install it.
  if ! command -v cpio &> /dev/null; then
    echo "cpio not found. Attempting to install..."
    if command -v dnf &> /dev/null; then
      sudo dnf install -y cpio
    elif command -v yum &> /dev/null; then
      sudo yum install -y cpio
    elif command -v apt-get &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y cpio
    else
      echo "Unable to install cpio. Please install it manually."
      exit 1
    fi
  fi

  # Extract the contents of the RPM to a temporary directory
  TMP_SCAN_DIR=$(mktemp -d)
  echo "  TMP_SCAN_DIR: ${TMP_SCAN_DIR}"
  rpm2cpio "${SOURCE}" | cpio -idmv --no-absolute-filenames --quiet --directory "${TMP_SCAN_DIR}"
  SOURCE="dir:${TMP_SCAN_DIR}"
  echo "  SOURCE: ${SOURCE}"
  BASE_PATH="${TMP_SCAN_DIR}"
fi

# Generate the SBOM
echo "Scanning with syft..."
syft scan -vv --scope "${SCOPE}" --output "${OUTPUT_FORMAT}" --base-path "${BASE_PATH}" "${SOURCE}" > "${OUTPUT_FILE}"

# If the source was an RPM file, remove the temporary directory
if [[ -n "${TMP_SCAN_DIR}" ]]; then
  echo "Cleaning up temporary directory..."
  rm -rf "${TMP_SCAN_DIR}"
fi

echo "Done."
echo "Syft scan completed successfully. Wrote SBOM to: ${OUTPUT_FILE}"
