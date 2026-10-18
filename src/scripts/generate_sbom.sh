#!/bin/bash

set -euo pipefail

# Ensure CircleCI environment variables can be passed in as orb parameters.
# Values are passed via stdin: values like "-file" would otherwise be parsed as CLI flags.
BASE_PATH=$(printf '%s' "${PARAM_BASE_PATH}" | circleci env subst)
ENRICH=$(printf '%s' "${PARAM_ENRICH}" | circleci env subst)
SOURCE=$(printf '%s' "${PARAM_SOURCE}" | circleci env subst)
OUTPUT_DIR=$(printf '%s' "${PARAM_OUTPUT_DIR}" | circleci env subst)
OUTPUT_FORMATS=$(printf '%s' "${PARAM_OUTPUT_FORMATS}" | circleci env subst)
SCOPE=$(printf '%s' "${PARAM_SCOPE}" | circleci env subst)
CONFIG=$(printf '%s' "${PARAM_CONFIG}" | circleci env subst)
EXCLUDE=$(printf '%s' "${PARAM_EXCLUDE}" | circleci env subst)
SELECT_CATALOGERS=$(printf '%s' "${PARAM_SELECT_CATALOGERS}" | circleci env subst)

# Print command parameters for debugging purposes.
echo "Running Syft scanner to generate an SBOM with parameters:"
echo "  BASE_PATH: ${BASE_PATH}"
echo "  ENRICH: ${ENRICH}"
echo "  SOURCE: ${SOURCE}"
echo "  OS_USER: $(whoami 2> /dev/null || true)"
echo "  OS_USER_GROUPS: $(id -Gn 2> /dev/null || true)"
echo "  OUTPUT_DIR: ${OUTPUT_DIR}"
echo "  OUTPUT_FORMATS: ${OUTPUT_FORMATS}"
echo "  SCOPE: ${SCOPE}"
echo "  CONFIG: ${CONFIG}"
echo "  EXCLUDE: ${EXCLUDE}"
echo "  SELECT_CATALOGERS: ${SELECT_CATALOGERS}"
echo ""

# Ensure Syft exists
if ! command -v syft >/dev/null 2>&1; then
  echo "ERROR: syft not found in PATH; please run the syft/install command first" >&2
  exit 1
fi

# Helper functions
runpkg() {
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then sudo "$@"; else "$@"; fi
}

# Scratch files for RPM and DEB extraction. They are removed on exit, whether
# the scan passes or fails. Removal is best effort, so it can't change the
# script's exit status.
TMP_SCAN_DIR=""
TMP_ARCHIVE=""
cleanup() {
  if [[ -n "${TMP_ARCHIVE}" ]]; then
    rm -f -- "${TMP_ARCHIVE}" || true
  fi
  if [[ -n "${TMP_SCAN_DIR}" ]]; then
    rm -rf -- "${TMP_SCAN_DIR}" || true
  fi
}
trap cleanup EXIT

