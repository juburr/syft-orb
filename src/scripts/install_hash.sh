#!/bin/bash

# Convenience script, not used by directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh. Prints one table entry per architecture, keyed
# as "<version>_linux_<arch>".

set -e
set +o history

ARCHES="amd64 arm64"

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v:a: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        a) ARCHES=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0 [-a \"amd64 arm64\"]"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT
cd "${WORKDIR}"

# The release's checksums.txt lists the SHA-256 of every release asset. Use it to
# confirm each download is the published artifact before hashing the binary inside.
# If cosign is installed, also verify that checksums.txt was signed by syft's
# release workflow (signatures are published for 1.0.0 and later).
RELEASE_URL="https://github.com/anchore/syft/releases/download/v${VERSION}"
wget -q "${RELEASE_URL}/syft_${VERSION}_checksums.txt" -O checksums.txt
if ! command -v cosign > /dev/null 2>&1; then
  echo "NOTE: cosign not found; skipping signature verification of checksums.txt" >&2
elif ! wget -q "${RELEASE_URL}/syft_${VERSION}_checksums.txt.sig" -O checksums.txt.sig \
  || ! wget -q "${RELEASE_URL}/syft_${VERSION}_checksums.txt.pem" -O checksums.txt.pem; then
  echo "NOTE: syft ${VERSION} publishes no checksums.txt signature; relying on TLS only" >&2
else
  cosign verify-blob checksums.txt \
    --signature checksums.txt.sig \
    --certificate checksums.txt.pem \
    --certificate-identity-regexp '^https://github\.com/anchore/syft/\.github/workflows/.+' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com > /dev/null 2>&1 \
    || { echo "ERROR: cosign could not verify syft_${VERSION}_checksums.txt" >&2; exit 1; }
fi

# Download each architecture and get the SHA-512 checksum of the syft binary
# inside. Suppress output for readability; this is a dev script, so simply
# re-enable output if you need to debug anything.
for ARCH in ${ARCHES}; do
  ASSET="syft_${VERSION}_linux_${ARCH}.tar.gz"
  if ! grep -q " ${ASSET}\$" checksums.txt; then
    echo "WARN: ${ASSET} is not part of this release; skipping" >&2
    continue
  fi
  wget -q "${RELEASE_URL}/${ASSET}" -O "${ASSET}"
  grep " ${ASSET}\$" checksums.txt | sha256sum -c --quiet - >&2
  tar xzf "${ASSET}" syft
  CHECKSUM=$(sha512sum syft | awk '{ print $1 }')
  echo "[\"${VERSION}_linux_${ARCH}\"]=\"${CHECKSUM}\""
  rm -f syft "${ASSET}"
done
