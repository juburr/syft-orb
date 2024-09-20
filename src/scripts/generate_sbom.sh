#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
IMAGE_URI=$(circleci env subst "${PARAM_IMAGE_URI}")
OUTPUT_FILE=$(circleci env subst "${PARAM_OUTPUT_FILE}")
OUTPUT_FORMAT=$(circleci env subst "${PARAM_OUTPUT_FORMAT}")
SCOPE=$(circleci env subst "${PARAM_SCOPE}")

# Print command parameters for debugging purposes.
echo "Running Syft scanner to generate an SBOM with parameters:"
echo "  IMAGE_URI: ${IMAGE_URI}"
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"
echo "  OUTPUT_FORMAT: ${OUTPUT_FORMAT}"
echo "  SCOPE: ${SCOPE}"
echo ""

# Expand SBOM filename for debugging purposes
echo "Computing absolute path for the SBOM..."
OUTPUT_FILE=$(realpath --no-symlinks "${OUTPUT_FILE}")
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"
echo ""

# Generate the SBOM
echo "Scanning..."
syft scan -vv --scope "${SCOPE}" --output "${OUTPUT_FORMAT}" "${IMAGE_URI}" > "${OUTPUT_FILE}"
echo "Wrote SBOM to: ${OUTPUT_FILE}"
