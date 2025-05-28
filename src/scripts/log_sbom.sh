#!/bin/bash

set -e
set +o history

# Ensure CircleCI environment variables can be passed in as orb parameters
PRETTY="${PARAM_PRETTY}"
SBOM_FORMAT=$(circleci env subst "${PARAM_SBOM_FORMAT}")
SBOM_PATH=$(circleci env subst "${PARAM_SBOM_PATH}")

# Print command parameters for debugging purposes.
echo "Running SBOM logger with the following parameters:"
echo "  PRETTY: ${PRETTY}"
echo "  SBOM_FORMAT: ${SBOM_FORMAT}"
echo "  SBOM_PATH: ${SBOM_PATH}"
echo ""

# If the SBOM is in JSON format and the user wants it pretty printed, run JQ
# when logging it. Otherwise just dump out the file contents normally. The for
# loops below allow for SBOM_PATH to contain wildcards, allowing the caller to
# log multiple SBOM files at once. Only one iteration of the loop will run if
# SBOM_PATH does not contain wildcards.
if [[ "${SBOM_FORMAT}" == *"json"* && "${PRETTY:-0}" -eq 1 ]]; then
  for file in ${SBOM_PATH}; do
    jq . "$file"
  done
else
  for file in ${SBOM_PATH}; do
    cat "$file"
  done
fi
