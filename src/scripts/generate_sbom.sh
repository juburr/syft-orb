#!/bin/bash

set -e
set +o history
set -o pipefail

# Ensure CircleCI environment variables can be passed in as orb parameters
BASE_PATH=$(circleci env subst "${PARAM_BASE_PATH}")
ENRICH=$(circleci env subst "${PARAM_ENRICH}")
SOURCE=$(circleci env subst "${PARAM_SOURCE}")
OUTPUT_FILE=$(circleci env subst "${PARAM_OUTPUT_FILE}")
OUTPUT_FORMAT=$(circleci env subst "${PARAM_OUTPUT_FORMAT}")
SCOPE=$(circleci env subst "${PARAM_SCOPE}")

# Print command parameters for debugging purposes.
echo "Running Syft scanner to generate an SBOM with parameters:"
echo "  BASE_PATH: ${BASE_PATH}"
echo "  ENRICH: ${ENRICH}"
echo "  SOURCE: ${SOURCE}"
echo "  OS_USER: $(whoami 2> /dev/null || true)"
echo "  OS_USER_GROUPS: $(id -Gn 2> /dev/null || true)"
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"
echo "  OUTPUT_FORMAT: ${OUTPUT_FORMAT}"
echo "  SCOPE: ${SCOPE}"
echo ""

# Ensure Syft exists
if ! command -v syft >/dev/null 2>&1; then
  echo "ERROR: syft not found in PATH; please run the syft/install command first"
  exit 1
fi

# Helper functions
runpkg() {
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then sudo "$@"; else "$@"; fi
}

# Format suffix mapping for auto-generated output filenames
declare -A FORMAT_SUFFIXES=(
  ["spdx-json"]=".spdx.json"
  ["cyclonedx-json"]=".cdx.json"
  ["cyclonedx-xml"]=".cdx.xml"
  ["spdx-tag-value"]=".spdx"
  ["syft-json"]=".syft.json"
  ["syft-table"]=".syft.txt"
  ["syft-text"]=".syft.txt"
  ["github-json"]=".github.json"
  ["purls"]=".purls.txt"
  ["template"]=".txt"
)

# Extract base name from source for auto-generated output filenames
# Arguments: $1 = source path/URI
# Output: prints the extracted base name
extract_source_basename() {
  local source="$1"
  local basename

  # RPM file: strip .rpm extension
  if [[ "${source}" == *.rpm ]] || [[ "${source}" == *.RPM ]]; then
    basename=$(basename "${source}")
    basename="${basename%.rpm}"
    basename="${basename%.RPM}"
    echo "${basename}"
    return
  fi

  # DEB file: strip .deb extension
  if [[ "${source}" == *.deb ]] || [[ "${source}" == *.DEB ]]; then
    basename=$(basename "${source}")
    basename="${basename%.deb}"
    basename="${basename%.DEB}"
    echo "${basename}"
    return
  fi

  # Container image: extract image name and tag
  # Patterns: ghcr.io/org/app:1.0.0, docker.io/library/nginx:latest, app:tag
  if [[ "${source}" == *":"* ]] && [[ "${source}" != "dir:"* ]] && [[ "${source}" != "file:"* ]]; then
    # Remove registry prefix (everything up to last /)
    local image_with_tag="${source##*/}"
    # Split on : to get image name and tag
    local image_name="${image_with_tag%%:*}"
    local tag="${image_with_tag#*:}"
    # Handle case where tag contains @ (digest)
    tag="${tag%%@*}"
    # Combine image name and tag with hyphen
    if [[ -n "${tag}" && "${tag}" != "${image_name}" ]]; then
      echo "${image_name}-${tag}"
    else
      echo "${image_name}"
    fi
    return
  fi

  # Directory: use basename (handle "." specially)
  basename=$(basename "${source}")
  if [[ "${basename}" == "." ]]; then
    # Use parent directory name or "project" as fallback
    local parent_dir
    parent_dir=$(cd "${source}" 2>/dev/null && basename "$(pwd)")
    if [[ -n "${parent_dir}" && "${parent_dir}" != "/" ]]; then
      echo "${parent_dir}"
    else
      echo "project"
    fi
    return
  fi

  echo "${basename}"
}

