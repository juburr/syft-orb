#!/bin/bash

set -e

# Ensure CircleCI environment variables can be passed in as orb parameters
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Check if the syft tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f syft.tar.gz ]]; then
    tar xvzf syft.tar.gz syft
fi

# If there was no cache hit, go ahead and re-download the binary.
# Tar it up to save on cache space used.
if [[ ! -f syft ]]; then
    wget "https://github.com/anchore/syft/releases/download/v${VERSION}/syft_${VERSION}_linux_amd64.tar.gz" -O syft.tar.gz
    tar xvzf syft.tar.gz syft
fi

# A syft binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. Move it to an appropriate bin directory and mark it
# as executable.
mv syft "${INSTALL_PATH}/syft"
chmod +x "${INSTALL_PATH}/syft"