# Split a comma- or newline-separated list of glob patterns into EXCLUDE_PATTERNS.
# Commas inside {...} are kept, so doublestar alternations such as
# "**/{target,dist}/**" stay intact. Entries are trimmed; empty entries are dropped.
# Arguments: $1 = pattern list
EXCLUDE_PATTERNS=()
parse_exclude_patterns() {
  local input="$1" current="" char depth=0 i
  for (( i = 0; i <= ${#input}; i++ )); do
    char="${input:i:1}"
    if [[ "${char}" == "{" ]]; then
      depth=$((depth + 1))
    elif [[ "${char}" == "}" && ${depth} -gt 0 ]]; then
      depth=$((depth - 1))
    fi
    if [[ ${i} -eq ${#input} || "${char}" == $'\n' || ( "${char}" == "," && ${depth} -eq 0 ) ]]; then
      current="${current#"${current%%[![:space:]]*}"}"
      current="${current%"${current##*[![:space:]]}"}"
      if [[ -n "${current}" ]]; then
        EXCLUDE_PATTERNS+=("${current}")
      fi
      current=""
    else
      current+="${char}"
    fi
  done
}

if [[ -n "${EXCLUDE}" ]]; then
  parse_exclude_patterns "${EXCLUDE}"
  echo "Exclude patterns:"
  printf '  - %s\n' "${EXCLUDE_PATTERNS[@]}"
  echo ""
fi

# Resolve the config file up front: RPM/DEB sources are scanned from a temporary
# directory, which would otherwise break a relative path.
if [[ -n "${CONFIG}" ]]; then
  if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: syft config file not found: ${CONFIG}" >&2
    exit 1
  fi
  CONFIG=$(realpath "${CONFIG}")
  echo "Using syft config file: ${CONFIG}"
  echo ""
fi

# Format suffix mapping for auto-generated output filenames.
# Directory logging in log_sbom.sh follows these suffixes. template uses a
# generic .txt suffix, so log_sbom only prints template output via sbom_file.
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
    basename=$(basename -- "${source}")
    basename="${basename%.rpm}"
    basename="${basename%.RPM}"
    echo "${basename}"
    return
  fi

  # DEB file: strip .deb extension
  if [[ "${source}" == *.deb ]] || [[ "${source}" == *.DEB ]]; then
    basename=$(basename -- "${source}")
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

  # Directory or file: strip the dir:/file: scheme, if any, then use the
  # basename ("." , ".." and "/" resolve to the directory's own name, or "project")
  local path="${source}"
  case "${source}" in
    dir:*) path="${source#dir:}" ;;
    file:*) path="${source#file:}" ;;
  esac
  basename=$(basename -- "${path}")
  if [[ "${basename}" == "." || "${basename}" == ".." || "${basename}" == "/" ]]; then
    # Use the directory's own name or "project" as fallback. cd's output is
    # discarded because it prints the resolved path when CDPATH applies.
    local parent_dir
    parent_dir=$(cd -- "${path}" >/dev/null 2>&1 && basename -- "$(pwd)")
    if [[ -n "${parent_dir}" && "${parent_dir}" != "/" ]]; then
      basename="${parent_dir}"
    else
      basename="project"
    fi
  fi

  echo "${basename}"
}

# Generate output path for a given format
# Arguments: $1 = output_dir value, $2 = source basename, $3 = output_format
# Output: prints the resolved output file path
generate_output_path() {
  local output_dir="$1"
  local source_basename="$2"
  local output_format="$3"

  # Get format suffix (default to .json if format not in map)
  local suffix="${FORMAT_SUFFIXES[${output_format}]:-.json}"

  # Extract the basename from source for auto-generated filenames
  local basename
  basename=$(extract_source_basename "${source_basename}")

  # Use specified directory or default to sboms/
  if [[ -z "${output_dir}" ]]; then
    echo "sboms/${basename}${suffix}"
  elif [[ "${output_dir}" == */ ]]; then
    echo "${output_dir}${basename}${suffix}"
  else
    echo "${output_dir}/${basename}${suffix}"
  fi
}

# A file: scheme on an RPM or DEB is redundant: drop it so the package is
# expanded, named and extracted like a plain path.
case "${SOURCE}" in
  file:*.rpm|file:*.RPM|file:*.deb|file:*.DEB) SOURCE="${SOURCE#file:}" ;;
esac
# A package path starting with "-" would be parsed as an option by dpkg-deb.
case "${SOURCE}" in
  -*.rpm|-*.RPM|-*.deb|-*.DEB) SOURCE="./${SOURCE}" ;;
esac

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
        echo "ERROR: No files matched pattern '$SOURCE'" >&2
        exit 1
        ;;
      1)
        SOURCE=${matched_files[0]}
        echo "  Expanded SOURCE: $SOURCE"
        ;;
      *)
        echo "ERROR: Multiple files matched pattern '$SOURCE'" >&2
        printf '  - %s\n' "${matched_files[@]}" >&2
        exit 1
        ;;
    esac
  fi
  SOURCE_BASENAME_FOR_OUTPUT="${SOURCE}"
fi

# Parse OUTPUT_FORMATS into an array (comma-separated)
# This must happen after wildcard expansion so we have the resolved source name
echo "Parsing output formats..."
IFS=',' read -ra FORMAT_ARRAY <<< "${OUTPUT_FORMATS}"