# Generate output path based on output_file parameter mode
# Arguments: $1 = output_file value, $2 = source, $3 = output_format
# Output: prints the resolved output file path
generate_output_path() {
  local output_file="$1"
  local source="$2"
  local output_format="$3"

  # Get format suffix (default to .json if format not in map)
  local suffix="${FORMAT_SUFFIXES[${output_format}]:-.json}"

  # Mode 1: Empty string - auto-generate in sboms/ directory
  if [[ -z "${output_file}" ]]; then
    local basename
    basename=$(extract_source_basename "${source}")
    echo "sboms/${basename}${suffix}"
    return
  fi

  # Mode 2: Trailing slash - auto-generate in specified directory
  if [[ "${output_file}" == */ ]]; then
    local basename
    basename=$(extract_source_basename "${source}")
    echo "${output_file}${basename}${suffix}"
    return
  fi

  # Mode 3: Explicit filename - use as-is
  echo "${output_file}"
}

# Wildcard Expansion for Package Files
#
# Expand wildcards in the SOURCE path for RPM and DEB files, allowing callers
# to wildcard the version number within the filename. This script generates
# an SBOM for a single package file, so we expect the SOURCE to match exactly
# one file. If multiple files match, we will error out and require the caller
# to specify a more specific SOURCE.
#
# This must happen BEFORE output path generation so the basename can be extracted
# from the resolved filename.
SOURCE_BASENAME_FOR_OUTPUT="${SOURCE}"
if [[ "${SOURCE}" == *.rpm ]] || [[ "${SOURCE}" == *.RPM ]] || \
   [[ "${SOURCE}" == *.deb ]] || [[ "${SOURCE}" == *.DEB ]]; then
  if [[ $SOURCE = *[\*\?\[]* ]]; then
    echo "Detected wildcard in SOURCE. Expanding..."

    # One match per line; tolerate zero matches without aborting set -e
    mapfile -t matched_files < <(compgen -G "$SOURCE" || true)

    case ${#matched_files[@]} in
      0)
        echo "ERROR: No files matched pattern '$SOURCE'"
        exit 1
        ;;
      1)
        SOURCE=${matched_files[0]}
        echo "  Expanded SOURCE: $SOURCE"
        ;;
      *)
        echo "ERROR: Multiple files matched pattern '$SOURCE'"
        printf '  - %s\n' "${matched_files[@]}"
        exit 1
        ;;
    esac
  fi
  SOURCE_BASENAME_FOR_OUTPUT="${SOURCE}"
fi

# Generate output path based on OUTPUT_FILE parameter mode
# This must happen after wildcard expansion so we have the resolved source name
echo "Determining output file path..."
OUTPUT_FILE=$(generate_output_path "${OUTPUT_FILE}" "${SOURCE_BASENAME_FOR_OUTPUT}" "${OUTPUT_FORMAT}")
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"

# Ensure the output directory exists
# Automatically create it as a convenience for the caller.
# This must be done before computing the absolute path with 'realpath'.
OUTPUT_DIR=$(dirname "${OUTPUT_FILE}")
if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "  Creating output directory: ${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}"
else
  echo "  Output directory already exists: ${OUTPUT_DIR}"
fi

# Expand SBOM filename to absolute path
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
if [[ "${SOURCE}" == *.rpm ]] || [[ "${SOURCE}" == *.RPM ]]; then
  echo "Detected RPM file. Extracting contents to temporary directory..."

  # If rpm2archive is not installed, make a best effort to install it.
  if ! command -v rpm2archive >/dev/null 2>&1; then
    echo "rpm2archive not found. Attempting to install..."
    if command -v dnf >/dev/null 2>&1; then
      echo "Installing via dnf (package: rpm)..."
      runpkg dnf install -y rpm
    elif command -v yum >/dev/null 2>&1; then
      echo "Installing via yum (package: rpm)..."
      runpkg yum install -y rpm
    elif command -v apt-get >/dev/null 2>&1; then
      echo "Installing via apt (package: rpm)..."
      runpkg apt-get update
      runpkg apt-get install -y rpm
    else
      echo "Unable to install rpm2archive automatically. Please install 'rpm'."
      exit 1
    fi
    command -v rpm2archive >/dev/null 2>&1 || {
      echo "rpm installed but rpm2archive still missing (older distro?)."; exit 1;
    }
  fi

  # If tar is not installed, make a best effort to install it.
  if ! command -v tar &> /dev/null; then
    echo "tar not found. Attempting to install..."
    if command -v dnf &> /dev/null; then
      echo "Installing tar using dnf..."
      runpkg dnf install -y tar
    elif command -v yum &> /dev/null; then
      echo "Installing tar using yum..."
      runpkg yum install -y tar
    elif command -v apt-get &> /dev/null; then
      echo "Installing tar using apt-get..."
      runpkg apt-get update
      runpkg apt-get install -y tar
    else
      echo "Unable to install tar. Please install it manually."
      exit 1
    fi
    echo "tar installed successfully."
  fi

  # Extract the contents of the RPM to a temporary directory
  # Syft doesn't capture filesystem permissions in the SBOM, so ignore them to
  # prevent permission errors.
  echo "Extracting RPM contents to a temporary directory..."
  TMP_SCAN_DIR=$(mktemp -d)
  echo "  TMP_SCAN_DIR: ${TMP_SCAN_DIR}"
  TMP_ARCHIVE="$(mktemp)"
  echo "  TMP_ARCHIVE: ${TMP_ARCHIVE}"
  trap 'rm -f "$TMP_ARCHIVE"' EXIT

  # Extract the RPM to a TAR archive first
  # The "rpm2archive | tar" strategy is a workaround for allow compatibility with
  # RPMS greater than 4 GB, as "rpm2cpio | cpio" fails with the error messages:
  #   "files over 4GB not supported by cpio, use rpm2archive instead"
  #   "cpio: premature end of archive"
  rpm2archive - < "${SOURCE}" > "${TMP_ARCHIVE}"

  # Build the tar command arguments
  # Depending on the distribution in use, rpm2archive may or may not output the TAR file using gzip
  tar_args=(-x) # Extract
  if gzip -t "${TMP_ARCHIVE}" >/dev/null 2>&1; then
    tar_args+=(-z)
  fi
  tar_args+=(-f "$TMP_ARCHIVE")
  tar_args+=(-C "$TMP_SCAN_DIR")
  tar_args+=(--no-same-owner --no-same-permissions)
  if tar --help 2>&1 | grep -q -- 'delay-directory-restore'; then
    # May not be supported on some distros such as BusyBox
    tar_args+=(--delay-directory-restore)
  fi

  # Extract the TAR archive to the temporary scan directory
  tar "${tar_args[@]}"

  # Remove the temporary archive
  rm -f "${TMP_ARCHIVE}"

  # Change directories before running filesystem-based scans to prevent the
  # temporary directory paths from showing up in the SBOM, as it does not
  # represent the actual filesystem structure after the RPM is installed.
  # Before: "spdxElementId": "SPDXRef-DocumentRoot-Directory--tmp-tmp.VU9UMSOAIP"
  # After: "spdxElementId": "SPDXRef-DocumentRoot-Directory-."
  SOURCE="dir:."
  pushd . > /dev/null
  cd "${TMP_SCAN_DIR}"
  echo "  SOURCE: ${SOURCE}"

  # If the user provided their own base path, use it. Otherwise it's desirable to set the
  # base path to the root directory where the RPM files are extracted.
  if [[ -z "${BASE_PATH}" ]]; then
    BASE_PATH="${TMP_SCAN_DIR}"
  fi