# Validate that we have at least one format
if [[ ${#FORMAT_ARRAY[@]} -eq 0 ]]; then
  echo "ERROR: No output formats specified. Please provide at least one format." >&2
  echo "  Supported formats: ${!FORMAT_SUFFIXES[*]}" >&2
  exit 1
fi

# Validate each format is supported
INVALID_FORMATS=()
VALID_FORMATS=()
for format in "${FORMAT_ARRAY[@]}"; do
  # Trim whitespace from format
  format=$(echo "${format}" | xargs)

  # Skip empty strings (e.g., from trailing commas)
  if [[ -z "${format}" ]]; then
    continue
  fi

  # Check if format is in the supported list
  if [[ -v FORMAT_SUFFIXES["${format}"] ]]; then
    VALID_FORMATS+=("${format}")
  else
    INVALID_FORMATS+=("${format}")
  fi
done

# Report any invalid formats
if [[ ${#INVALID_FORMATS[@]} -gt 0 ]]; then
  echo "ERROR: Unsupported output format(s) specified:" >&2
  for fmt in "${INVALID_FORMATS[@]}"; do
    echo "  - '${fmt}'" >&2
  done
  echo "" >&2
  echo "Supported formats:" >&2
  for fmt in "${!FORMAT_SUFFIXES[@]}"; do
    echo "  - ${fmt}" >&2
  done
  exit 1
fi

# Check we still have valid formats after filtering
if [[ ${#VALID_FORMATS[@]} -eq 0 ]]; then
  echo "ERROR: No valid output formats specified after parsing." >&2
  echo "  Supported formats: ${!FORMAT_SUFFIXES[*]}" >&2
  exit 1
fi

# Replace FORMAT_ARRAY with validated formats
FORMAT_ARRAY=("${VALID_FORMATS[@]}")
echo "  Formats to generate: ${FORMAT_ARRAY[*]}"
echo ""

# Generate output paths for each format and ensure directories exist
declare -a OUTPUT_PATHS=()
echo "Determining output file paths..."
for format in "${FORMAT_ARRAY[@]}"; do
  output_path=$(generate_output_path "${OUTPUT_DIR}" "${SOURCE_BASENAME_FOR_OUTPUT}" "${format}")

  # Ensure the output directory exists
  dir_path=$(dirname "${output_path}")
  if [[ ! -d "${dir_path}" ]]; then
    echo "  Creating output directory: ${dir_path}"
    mkdir -p "${dir_path}"
  fi

  # Expand to absolute path
  output_path=$(realpath --no-symlinks "${output_path}")
  OUTPUT_PATHS+=("${format}=${output_path}")
  echo "  ${format}: ${output_path}"
done
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
      echo "ERROR: Unable to install rpm2archive automatically. Please install 'rpm'." >&2
      exit 1
    fi
    command -v rpm2archive >/dev/null 2>&1 || {
      echo "ERROR: rpm installed but rpm2archive still missing (older distro?)." >&2; exit 1;
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
      echo "ERROR: Unable to install tar. Please install it manually." >&2
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
  # grep reads all of the help text: with -q it could exit before tar finished
  # writing, and pipefail would then report tar's SIGPIPE as a failed match.
  if tar --help 2>&1 | grep -- 'delay-directory-restore' > /dev/null; then
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
      echo "ERROR: Unable to install dpkg-deb automatically. Please install 'dpkg'." >&2
      exit 1
    fi
    command -v dpkg-deb >/dev/null 2>&1 || {
      echo "ERROR: dpkg installed but dpkg-deb still missing." >&2; exit 1;
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
syft_args=(scan -vv --scope "${SCOPE}" --base-path "${BASE_PATH}")

# Add output flags for each format
for output_spec in "${OUTPUT_PATHS[@]}"; do
  syft_args+=(-o "${output_spec}")
done

# Always pass --enrich, including "none", so the orb's setting overrides an
# enrich list from a syft config file (e.g. an implicitly loaded .syft.yaml).
if [[ -n "${ENRICH}" ]]; then
  syft_args+=(--enrich "${ENRICH}")
fi

# Scope control: config file, exclusions, and cataloger selection. Flags given
# here take precedence over the same settings in the config file.
if [[ -n "${CONFIG}" ]]; then
  syft_args+=(--config "${CONFIG}")
fi
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
  syft_args+=(--exclude "${pattern}")
done
if [[ -n "${SELECT_CATALOGERS}" ]]; then
  syft_args+=(--select-catalogers "${SELECT_CATALOGERS}")
fi

# The source is added last and can be a container image or filesystem path.
syft_args+=("${SOURCE}")

# This orb pins the syft version, so syft's start-up update check only adds a request
# to toolbox-data.anchore.io. That request has no timeout and can stall builds whose
# egress is blocked, so it is disabled unless the caller explicitly sets the variable.
export SYFT_CHECK_FOR_APP_UPDATE="${SYFT_CHECK_FOR_APP_UPDATE:-false}"

# Generate the SBOM(s)
echo "Scanning with syft..."
echo "  Command: syft ${syft_args[*]}"
syft "${syft_args[@]}"

# If the source was an RPM or DEB file, remove the temporary directory
if [[ -n "${TMP_SCAN_DIR}" ]]; then
  echo "Cleaning up temporary directory..."
  popd > /dev/null
  cleanup
fi

echo "Done."
echo "Syft scan completed successfully. Generated SBOMs:"
for output_spec in "${OUTPUT_PATHS[@]}"; do
  echo "  - ${output_spec#*=}"
done