fi

# DEB Handling
#
# If the source is a .deb file, scanning it with syft will return
# a single result, treating the deb as a single combined unit. For
# best results, extract the contents of the deb to a temporary
# directory and scan that instead. This will allow syft to identify
# the individual files inside the DEB and include them in the SBOM.
if [[ "${SOURCE}" == *.deb ]] || [[ "${SOURCE}" == *.DEB ]]; then
  echo "Detected DEB file. Extracting contents to temporary directory..."

  # If dpkg-deb is not installed, make a best effort to install it.
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found. Attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
      echo "Installing via apt (package: dpkg)..."
      runpkg apt-get update
      runpkg apt-get install -y dpkg
    elif command -v dnf >/dev/null 2>&1; then
      echo "Installing via dnf (package: dpkg)..."
      runpkg dnf install -y dpkg
    elif command -v yum >/dev/null 2>&1; then
      echo "Installing via yum (package: dpkg)..."
      runpkg yum install -y dpkg
    else
      echo "Unable to install dpkg-deb automatically. Please install 'dpkg'."
      exit 1
    fi
    command -v dpkg-deb >/dev/null 2>&1 || {
      echo "dpkg installed but dpkg-deb still missing."; exit 1;
    }
  fi

  # Extract the contents of the DEB to a temporary directory
  # Syft doesn't capture filesystem permissions in the SBOM, so we don't need
  # to preserve them during extraction.
  echo "Extracting DEB contents to a temporary directory..."
  TMP_SCAN_DIR=$(mktemp -d)
  echo "  TMP_SCAN_DIR: ${TMP_SCAN_DIR}"

  # Extract the DEB package contents
  dpkg-deb -x "${SOURCE}" "${TMP_SCAN_DIR}"

  # Change directories before running filesystem-based scans to prevent the
  # temporary directory paths from showing up in the SBOM, as it does not
  # represent the actual filesystem structure after the DEB is installed.
  # Before: "spdxElementId": "SPDXRef-DocumentRoot-Directory--tmp-tmp.VU9UMSOAIP"
  # After: "spdxElementId": "SPDXRef-DocumentRoot-Directory-."
  SOURCE="dir:."
  pushd . > /dev/null
  cd "${TMP_SCAN_DIR}"
  echo "  SOURCE: ${SOURCE}"

  # If the user provided their own base path, use it. Otherwise it's desirable to set the
  # base path to the root directory where the DEB files are extracted.
  if [[ -z "${BASE_PATH}" ]]; then
    BASE_PATH="${TMP_SCAN_DIR}"
  fi
fi

# If we don't have a base path yet, assume "/"
if [[ -z "${BASE_PATH}" ]]; then
  BASE_PATH="/"
fi

# Build the syft command arguments
syft_args=(scan -vv --scope "${SCOPE}" --output "${OUTPUT_FORMAT}" --base-path "${BASE_PATH}")

# Conditionally add the --enrich flag
if [[ -n "${ENRICH}" && "${ENRICH}" != "none" ]]; then
  syft_args+=(--enrich "${ENRICH}")
fi

# The source is added last and can be a container image or filesystem path.
syft_args+=("${SOURCE}")

# Generate the SBOM
echo "Scanning with syft..."
syft "${syft_args[@]}" > "${OUTPUT_FILE}"

# If the source was an RPM or DEB file, remove the temporary directory
if [[ -n "${TMP_SCAN_DIR}" ]]; then
  echo "Cleaning up temporary directory..."
  popd > /dev/null
  rm -rf "${TMP_SCAN_DIR}"
fi

echo "Done."
echo "Syft scan completed successfully. Wrote SBOM to: ${OUTPUT_FILE}"
