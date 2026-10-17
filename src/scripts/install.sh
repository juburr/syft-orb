#!/bin/bash
#
# Installs Syft for the install command: the Linux amd64 or arm64 build that
# matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (Syft only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing Syft needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="syft-orb"
TOOL_NAME="Syft"
TOOL_BINARY="syft"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    printf 'syft_%s_linux_%s.tar.gz\n' "$1" "$2"
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf 'https://github.com/anchore/syft/releases/download/v%s/%s\n' "$1" "$3"
}

# tool_archive_member VERSION ARCH: the binary's path inside the asset. The
# checksum table holds the SHA-512 of that file.
tool_archive_member() {
    printf 'syft\n'
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    SYFT_CHECK_FOR_APP_UPDATE=false "$1" version
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            rm -f "${ORB_CACHE_FILE}"
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
#
# Linux arm64 builds were first published in Syft 0.28.0.
declare -A sha512sums=(
    ["1.52.0/amd64"]="ca3cb27a969cb35b8843f076cfef343594ba5dc1d498cf8262decbd734bdb7e229a4597bb41f14a9911fea9aace32600cda02bdc97c44582c29249575ecfbd35"
    ["1.52.0/arm64"]="c8bc6e313168bb6b97166c18dc92f721148cd38baf41f806dcd207174a0d390bc3fd576f7ea8a0c1d60ca29c180239b151714a9c17ffce3d642727f0a21b3195"
    ["1.51.1/amd64"]="fd5f37edbb0dc2aa72ff6787ff96d7b7f0b8ecf93b174cd1d207a2264ce8b846780680e58d79debf48086ae2410001dae4cfbb02b3572fee1c15b7a7c0b0dd45"
    ["1.51.1/arm64"]="a5b6c30415bc9c6c9b20721272454fb5db5cd5d686a6254ca7c3528175e7a7b11851789af2865291df5f983e18add7c5a0098ded77491a42dadcc77d744b5e91"
    ["1.51.0/amd64"]="86a4ad2ca0e0d03f6f3eeda220ff44fb35d5a968638041c527141a223e2f7f739c4c1b1e8949b839c24c987bce8509d700d0fd415a820931b18176c98de9cc4e"
    ["1.51.0/arm64"]="29dc766559173a5b7d60585fc273f39870c7d4931b462dd8bc475f9862ee34415485133ca768ccd8eb620a4105cead928bd3826ac17ce9cbbbc9c79121ba7434"
    ["1.50.0/amd64"]="c410ec7744429559ff761d84fe43865d3ce64add55d84725c1fca9114df3cb29e5644400cd9808e55e7851ffdca69052881dee51e9a2a437d67343a8f23501d2"
    ["1.50.0/arm64"]="2feb8d3b95209b05f733dedd998462b3e4a6d74cde15ea3de225ee35e60efc0dd6efe2bed758253f6e55fc02e631d8e0a1a0463129ce00f60d1f594fdd71669e"
    ["1.49.0/amd64"]="719af223d5aeaacf95866650f59ea34ed83592a6d25f476046961d7f4bcbe39230625e04b087c9658210f2f387e6785dbfa03e10abe8ec34a32a6b42a02ccfb7"
    ["1.49.0/arm64"]="9fa4352630b1b18f9afe987ad9c8668123ac60f703cf723d5707767b8edfc6861b6e2aa48bdf77a509c196e41fb15d9f49cea62b5e2f684ce345d457acaa04f5"
    ["1.48.0/amd64"]="1fb54a9eae1bcce6cf6053609ebc9eaaa9dd5188da7c121ef9d05ee43f97e0ad7ef0dac86c4c60476a9b10d777479466eeb280ce3d39f9d3a7417bcaf3323a42"
    ["1.48.0/arm64"]="f2e1c495e03ef774b140af18bdeb42040a7e542d9ec5ea9a8a767248fbc5ec8efd50b8072cb224c24766992a4de2cbcf020889ec2a6060de9323178801b8e011"
    # Version 1.47.0 was not released correctly.
    ["1.46.0/amd64"]="9d2a86b0cbb7c9baa17ef4f44293886816072b25df045934ec71b64b8ac79da2856ecea2a945657f5ded7f23fdee38c2dee7a7b46f51bddf2dcb915c63f366ba"
    ["1.46.0/arm64"]="bc2e2b33bcb8017a8026911b703946854f13cdc7944aa49f247782d4fde83cec6d65a962a4c4d2644a4a3546c32d0379315906f5e0cdb85253243ace2a7dd0c7"
    ["1.45.1/amd64"]="4da3d7328e163d430154330709ced75747359116e4905c324fc1173a6d9767163af52bcbcb6a5373ac9d0fc0d008608cf6a0b2318ddb9471d04792ed4bb2876d"
    ["1.45.1/arm64"]="ba53525557129dbc623833ee5655c5a643a4d3a23227bb38492c48ed6b93739019d46b09ac4649982eb14ef3643d14dff2c9e098538b2a228d8ddc98d0bb957d"
    ["1.45.0/amd64"]="1f9717a102e117b9a541001e27c4275f17cab640f606d20c3d298cc838d6959870dafd0932a5f1bc36363cb6df288ab6c2824cdb2f98b8edfdf234546cf6b954"
    ["1.45.0/arm64"]="a4dae3d023c3068c13b345c78c657ebb1bfadd766b3a725a824bef1e78ab296846b7468fea2bbfbe1ddbaa19cda18deca59e74c6058d0e72354fce6f24912e25"
    ["1.44.0/amd64"]="5b456c03d56eeeb4a77ccebcc9b89b902fd031d8a5fcdf816f1fea405035bfad9d6a1db215938bef8229e3a1704e368a77571b7c5854ef26e2282c163fa07f1d"
    ["1.44.0/arm64"]="cb9e7d356e77fd12cd306d6ef51d654cc4ba9e6c6238f7be96c6df85f92cf3f96faad8531a0161724cdad56679eb5141f6b06fb85479fc1adc927dcfdbbe9986"
    ["1.43.0/amd64"]="10d6d395c365def839fe4daef6df8e6e143d2f053f2b0e7f1c206ab4ba5009eaae40abeb3df05ba6f40b88156e9ed74b87f5d605ba4a88271d6307fadaf96bc2"
    ["1.43.0/arm64"]="398e72b1197d75a0dfd87b398bb37d47eb033746d16e2be7f32b73f45cc164b0e4f5e78f325ad502fa43d77e0e5c26325dcfae6ca9ad376f626af0242a96bd81"
    ["1.42.4/amd64"]="5c07d9ef802b9a2c270548ca0d3eef3a52f4004882ec6ac08333aea59a781e4ed09dc73bd50f1ac99be84b9b1a44219e08894a0bb3f43f34272930f932095a1d"
    ["1.42.4/arm64"]="c7dfa06d0b7915a3caef252a284b74169683049cf2e3c0827a4ac93c847a63d28655798cbae3c30d198c318624f052f395ebbc778a3df63e23ddefa76f139085"
    ["1.42.3/amd64"]="0b8ce93d449bba33b9f1ca53ab55b6bba36a242291b70bf49e5130f2721af16bd4219182d6ee664c8d66274f4fded635f47748253f9d4ec7486acff3e0c67eae"
    ["1.42.3/arm64"]="7960a54773362a10f97d546a4ac1a3c913b38dcec0531c2ca0eb507c6e3e444c51f5184e77380f1d6a4a3d52113dc1e05e7c98a2c80883dcffdaab79438b4cb7"
    ["1.42.2/amd64"]="4256b171eefe05d3c0b805dc7c24713b12028513253cac918d79fe44e19b35bcd556a56faa41f59a537ee1c3bbadf4b804ee2c5c3a74fdbc970a7d64fd8bdcdc"
    ["1.42.2/arm64"]="fc8f56894fd75017f4b636564896a902c2c8ba185b91ef2965c9e12090122948a983de03733d586d03260bb4e577dc28ec87b91d31a8f7d6c00bf8335a4486e8"
    ["1.42.1/amd64"]="bf23b69af6655981c8dfe48287b8c66b2800d420094888f0453b9048f2d4548b5ccb28d35e1078298bd1e35c48b0e297f8c0a1c5a38f59a66db9b95f9fa6c5ee"
    ["1.42.1/arm64"]="13966a6aba3a7bcf2837f21b46de88e7afb1caaaece829e1c22f5a68c3ff0fe9587d0f597993b3106dc4568921a45c8effd4517c74540039eca03b66da02044b"
    ["1.42.0/amd64"]="a52d16e45e6f8027d6f5f5ac34093073587f6caa1b7b098c289306df80770e5afdc8d88880f663cff05a9bf33541bb7acbbe4a1cca30108cb366f3b3e5574d03"
    ["1.42.0/arm64"]="34def1e4ecad41a14fc2492f50f3924f072931415cabb48a62a4df9e4cb6711424f54f9d74c18a514a31d39ad23b76593a52455307fc2fbb2512d23ca0859589"
    ["1.41.2/amd64"]="81c7c7e782c8c59fc11d6e8f9febbd0accc4d18925021e13e5ad96bd98101374343820c47572fb47f4c40877caea0af5651f3247b7f94737e6a1a8fa4d172b14"
    ["1.41.2/arm64"]="a6a98d219462c3fc962ca84db73a654de2aa26f1a0bdbcc63397d06c5870a36dab567bea264ee78120b0fd20e14e8dbe90b84ddd910f058cacaa0f29029c4ba1"
    ["1.41.1/amd64"]="5f626baeee454dbd63e606cf5cb0d68441799b1267b440937ef13523ad63644abd183a28d6d70e13f9eb3c719c83f61eb234ce625d9170996a7018ced690b862"
    ["1.41.1/arm64"]="77e70bdc757cb1af3b1412194fed7fe9578ede7ced8a80e429e73305acb0a1097f2eff56d928359d91fd71cc7ef7369f3e5f3b70c9de56e9981bdaa0f85947ec"
    ["1.41.0/amd64"]="698d0a721a359925c789a0c8624f2eee2807ea55f4a450a7443913aec73040fb9c2039e81d7f1dbfaa9c2605d1b1c3e1cea9e8abb9c6294f1580bc9ce573a3e0"
    ["1.41.0/arm64"]="87f2e016b06fe9ba0ae37e389ace73a92421d7532f2b08c3eb45e90ecf520a2788428d172e789e5aaeed0719e54e2e23a8a9572200fbefe240d4bfe01fd135e3"
    ["1.40.1/amd64"]="6e4fc66b8d719968f52e76ff65498a89e1d1d388630c4596b6fe1d27c04cdc1b8e1b5215a6d9cfd21d2de7511967f6fc9a5ffc99791eb3873919007e5811c30f"
    ["1.40.1/arm64"]="04478db80fd771418f75bec2ba58120f00253de74828888d76fa33d56b312f3b82b8b8b0e2b1daf25abd1a8f6e62448447c8c53f9b2c13059ecaf74be2faf8a2"
    ["1.40.0/amd64"]="83e8055c2db3fbbd6202bef2e3e42f62c2b22885de667eb11e3e04014e840f78a4a394593ae7d6f2aec8e3e75f339e76dadbe4cc292e350334de78430d4924d1"
    ["1.40.0/arm64"]="6fad477169560cb4592a7efe0681d9903446058ded1f4848d34dcbe79a985b71101e2ea954c5f213ae21aa602b0ebff4cc0f2902f586cf2685da58b94f94f090"
    ["1.39.0/amd64"]="0f34ce4da70767d4a949e33bdce3639b15c47d7c5f5ae446f23a1fe6076f681ec274b5e268732d6ea10c1822103478d7c6ba186419580b13a0a6ee231d99b3c3"
    ["1.39.0/arm64"]="09fc11014100b19dd6c5c7835d39de86853aeb23c9a836833a24f310aa95bdd360570ce24616bfdb0939364aabae5625d728a0d6408bfdbc25b0149639f307c1"
    ["1.38.2/amd64"]="da294ba0401e5138177bbc41111bb63a767befa01c87ee11426ded55f42f8fc8ca583dbba997484982bdc2b8c03d105bbd399d56d20abbe67f9ec5cfcd640396"
    ["1.38.2/arm64"]="df5530dce0b563c2914a8e2b07e80824054023546a73f6a6e69dd1284fda2f694c71d19d510ace3478f185ae526c46daca113eeb5431b2ada4d102b4ace87963"
    # Version 1.38.1 was not released correctly.
    ["1.38.0/amd64"]="8425e765e52afb00bce8217a3697eaaa31b92ea327c875975142d08638fcd8af9a285c79f6f95de9ed574a8ccdf5afa866ca4bea437a4513161f34b7a8d650fd"
    ["1.38.0/arm64"]="d2464d373835b827e3d296db2a34d0c1b0f60445848677fc12c35cf064d4d200a02dd531c05a923222ceeb88749511ba4ca87ef3cec0a14355bdebbb6b9a2011"
    ["1.37.0/amd64"]="95f09a01a274098e0c10ee38afe9888131d04939e46aacd4ce9c3b5c16aa7569579914d4fd6a2bd6d61e6d41ffe9ddc29f7ce9648ebbc110f504dd708f59d3b4"
    ["1.37.0/arm64"]="95f565cc5fbb0f8651d4d860e4810c8ed4a45ea3c9debac0416d8c371b1eff37093585b593dda0845643362e87dc2ef1b7300f510d41250eb83be47bec645269"
    ["1.36.0/amd64"]="5f59351d445f51d8e0e49d2917d47c35319b1be6430d47cf162f121c1f5ccf4c86902f8722b066ce948815f17c43e0e8a4bdd385563a59a366a27566e01ddd09"
    ["1.36.0/arm64"]="cc01d962662df996fb91e9bc1a7e3bf8da624b34a3eae82f0d9ae30370a70f501b82a283ad25cb75ee9d89babe9c3d0bccbb34408cfdbb355aed305d778a530c"
    # Version 1.35.0 was not released correctly.
    ["1.34.2/amd64"]="bd711112fed41aad49042498887445619a00b36f69d4e86fc7f7003c050c213c2defc6d67fef2e80243cdab16a833dd8f6c356782e85449333ad25fa40f02ac8"
    ["1.34.2/arm64"]="9043eec35bdfc51a1115c35122649ba01b5a6ac532946c52af855ac0e25d24a044addc883e95b725ec0b525fd4f9f12100c655a036bf234837f53553f9357c1d"
    ["1.34.1/amd64"]="2eda12dceb22ca6e9013bbdbb6465fafafdcbb0866428fe81a5d8c58159dcc71a5a55a346758cb59351a37cb3002bd593e73c8d58629efede7040e566bd8097a"
    ["1.34.1/arm64"]="e52b300435f996a73c55f31a872e0df08e1fc11f11f9276fca4e2577409dad3ec183720f123f7fb6fe467dc5430248ec77035482f55bd99ceb6683f2903aa5c1"
    # Version 1.34.0 was not released correctly.
    ["1.33.0/amd64"]="36c1c6085df561e99bd2743cd025d91329331c922356648eac6e780130f31955ca15f06b9056b5a065589a39df7ce1637ac3c97a05f5b18c00049b0fd0121f81"
    ["1.33.0/arm64"]="384b60214da382ee076fdb664340507851a1f4facb750b9e98fc337c4f4a2e88f72a40271bc534504e1cd4cb87276492e07c6024f19dbd9d5fb4a9de8f0babf4"
    ["1.32.0/amd64"]="60ffe5cee324189909b032ddfe9ca4ddfaea486592034fc4a19f1b556beab920365b5a70f5e0c017d3ac38188d87d8611004db61f872ceb2d0cef20be3175d70"
    ["1.32.0/arm64"]="8e36b1a5e1e5376b8e733f78c0612177c0df41d9d66d586f7069db9ea1ee25a21cb92dc8d70fa700d147c0a8426d633205688aacb32eb3d65cf1f4899dc8ce92"
    ["1.31.0/amd64"]="d750c25c3c3bd810cb9c88a9be0ab7d7788a316496b51d22ba4c481ff71b7e29d3bd606b2f341b19d65302ad5c1fa4879618dbfa33706bb61521c98085fbc711"
    ["1.31.0/arm64"]="b982b3431a86e7bb0ab64404eec6a36317a05dc4fcf062ba7066656fa4b88deedc44b6b9f092607825989d1563b7bcf584aef94f38412f796ff8bad345cb5b94"
    ["1.30.0/amd64"]="5158a1d2913902c111fbb1fe3b5f8aba82fc75bb51825e2d381557e05defbb17db8a32bb7211c13d24c96fc0103b86012c4603cf1caa41b8dfb6124bdecf1cdb"
    ["1.30.0/arm64"]="4c80e100bce37c0b1a14fb5b4a3c4ffa5da6e36f06ce47cb3843752cb793a429d6a9dc75233dca6a0b76b6a9a454d1a78848b22f9204d6f46bf5cda1b7ea3713"
    ["1.29.1/amd64"]="00a2d82300dd674c86cb5f7118d60e2d98ed9b43ab3583e3169a82bdf38a368ccdb997567c2479fe00e0f770f117165b38d66c51b960e9857010802a8a6da8f5"
    ["1.29.1/arm64"]="783c40b59efb9794a422a436d8be09e4ef582a236515b2d87954d1e8a4d9dc4b4a14bd0a228e8682fad75324795c4420fb66377a96f5e9d66665875009de6024"
    ["1.29.0/amd64"]="1d82ff92c15ab8fd9f84edc2d6e215e42d6ec1170e14a3a672d498aaa82e09305b24fc6a0d799bba17eb13055dd336f4e19e954fb178afd94e0c6e9b81d69f64"
    ["1.29.0/arm64"]="1eccab576fb6dc3e68b49be0d5df1c1752d335e831da8c7865fff6c13f71604f600079a7b8b537c4f5d7dc9e32421ef94d277a75475f4de5ba529699f0fa597c"
    ["1.28.0/amd64"]="a6d66e2c01b260a7968aa17c7f358221c21064c12c68dfd34f2adf9a992f689ddcfc460a87abc538febab793732f2fb587d4a16f3f32c072f441458e930af20d"
    ["1.28.0/arm64"]="b81f754764d637e1f38a7b12448609af01c665b0a3b35a91510370286102f8b9bff4eae2251fb94460b94a8ac7a02a20d929d072be7642fa7b02190dd05f29b8"
    ["1.27.1/amd64"]="2f2e1379cc88230b63852c8eefda9d4a2fbf82f69d72e8c5701c5a4c4c1cb7e7ce9362288fb2de4bfc69be61a8f8f0c0147ff1a904a58adebf67683f6eb095b5"
    ["1.27.1/arm64"]="482a811f5afa819d3bc3cc75820e2ac8ca25dfa79f16d4d9bfbf41114a79bbe393d26ed9b7b8447a2f39fe9c1d5f03c2724d38271526c1ecfd6475a634918d0f"
    ["1.27.0/amd64"]="184b90dd024eec2e256f43b744f83e1fb0c67b4ada3000046b0194151b2bc9dd18a189c18fc75ac77bce731f5ca1632c541f9a7672b840b0ef8f63429b155d6c"
    ["1.27.0/arm64"]="cb66664e0ca9645287051c3592ae3ab090bb416f6fff0d37fe8965e67b45d1d8d65ca559682acfe399651b79f5a95f2d8ccd8e5633b314bc0b6eb92dff952c2b"
    ["1.26.1/amd64"]="e80855472b51ad02f4567e11b9974ba289ab681115659fa258cdb246c986a7fb19053faeda801fe9ab4aaecf1943ffabe85c14e3a8b9cf6f0f6547675f6e23cb"
    ["1.26.1/arm64"]="20029c2ce580dcd442a7b1da97961b855c0228937d090ed2b4462c2ae44a15c6a38f5fdfe5d366afc6fabc594a5e40663f81b042422bab8e6edb30e79e0e5c52"
    ["1.26.0/amd64"]="48abaf0d42d5618870a6a3b60246c5acde2b4e7bb1d4f5055d262e7544083faf67d71f7aeabaa945e72ffc1d1e1b264c5eaed1e04559a5bcbbacfec00eb9e14f"
    ["1.26.0/arm64"]="7d771e8324212cec47719665688f964adeacd3c98463a837990ec8ecf2a4274d3fb7c0299232871cb143e804b52b7ed192885b925533caf7923bcfc45dda74cd"
    ["1.25.1/amd64"]="7f5e749361b737f09452297838f4296f153615e6acf32fccee5dee87d57335bef956575a1aad79ce89668adec32bfc8c316df3599d13da05e25b239b288a6592"
    ["1.25.1/arm64"]="32d400a4e201df64824e2a172286ea9a91af51007f3f8624749efa892785c8503cbc3fd6213e215a2fc21c5885473b59afef73b4c9289415e1a8d08973d22fa2"
    ["1.25.0/amd64"]="984e70c8e03bb2321cacb54cb9a101a1f0d8db27ddf4ea7cc2be974ef7a73090912d0806186efd14e89634c719ec1b8b209708734123a7bd201a58b91044c9b6"
    ["1.25.0/arm64"]="2135c313ea66733384a8f068dc929e19ef2395d52b4e4287b2c369f0fc869260ef11f466406b3af7b0a836fece92d738e4e45520ea08b3f3aba1ea3b41999870"
    ["1.24.0/amd64"]="69ddc4ef83243bda01946bc53c1d6bc261c3f9eca9aa459ceb46f731c961e229a1e2fd83b64f4cf04e8ef7b7c0f702331495719ce5490fbff7d738e99dde6585"
    ["1.24.0/arm64"]="1ef5b39abb9f3d868b39eb2579a3992b0b982f097fc2b2f92cff4a41ac3a1576adec78fba6f066ed018875499bb0e80ad90ffb0cc049b380cc8815dace0286f6"
    ["1.23.1/amd64"]="43223b86885a3cec20d2d5d6fa5dea7c05debbfe46709a8ee2d9a18896f068133b5c94e27b41d8d874e98fa1b4f1d5ab1d097a27da52c291c309f82bfcdd4bad"
    ["1.23.1/arm64"]="4293cbc626e6403069fd631bef000c097d4fea6f8f1255dcd3d2734733fbd7e92a040d3e3aae1c21a80e42ee53fae853af275f43030276fdffb99f841ca80332"
    ["1.23.0/amd64"]="e0f44cfe28e94d0ea190355aa2a42e637047341c984774bc35d1b35327b54f71814a5ec18897c258b31ba92c03d47764c758ee7c6b09df659333d9053faf4ad5"
    ["1.23.0/arm64"]="ba6236e48bca394b798538a7a451dd35004199e14b8086bf9d38cc5d9b995da4400a5ce8ea46eb1d623a8f13d2b3bf607f5f9cf05fd68fafebf397562186ccea"
    ["1.22.0/amd64"]="91b8e971eb4ae17418eb8649ec4f2aa752b6ed748d1b4db23ce5905e2f4689cef8c6301ed76ee77e3de96e5e4c9fcb4bb724af906757dd2a17661352b91d83ed"
    ["1.22.0/arm64"]="da8509a3025aefd5bfaeae8c5c78b544b73bfb36047860f52410b909a7ee6181fc3d42d24582505da75d4da51c8617891b733e2f528cafe1be20e16e4a3f4001"
    ["1.21.0/amd64"]="116cbacd48a816b28d8e84c83a402a06446f51e5543e8ea0390bd27688246b36cd3481eea5f7bca5cc00049b248504997f2eb000bd6021d7c7ebf01437b62169"
    ["1.21.0/arm64"]="9fee2a2b0445574e04c355f059e603f92b4827042b662bf7869525ec4f5a0a691f60eaff47ba7eef4dfe4f12c3b90b4944903d24bcf5113b2bf21d069898d0a8"
    ["1.20.0/amd64"]="57c8f8dbea2d4b1880da7398aa8314f97f3f74538e7500f4163cd3423b5d484a0623b56733989697e3d9265725194890a1e35889975d1faa7d71038caaafe128"
    ["1.20.0/arm64"]="ef1767ae7ec9ee86f80e465ea964c1c2288dbc4430b668a251fbd8392a347c764093d338fe71731603f4641e0d6416d17278fddb7770a4c7e0bc5468ba26a8b7"
    ["1.19.0/amd64"]="82361da107c96bee91c8a507251219f8fe60114eba6cb8ac001aa1dad57ebf662830ca2f95fd524c897265be86e00d024a8196afc6137c66984c01c16ca936bf"
    ["1.19.0/arm64"]="8dc0cd0593fb150713a5abe85c1c21a7fe3923355ecf188e281464acf205b13a0f5ba7b63325edea4f536c14f819b5069acb3d70aa699e87209280607d2ef244"
    ["1.18.1/amd64"]="f27223d07085f773328e7edc34b43ee2a592b48bd140e2adfac8d9d8d5acbeac1f753e23ca5b207cf5807eec13dba4c324c978d4fd492642f89feafe015d407c"
    ["1.18.1/arm64"]="496e9dc2c8593fc4d57db8d76f8936bb2d7ba9c93f0a7afdcb6aac96353434c72e22149f008db37f90fdd26c3158a73a744822d8e11c50ee2dc1045391b89a4e"
    ["1.18.0/amd64"]="a4243b45bb6c58342a630b143dabfa6718ed9857afd4dde35fd62f6ae73ed7750274c99bfaf179024605ae719159716ce182daf0acb9d7c9260470dc6c1cd3e0"
    ["1.18.0/arm64"]="997e517e384850788e6d0d3544aeea288dc2824cf8e467774b08bbc626d388edb330c436d07084b28934af174638d40f5a849a70784b2e3447d8d63c661ba622"
    ["1.17.0/amd64"]="a1d7ad2422e3d13baa932a7e5d58ca27f2a0800228f40b9e5923b50ee08021deb38a0157736e6dfabebe66f723dfaaba48ba258d0d989356b87f1aaa164ef582"
    ["1.17.0/arm64"]="b4b6bd129702f2185b283f471545e82b588044d4a3469de235f60e6db2aa86debd78af1269042d9653d700e9805d8b300e97df447bf5bfe11f5fb3071d14b172"
    ["1.16.0/amd64"]="78147301fd2a681eec5ba684aa7970595918acf0357d113173efad6af1a6b32e41f646ed83a6559039ff8c8156971619cbc8561702f9f14c0e2f72f79b22c24e"
    ["1.16.0/arm64"]="6060e4774f8034445edd93956827992937ca45c08d208c24ba8e078a10016c9b7b58502f20dfbd01f2f70298f6aa3ecc03224ab9130831c4ec227999b307a044"
    ["1.15.0/amd64"]="638889b3050a4431ac5affd92da3b99e8218b0519fc8548017c686081ee9e56594a347e3e0e7e3bb6b56c1fb9da3b10218558a8063ed057b79b2ae49249319a6"
    ["1.15.0/arm64"]="a6e69c50e89799475292854a3450ee4267a6671bdf1db3bc93f861aa964ec39220363bdfbfc93e58b23277b9aafd33f4987dcda0505f874a70d7cb8d5e3cc322"
    ["1.14.2/amd64"]="d1fa2af4c0ee8e40ac72de02fd3cbdbf7c82a3e3329aa5ed5cf8aa207d6ef8d2f452ff7bcb11a39538152405b926ceee66e6f6f44e1807036558952ace7f582e"
    ["1.14.2/arm64"]="0b6a1caeca624f51849f8a9387d68c3efbece407c2c0850021bbc5714d5b6a1397d15d4841fff2c32c40b599a7b4f785bb494e37086b24f0873a3bcd47a9efa3"
    ["1.14.1/amd64"]="ae05957acb0714361723065d5f107ffce81367da73abb8a708c19209e288d56c31294526ccd7822300a7fd1d324ca54e22897071f498bb7240ff648de73c8dce"
    ["1.14.1/arm64"]="35913e455c8192d7ca953133aa75b767919997682b527699bc7080ae753e578b25b3ef4a115bb5384ec1f9c23613f4ad33fc26690897c80d661b2134a543e782"
    ["1.14.0/amd64"]="12413850c3c906aa5169e795377e2cb3c7914271cf4ef671c4db742742414fcee02788514c87ca433906b135be9235f0eecfff3b056188c36ba7901bab7b1f7f"
    ["1.14.0/arm64"]="0fb7f7239c7a12b76b8dec2d30f4badd18e320dc4e83e93b0a51656394717fd38a54ef4b0485ca1889eb319edb907c64c14bca9b9525ae1ba61a650862a7162d"
    ["1.13.0/amd64"]="eb0af40485b85e0fdd1cd52ee67ff193cdea93a1cc3790510d7378e6b20123eebe7ea54873b2a66bd141433dd12c32fffc95e0761844c58acfd20d190feef721"
    ["1.13.0/arm64"]="b24e22cc45c7da5fbfae1cf99dcb43fae6a1c7933dbb96390f6aab61ba6e66ed081550bc7995b05095ec8b3673b6c1f576575c708b581c6e4e75c226069ca371"
    ["1.12.2/amd64"]="cd521558641bcf24af1e130ff4e1cd45302e78bf22b2fcf0d04ff831fe27a926f3129b3a3b02ac6fe4497db9e8d43d40a23caf5f847127fc0c39e714724a137c"
    ["1.12.2/arm64"]="544359e7605dea717b0230fcbe4c0f7fb90e8ec142fbef0d689795724eb15c412ee663b161f89df3a42543936f8fbde5f77fadf26827abd1281223fa63fbac6c"
    # Version 1.12.0 and 1.12.1 were not released correctly.
    ["1.11.1/amd64"]="9c55bbcf5b248b52dd2b9d0e0785abe548d0550db2202c1a66b219b2653060ee9aebedf8e3e94bdd6150897a5a47154c46637f375ee852105d665b7b9b43e437"
    ["1.11.1/arm64"]="b02ead81b183f9d696104f1ff5095f946c9e4373cc58767c5c79acd5ecc8b02e42c1b32f9635cee292716c0008e318ac9f16fa9253bd62a778b96aa689856bcd"
    ["1.11.0/amd64"]="30872c3c9004e6699bf2afe587acc30aa6df613b4c01c66720cc5b8fec387121f8aab858191916b1182deea4fa1fdb0262af6937605e3eae1beb652aaa625231"
    ["1.11.0/arm64"]="94ea13299c30fbfcc502775812195d07b060632eb17921f5e2a0103d42d578b388c4a6c53d7059007b1b9363a24c45056da1915fde22aa8af5ace3f57514d225"
    ["1.10.0/amd64"]="ce4348e853bdaabe82e698f18137d4a7d58291f458c152bc8b32b5dd2895dd58b274bd1603b4b6b08069ef96733f08482581e9cf176af4aabd1bcc6e39b2e9f9"
    ["1.10.0/arm64"]="97ed759c2c8c3530f2a57ae9fcbe672b6b6bc79c39b1d81baf5d02e2428546d53c37034fdb9c2f8cbe4e849b2415ec1d0629a1449c3ec0b2a2f4ee39fc69f7b2"
    ["1.9.0/amd64"]="703e0d4afb0713fe84750b1cb6a60b61c24e728413077fa29ed474e1207a46c32ef4a968d4533b4a59045f8ee150e200354b2bbef42912e767fb40968b353f0a"
    ["1.9.0/arm64"]="7c3d02df23a64f883ddbf75a3f31075d0a03d481c35d1238199c9a865fdd44dbc1f6303a806c420173fb38aab86ede51252f8eb1b75fcc6dec313e2280a6fcef"
    ["1.8.0/amd64"]="0897cad6077c2abe9c095b20dfda240836b136892a816f4a550a374820e801f919badfc2d370ef54f80db57d8abc86388004f2561f90beb87e6c7b2889388501"
    ["1.8.0/arm64"]="1fe0491e58534d63620fa9c6e66770d97d9bb908be3063f1b6169aff47c3dd4aa267263f4aa848ff0acfd5ed741b063aa0ae11dd938c12e144dc1d2b8ecaa22f"
    ["1.7.0/amd64"]="3261a585d723eb427db271c997797fa376ce728ca4e708b1f418efe9c77687a0d93dabe1dd77d5578d09bd494e5d0b3fb6b3d16732f19ef6350748f34a07d58f"
    ["1.7.0/arm64"]="f2cdd51baaaf0c0eb619c791497dce9307c6fe977aaafca7de8d44c4b2cfce50396e1b94ae44192542625b460e68c1529f5e9176bcf838eca158732d0cdf9924"
    ["1.6.0/amd64"]="e174be826f7979bebd32776ed0ac4a6bd81d9524d8201e08ce799d8540b5b1bbd345f121abe454a3e1d560b1fec6d50603dfe1d91a7229a07530f487960debd5"
    ["1.6.0/arm64"]="fefd630d3881e1ea0fe7714ab43ccd484c522750748d4f5f45274ed62776f149143d30a9ce387969cbf253ec9a633c6e480c95822e83f809708dcc8db0823fc8"
    ["1.5.0/amd64"]="3a66c91e2cae1ec89bae3397e7851369d06600bf29e33d968556a160faf22ad8a5646b447f8d537aaca6396abbfe9f59958080a825cff5a188c5adc6d19a9cac"
    ["1.5.0/arm64"]="2b8fbe9cf625fd25f2fea7d1333dc071d01af72e7ea12fb742eddf6146d3885a5d89b47e9f909d9f55faf0d8245a8e6efe9f08722698d3a1a2406f4dc6dc5bb6"
    ["1.4.1/amd64"]="4d9d4b68b20d77b021159478fb0f1a3ddc116444a26fea98c99a05132da88fb283099fa0eeba66c12a741fdcc81e274f40d15be8dad0007076ebce72f4558ace"
    ["1.4.1/arm64"]="10385bcbd3647aa00645bdef8427e7788335e15daf00c3571d89ae759b4316964c65d82482411166abc255538636073e2c69f8ac49bb4d5b880e15eac8035979"
    ["1.4.0/amd64"]="9352c50939d0211ee9d1eb292bf1678906442c9015c6ad6fe983d691aefb0aa952fa86db897d5fc8747658a8ac82abebf3f88a844e8b60be636421b9595b0b0f"
    ["1.4.0/arm64"]="fc9a55f54a1c4eb73de3a5147c1dfd76bd367df1f7eb3e9a631a0d3404b9d7486275385b0879ba0e5b46a5106e149670d1e95921bb2ab4fd4baf1af436e4c0d5"
    ["1.3.0/amd64"]="9e1e810e4cfc6b50ed6c6c0412c6798b43e9eda90a96ec372e40daf8e20835316b8cf2a534778e19925b8ac573229123e9f885386c816f40e84b069985c38bb0"
    ["1.3.0/arm64"]="0c5f69c7a8a97d47d09bec0beaf9669bc5d19316fec322cba4356a99eaf5f0c22f7afae6971fd5ecb6aa993be9a5f738eaae09cb5ca2a298ca1e88a7d24eaaf7"
    ["1.2.0/amd64"]="60dbd15bffc4f4a098262c22c431c32e142e966d9f6fbf9f417979b6794df1729312b34406fae675b2a6b56bbe097b7395e877dcb29a5d0ba12b286e988fbe0a"
    ["1.2.0/arm64"]="5dd33a5f988b668e72187dd9dc99876e53d5834d430a67d1f5fc754697337fcd93550338688d7c1c6f742be1aa002a7a7b44e75f4693950edc076a363b182c40"
    ["1.1.1/amd64"]="add4f37bed3b4739aa01dbbd83a015bc4255aae50460360f37153069f3f921d7d3cbae85bdd7cdbdd748594acf851bcff634df6e259d1a6a90adc8e099c05f6b"
    ["1.1.1/arm64"]="641306a08b1c5ba7ca16013312d0495d842658566f25a6cb36043033603c265d294c7c2e4c1d75ad33fa487ab95d3b7156735d0728f9c095d2043a624fbabb41"
    ["1.1.0/amd64"]="ad12c45d43c47e51fcef5602bc18f525d852b67798a223c00c2927a499cde1c90420cb30d5591cb838050c2729093e1bc4b4e54c7b360e17b3f856c0977a6f5c"
    ["1.1.0/arm64"]="b1c1d80d517fde505d8034a003da177d383a6fea29e615717f279f4dce313ff325c04b136de5f481fc85288dbceefcfe477711def1ea55a48be2e71a6dc6b877"
    ["1.0.1/amd64"]="c9d82a7abb00941a79dd3cb712effa137e0c1cb685778240eecaa023fd0274ae781fa666a8e42ed162f5e5941f3f05c1106dd8def3c1dcff9162fe588abab3ca"
    ["1.0.1/arm64"]="e10ca0c773aa42602d702a04a03f9bd60b21c3510229887b46993ee3ecc9a730f221465b75e6033107608369ec6f3a7e8eade952b65d0e947d715d0c99bad870"
    ["1.0.0/amd64"]="7948a12c9b431253ff8cb3d0a17e66423b3e2882cbb461bd72aec4019281e898b2244684fab388dc1dc99712493d16d349410f5b46c020004f937d4a6f9eadac"
    ["1.0.0/arm64"]="cc216b025cde697a29d24f9db9dd7850f4aa9077dcb2a64d7d83f1f8d613f30ab3cfcd4162541f2e9b0a80bc98862419ce0e771ea4786bf32871e2d82856574e"
    ["0.105.1/amd64"]="044461756d67aa863c1a6d709e3f29865121dcf0c773a8b4c609155dab97baae9e8541060ee82d3b79fa532f5f3332827b5c6548f0063554d9525361b2650e2e"
    ["0.105.1/arm64"]="33d59e8791c58d417b4e22dba0349218cd69f7a600792538e47b9b8bf267378091f2a8764d600e5c05b4204bb18475e8810786032a890f0766cc706ce2e77c4a"
    ["0.105.0/amd64"]="1f9b31dd6900395d07c2716c8fc2851866d6d38c60f209a0c4108551c981d1878eb125c1b31442f01b586db18755e172c6ca68d05eb5b3dd8c232dfe1844a654"
    ["0.105.0/arm64"]="32cac2e5505bb48993d96ddd653a7f988b13a9af9f5aeaabf9c52a2f0aa719b855a3cabc5b1883cdf536cf8e60b9a65cad60d7e1cfc347d047957526446e335c"
    ["0.104.0/amd64"]="aa216881a462a5d944f4c63e1ab1d3ff7eaf910d26a3f55d725a66a192944269fe9441943b993fa12b6897889671f8ff82c75e9f51353f020200690e8332f547"
    ["0.104.0/arm64"]="8c56d0130a1e4f8c52fbb1e14a87b364008fbd4f4faf25229eb53f593605f6c9a43cd86edc7abf16b69cc16bec5ace5b085c8c1262f5570c07e7f06473b074ee"
    ["0.103.1/amd64"]="413b6705d04c539f114bddb5dd03e4d9cdca53175c01d291058410e6150a357e672e9d466fde4f211c189de1202e5adec11bb9f5cd93bd6ee3abec60a872db60"
    ["0.103.1/arm64"]="3214535b176274670d1ab0424f0fcfbdcb0683bc9a91a7b106a47ffa54100f832cea9174ba82a4ee0b7b96a3ddbc052182aa8d9d64ea3bbb0ccc5a60cf908233"
    # Version 0.103.0 was not released correctly.
    ["0.102.0/amd64"]="9d414045319c739746320effc649d1fd75df0aca91fce4d40487ce3daef0d9a6d910150c3f1e92c30a5865004d12cd868625a3da34fc9b2cd740c0d2840fc6e4"
    ["0.102.0/arm64"]="0510d3254b9cadee48b69ed73aa30cb8be698fd81a9453eb01402825332bfa354892a0fa616e6191e842bb22f14f7ee1fe4ce4c881b2cf8cd5670bed932014bd"
    ["0.101.1/amd64"]="30adac71fbc3e74a784d3a38f62a704bac1c6f7ade2d70e2d73f684a7ee339ca79ef3199c332c82f2eb773cb0cfb460f401af0feacf61803e20cd82d75717669"
    ["0.101.1/arm64"]="8f55b50a75eedfc78d6c4f2a050a55a251db1b841b6ef21639a3a980049bbd2911d761b56b7234926e1f97369efcf551bcf0aca76756a010231b0aea34b2c4c5"
    ["0.101.0/amd64"]="02af46edb87b165501abaeeaefa7f03319bbeffaf41893e2bb217a53feb83f9a4aafa98866f7b5972a221fd5b06c8ac86812bc3577312a74dbc07ccc9772874e"
    ["0.101.0/arm64"]="eb7434f5648a40b4cd7b49ec01f2a90aee214cddd0391b36edd245107f82b05ccaa41586c4a55e0b30c624beda4d77b6b039b242bebc1cbc5afad5653020370d"
    ["0.100.0/amd64"]="fe8cc5bfc106fca1c0ea80434bf05379aba9afcc45d23c7f5d9e77888b3420e52cd37505da1ea2fad065d02f71f7873b25041719ae00c22aea563e3dcb43e1da"
    ["0.100.0/arm64"]="73c592f690acae648bb97efff91d46c151263ecc75e3c05a0d82cee06fccab91666465385064a77bc4620890b03817d570f39567d60a238e17d2f6d5dc5e983e"
    ["0.99.0/amd64"]="142f48c8be88f4fffe949563632194295abd2daf54ee0fcad40a62869d42037b15ea5ab49570f4c8cb53ee0c433cc52aa3629796d209a16fd933a34b28f09c13"
    ["0.99.0/arm64"]="7247bccf7a0e5ecdd02d28f2f0549c7bc6ccae1dcf29ffa07c5ba8f959f4312f3e713c52c475bde0643a9f7768561c244d9a60c47c6f9be73450071260be0be0"
    ["0.98.0/amd64"]="97ac0edaaccfb19582d0c0600fd2fefb72cfb44428fde7a413738bcf210e0fee495765ca01d00c0b11a547e02afe125e39285628d97d5106af64935800912c43"
    ["0.98.0/arm64"]="c67eb979c13f645e3ac08772812e3c36bdae0b8f11af18b7419866124fb73c16927a78574bcbb017683fc79cf17945284d2483f2eefefe218f876c0d5ca41cb5"
    ["0.97.1/amd64"]="d6dbe7a1c787c4dc68bee3824439c37cdba6daa62e6faf1193c5619ae37d27a8a47d6df3f23e60402dac5c7f363e4c4ffb835b979f5fa0f3afeb7072b59def16"
    ["0.97.1/arm64"]="a320a509dcb5c5924591de07ca058805a7b7affccad6433d2091eed024cf041aa4b9c0478cbc3ced039d8c7d8a05f598a079cf3276808e85bf1f37604581429c"
    ["0.97.0/amd64"]="52d22dc6b26c23da22bd70d221621a6e18587c81f0836ff190a264bdafde3e14879cbab93669a88d3c7693b43243d7f790b142da9955a7acb6301527c0fab3b8"
    ["0.97.0/arm64"]="a489dabf00f44120aa84104e5b3a0ee8d2661505405bd9630b7d9f88c7fd1d65c61f67dd55df2c404189ac75c83bfc7e6be4a87b7b1cb04562de71b44b6fcd52"
    ["0.96.0/amd64"]="f24144df15bfb8f864ba901b50ed3b9864dbd3927f7e53b4244bb3687d4ca9eb93b898dc51d13c976da40a210af2b4853790d4e07dd402958f0dede68e90b22d"
    ["0.96.0/arm64"]="d73ed4b36b2c14d71fa121c67b58910fd7a748107cec7e633a47205e38ec49f2cb94cbb78b699525fc3507f48e16a9dbe59e18564fc3013f80c73d59b19eee93"
    ["0.95.0/amd64"]="3a4c334d1497cde3a30061e599a4893ae4e025a03c86e173731b56de353436171e632f9e6a5a52ef2aed5ea55931093d5d1f873a2630a09eacc60352ac6238c4"
    ["0.95.0/arm64"]="2ed2423d2d3c9e44a1c10d6b1bdb3b5e757b16eed6d64568d4ada2f66bda6c4bc85c56c0a6a9f86bfa1595e48d77508e52589747f20af8dfc586c508fe3fbd2b"
    ["0.94.0/amd64"]="82e5b82b251ca7c1cffb4b2ae63aabdecb54d457c906618341e7e0c0aafedf02c892a623f659e6e3bf35ce64981505a68711ea54fec5ea21bbd784ebe357813c"
    ["0.94.0/arm64"]="c2ed1cc7a263381392d0806a04149ca714efebeb4b554c5eed298d8d8d9802d10d66bf2b46c2e2dfed27a2f7ce685ea7073811b9bd197786cbb465bd2dadcbb5"
    ["0.93.0/amd64"]="687db3fb5c25cf615947665f4615d7c64eea209cd21d5ec94a44268b23e2979f3d6703601d8b6ebb0c3c82e70d2cd4597df7f017568c611e8a20f4a0d1ac9a8a"
    ["0.93.0/arm64"]="79b03fe31e317511e06dc46bbf162c05eab6e0b102280df61125c7bc95fd4b94f6000b4f3da0b4ba5ae7c6a785653a6f769c51d16ab57cd31563f852182b6ce0"
    ["0.92.0/amd64"]="5865fbab5e760a9a1175ecb6151c29915b3dbab792d93fa16e85984be9014a55eea4b8bccda3fb67647eb2daba7121f05c6933abd12b276e7e2f60cd7e8a8175"
    ["0.92.0/arm64"]="99090ddba2ce84feae1e524ac59e62cad88c3723439914d580d0791cd5d26f7d490374398deb21ab3d1c6e44cbe814fc9764c48ce63a3126ef2070b0750efc77"
    ["0.91.0/amd64"]="94bb479b926889738d568c17d714da4b2fa0f764136b0e009ae01a7d32d646ea60a9009f9b10eacd5f0b93ffeb92a72e5e81d167c9d411a7fbc20910ab926851"
    ["0.91.0/arm64"]="987b5db4aa54c93b4b7977d4f3d942509117f29791aa70483e31f913eeb2add30f093884d9e74274fd4b75b202ed500e28a8dc8f09be2a852cc36f0d3c96fa21"
    ["0.90.0/amd64"]="1c35f07e49a1af56c65193bbdbf8b51724a238f1160441b76ba7320631750805b51e4eb24f8cbf84298a8b7801e19f55c9ac1a82cc99a6d16546e94fcbee99a8"
    ["0.90.0/arm64"]="f6b7db51b3af7987518110e97063d7d6a7d4b6eb113e877538ea5a27b66d6bc84d1388e53fec1b9ae03b1d26a378f95099542050d1fe92c7ac594f291d17eea7"
    ["0.89.0/amd64"]="35a7df22d79e7ee20ceb187ad18b879e18d73841525126642ba13dc832c82ccffef70a1822f1f26d92ffe014b3ba4fc7e0693a141c4b5e31342ea8a7339726f2"
    ["0.89.0/arm64"]="3e74d49cd2a5f598abffc6f4a8406755a945c8764ccc51a8a8d35a9d69b9d657da10a5c5fcf87a0db799f2a9cbf5ac5bcfc6fa9433b43ac72a0c3e28d72d5d64"
    ["0.88.0/amd64"]="6278668e4662b7f309be5e513de31daf4abd1b7d43d7e268537eedce1ecdff7e0783ca6d3fc85c742b1d890ba0cd567c222edd78af8a221dea6b6af90fa9cd18"
    ["0.88.0/arm64"]="dc66ad6d159b2241d0ce4c655b0fc5a325a5899aedab11f2375ddf964056d79121982c5223f219d9374a5f1a134d5b51d8c90e5d9cd78a45ae83bce787b9b7ca"
    ["0.87.1/amd64"]="4e60c62d9a4161ca72ed49037d12e07a8c6f87df495bffd46ce2398fb780ff254c142f4054f73fa22c44e7c56bd1520ede83d0f760c287ae4aee5fef351afaba"
    ["0.87.1/arm64"]="f4f098b9ebc27c97ba546e806f99a9147c0929e770336cea5a443ef464447101fb0059f35bdd325c7937ee2b3052e0470077d6ec6ec78c0ef66ad5d5f35a2d40"
    ["0.87.0/amd64"]="4ab5b5ab2a16d70929033ea0ed9aa15d1502e4d63fdc1f9381814703264a640ae4736c709f15829a12caa881a1be76d684bdfd0246dcb5cf47c60111353bacfb"
    ["0.87.0/arm64"]="d99b1ad3234c1717746f5cb71792ebac75b541be88c76073ef87230054b1592265ea94b95cfc974954f484085b981143f884c166bedaf4242415664dedb8f752"
    ["0.86.1/amd64"]="425b6c6b50d2386abac716ec811431fadc4d68988ce2b3f742d041d10fdf29bab7e585b9fa27c9cdb211b372e0b04eeee19cfbf1cbc40f71acc3c95c62bc1bdc"
    ["0.86.1/arm64"]="e9dd8ac80fb5f2f8a04cf33ab6c1e8f82d4332e782c6b73e953fc3c1afa5230584b5e0db90df621044dbc28611cc6d6e7a27e77899bc150b1cb879c83298c701"
    ["0.86.0/amd64"]="ea16ea12e06a9efc7da0277a02e1191c1aad99f39da227b4ce11d0b6f6baec201fed76d275131f0fc3a338b3159c5bf5aee4027f4e3f04f693a1bc027179c447"
    ["0.86.0/arm64"]="5a38ef9a1e95d8bf9b0684cb5f0d2ef576fd1ced80d8285347728b16aa4ecd4ce68ddf94a90216c8b1fde70abe4c8d5b4f89124a0aa3287aa9e87eadfce854ca"
    ["0.85.0/amd64"]="5ec16506a0966cf9d2c2feb299fce9968b887080d5b7ab82d858b5663272536967437bc5e29bd19cd52e0727252aaf257711a37aff38029f8d682651b3a6008c"
    ["0.85.0/arm64"]="577bb57f3c8cc89deee13b6de21df776c3fcc405a73624ab9cfb78c0091b51033f9b1c7810a0c1f5f8a790331645e1c02ee2b9d9bc2f61c993e6523204f455bb"
    ["0.84.1/amd64"]="852aeca53ee479d57bcc680ab359040e1cdbe387a287dad1c77533619417e64b333658499453d67a474457ec4f5017840ba541ea0423ab54c54662d8de764443"
    ["0.84.1/arm64"]="57fe29909ca43ab25eec87f90e03c7d3557edb8dfdd16ad55c06f8d1a0282e1b9b654e85e3176282de7fddecff28f47f54a65f6c18e63c882d163dcc67c43048"
    ["0.84.0/amd64"]="56f50e2d29ea7491d705f4502dce963453ca6576ef30d60c36ee5bf4f8eb9234bdaa39a58aeb4ce022c50b595ca58584ac9516194f7fe1ebb0f83e9d8347b5e7"
    ["0.84.0/arm64"]="ff76f273caf4a2da71318194f83bd3129e0b80faaf5d109a4292ba080b5af75c6009a588e054eead0dfd5ed5215a7035579df43f92af957508dfcdb62a54d8f1"
    ["0.83.1/amd64"]="dcf240395c26c43a27622495932c52fd748e5b56f5a20ae0c6168d3784a71fc4ee3d61a21f44ef0cc2a3b9dec74ae714cf5be583906541a8287d106e7f0d4850"
    ["0.83.1/arm64"]="aa093f9b7ba597dd8e47c50217e2b34dc8063beeaa7826a1ea0f7c472cd1a1f11996b5149a41052293ffd4bcc134f985c23ab2cc5f478a3621f903f5f8092c9d"
    ["0.83.0/amd64"]="1b35d29a0c9838e74ece0ab32ce4b74d2094319285d84ca36940a6a90519e34d57c9aaffe2cdd3785f4cecf28adec29f2b6eac49eb54a97f58e74d040826e94d"
    ["0.83.0/arm64"]="4402a330022185be07d5e6d841ebaa7616ef888e324e72cee3b6fb1ba332cf6186765b43dad66ea0699e0bd107f33bbd6713dac6df1a495c52a4d3adbf06cc71"
    ["0.82.0/amd64"]="53a2b3d7cd262fbf19ff6ef86910064c6542ca57cd0c0a324a8212112ec5801295108966418503a57a76c05ca175394315cf731fa14f152ce3d031f0f041a044"
    ["0.82.0/arm64"]="7f02538f5e6d9c7a4be4c06de5bc6e88fdf0ade7315d0a1934cac60f0ab4a09a729c35abf4dfe395cd6f7803e7aa0fc69cb78e5ae38d2fd80c11594506a8938e"
    ["0.81.0/amd64"]="872c70386841d4d5208349e50fbce15c1e858b3f3e0447293d3be168b2a0973671c40d56d830d92d60fa09e924491527f51c1bdca96f8028c2bce36f2b9a28a4"
    ["0.81.0/arm64"]="caa440721470f84064be5af10ca691e7020e9905526386b457ebe211711a0b16763ddff411ada70cb928620337ba12776968fa443becdad818a3fbc982df467f"
    ["0.80.0/amd64"]="0ee23c06c13fcd6b5f56e0fb4f729c343d6f1327dcbcbf6ffc57b1336a01f908353f8fee2ad4ed64db6a0b6c118013c43e6a9dbf3d65e0d3785d43f67e0271f5"
    ["0.80.0/arm64"]="6b28474b5cd28c26c7c11f30587f07ed38bd90780943ffe2f5312819def9679d8f79e1826f816e35d0c241bb44793ef0d7e69690e8880242728031f416c03bf9"
    ["0.79.0/amd64"]="c60e725464ed3e7f51a84bfebf281c873a3e6c0765a7ea6d2503cf7bde12a81f1fb846131cc08a72f85a6bdc6028079d2226cfe1f259f56a01dcde261a8fdeaa"
    ["0.79.0/arm64"]="dc1ee29be0ba09dbc788a609a0ce6fadd0976f807001346c9a7c072c47d64eda9e67ea055aa0c1fd4520fb642be82c8b6c01c9248c3247e6084fb4579525cecd"
    ["0.78.0/amd64"]="a8f79fed90dbf3ab278f4f513cb3f6db1ec8087de32bb066667a559abd59e5f5f82f22000a8ea9b15cadf1845eed2f8f8cf0cc61f11ab9807ce099b109985d97"
    ["0.78.0/arm64"]="8a613ccca86d3b0ce537c91bf67dcd035b8851f183d359243fc42c854287fbb2839f4c83c518137344a31e98731d34299d91d509b6e6ff68a2454081ab07831f"
    ["0.77.0/amd64"]="b4304b2170ea7152a8665c461043d7c8ee0cb00f75b998a4aeab1b45c474f945ef4d459506faa0cd68780311fb6f04b83dfa1673e4c7c7f4af4de30bc451b5ad"
    ["0.77.0/arm64"]="ea49920595f0dcbdf5c7608776568375a6483b1abdb7c1fb5184b5046723f3edc6d2c538c502e9ba10c990fbf71f28fffa080e0bec5d14ec80eee7190cdfa0ce"
    ["0.76.1/amd64"]="290fa2c407ef41deabab42027363da73abfe97ce78348a722a70d685743ecc6cf7ffec97d6a345011da27fb6ddd4dbaf8e7ab844855b9b01d4dc781bc1bb616c"
    ["0.76.1/arm64"]="4029846450b7b717ade9132afe5b609f44f3d1bf0b7102838c0044364085a3688bedf2a80368f828b8ca2d9a92bb76f1d46cae076ae31dbd473612aee5ac790c"
    ["0.76.0/amd64"]="70969f9c1757cd1a50115ef5990d0f2d5ee80ef8ff190591ec60cce84ff8069ca516ac7f467148bc7e93d41e57b4a3550830483fb1fd7a099ea2e592fa7b3b87"
    ["0.76.0/arm64"]="8d0f8296a9f3305766125798cb3589aed7314e4a4c4948bac67ca43a4b4b0e8dce77c6dd59c37e8fa3f7dad08221c49466bd546c73f726b8bb510c7d36a9df65"
    ["0.75.0/amd64"]="338c18544ba7c2459b6ae8a009b5d662085d9a80604aed815db0013eb8abd3f7ff68996ff4639199818270c611f7cff4609cd025b8220f99373baed7b9d2db97"
    ["0.75.0/arm64"]="9dc21515872ad9f23fbd32f592015b6107a4631b1cbd2bd60d12d3d1c625f4d562d4469251d907ce446e5fd3a82834f5e61b56933c7c40ecc4ddaec33128d7ea"
    ["0.74.1/amd64"]="0f7db2cdd65d9c41eec9898c8b7b29ccdb4bb71af4f2309ba2a407ccad02fe9f5ae7e51faa33f7c22c6ab1522e3ded914b212738ababab7fb4e055e5c1f87eaa"
    ["0.74.1/arm64"]="2be959952ca26a07d68a73132804d0bbd8fb92f52258c6818a87c5d6d9f7cf0b3bc06e6aaa74c702e6983effcdeeaeeaaa2e6c53233fab0caaefcd64000ec6eb"
    ["0.74.0/amd64"]="e0fecb33c61ca021a1f97560c1403dc0a5808f09004901ebee6bc8735480be7c9603a5f539109b6571a3b5c4892246684c28e6f7bb35f74021d0177053c1ba6a"
    ["0.74.0/arm64"]="d77afc8d9f615afb2dedd7b45888fd0fc23cc888c1950342888ce655acd8df1ebe1918efd9d847768f20f993d5d6ce0d66f1352b7e64cc71d742cce7696abb15"
    ["0.73.0/amd64"]="f088b588283a083b7fa186258a36ae0130fe053026a5304194e3b1896283aab0334b504fde7774224af6cafa2201d94e46e615eb04b5aa1d0286c2ab00dbf709"
    ["0.73.0/arm64"]="f8e4182066a681d966cbc891207a6e6d32aa10a3c572d97f5a7e36001d855bc68cb302423fbc7febd6a32a4e450196966f0878e0feca5a90c9ae5cc7ad4d6d48"
    ["0.72.1/amd64"]="0d7c0024c1c3e84237f17c443a08ed90dc8a3d831ecd8d8f7a7f16510a4d9c253e7eb497c68d9fb42ac7c70c6fdbb0715c6f01a258558aae232133593f00fab2"
    ["0.72.1/arm64"]="b20dfa1c4a83238847a99336a8cc39ad702fc8db8fd700b2f426bc9579364b8ae7eba4108a21226d02fb36fd30e86a0e1a57d683b4fa12d49732396f18f770dd"
    ["0.72.0/amd64"]="f413ffef66ae4c8125f59a75d59ada080f033f00bff31bf09355f7f1c0edfb5355e55e2d5a22aa220772297743db9545dbe947ac9af16fdf2e62c09515d97425"
    ["0.72.0/arm64"]="11368cab8706d26a01ac31ab2d3d9b5e652c02afb91486950eb8fbb106e699adcba5a703f7177530d5901c8b7d27b0fbc684175dae892141bf12c8a2340e0279"
    ["0.71.0/amd64"]="8856116b617614ddce73fec5c9dfce9cc672a87e6b6d75a1ed724fbbc0dbcdfd7d10760e22193ed4e43f017cf2b895c3669080708468d1cac7db8da09b89a0aa"
    ["0.71.0/arm64"]="da6620b3b27e626ddcd171487d3f4fe94171158cebafc295cd0cc8df37252ebffa5604e517f4ff0bbfee7f5a8d57175839a1fdabfb27a543027a6e6465c2262d"
    ["0.70.0/amd64"]="b4e8528723eb81046225329ac290ad5cc5df11764d8d24be9681c159a1bd313712d046882f58d0ca92239160e5c205b136aa2d0625669f8a18b4d13638fc1926"
    ["0.70.0/arm64"]="440d6efba26d1551cafdf822b88b42b8a8be6d21aa0c927954f0cba2732ecf966153ed9a693ef2dc1e8114c53827915c0a506bd84ccc8b701a34743a137c4d6d"
    ["0.69.1/amd64"]="7ba5d041023c3d6640c547d83b3ab93b5911ddbb1f875d83d11c599480b1a5e6b8a6175ef5e8227965d4ac983163c71b8ecbbebc919c312978c4b8bd726517f3"
    ["0.69.1/arm64"]="28e866f9849d88441ae5a61dcdecfefa2f03e785455bd25b357f97073a317a54e6ce13efd8557e8b0bf72de5d430e042da9a3368bb781848eaf94683aeab4c13"
    ["0.69.0/amd64"]="6a5645ab106af0d21e35d10233d78467d985df26605669170bc14723f81214cdf6ce2357a3d16b885cb8b9fb87af9a767fe511bb073ab3128323188b5e51383e"
    ["0.69.0/arm64"]="0950f66f955b140e03467dd224b3bc2f84cf48db1ee18687c7a56f59c2e776e9e6a7255360c38f1165e6aa673431dc71549f6054e9d6b0f976a37b9d5b693974"
    ["0.68.1/amd64"]="5ed3a74c7bb108ffdd58247a980005ed55772965fe64c90451f3ec4422f2a043dcb9d2a0e558b135df20012edd8a33827ee680afc399a0909b02f9f5c39146ef"
    ["0.68.1/arm64"]="0dbf4c9cb00a883563a7b64d0cb76942f1e3605f16bc0408803bc0b40c7acc5777905c470bf36586c72bfba74f11292ad0ce4fc2451a383956c7b2b4b781ed19"
    ["0.68.0/amd64"]="3e460e15d6db5e0ab790177784738f044dafa9ff4e311467097046635170fffa451f970b480193bdf33c3157faf28f20671798e9b50adb9274f64e62f2d68064"
    ["0.68.0/arm64"]="8165bf2c7eed98c75967a8f738e125c45ba8deed28b9f20322035b1a7fbf23d87d69aac9225abdf88a1755db1ed58da634fa905dd0c671ee15b7dbc6a341b62d"
    # Version 0.67.0 was not released correctly.
    ["0.66.2/amd64"]="d0cbc3c1b6f5cf6806b12d295ad2b488c0b37e559b9eea4ed68ab196b46a00bb2bc13d718ad1fcca3b6f5f330da11b5f284359a9718d5a3aeccc5a3fb6286a75"
    ["0.66.2/arm64"]="734b9c7d92382cb7ccf9fca5d98e31f7a5dcdf54f82dadc2d95086a1c004aa76149614706bcb795c4057a927d0e8da8569546420c77b79e0127fd74649784097"
    ["0.66.1/amd64"]="3045eb7bc6fbea3669f556347f156fbfffdc82d23cb816941884f7d2cb179bd0c8c1ecbdcc41ede70a53461361511361002571477b3740c8f12072c930738010"
    ["0.66.1/arm64"]="4605d2af0ee97059b91aa32f9b810f2a597b16c0649b1bc10978b0ca0e59e46e34ec792d38d3d3074aa48f67d5289fa154c8b42a59d4bbbff8fbb094424e46e9"
    ["0.66.0/amd64"]="a69b531136a06c07a52827ede77899b8d9c7a5c79cd337968829063883ef0181fa062109ebe62c9d49fef65a52cc0fa289e469eb05320b47d9e36222bc14e006"
    ["0.66.0/arm64"]="9cebc9020388ee827df96741dd2e89d7e18c33c09ee00627743a0b711c456c53bac7aba90ebd37f3d1c4528a0e03dc3643bd998769d122388f7a37de03d1657c"
    ["0.65.0/amd64"]="60e471ef08346abb1121290438db9ed03692a9772fd2f7d25e2fd2a23d1f3022139c88525702f1a8541058e7e8ee75530a63460433fc2a4afe956fd558c4417a"
    ["0.65.0/arm64"]="ee9f0436cdfbba72c9e91e800ec676ffdb636289cb94fca8d7a5dc39b652c346c626d0ec5bbd2dd3e2c46df5b9e616978e4b87eed532db5c21a1160254ae1785"
    ["0.64.0/amd64"]="39ba231cbc82bc913f62e5cd8a6871b960cfa384dbda59b1ba2b9ff4068c9aa1739f083c902de6f675c151bdb6095e3fb0d455928439c4e7bfd2f5489d158101"
    ["0.64.0/arm64"]="f9aa0d711b92e688a4ac858804b6cc0a40361b204fb84ef016598160d31e4be536429b9e9245b2d21df7ec3f3d0e0ae569221a6582d8a6e5a4dd6f65885d0b7d"
    ["0.63.0/amd64"]="ebb07c5c217014dc6e3d1b6589740173facf6d020dd5e38b8912b3580572a89f694546fb864af3893e36035baeac285df13ca1e802a593a1f8dc8354ab8e1264"
    ["0.63.0/arm64"]="84d32d64217c1397dda13b9dd2414da4a55b7be8fe6d06b40bfedf06e26f7bf5dd0f546bbac8fb58a28b8bed473531c42373d58f1e60eddd9bacea5f8901854a"
    ["0.62.3/amd64"]="90a41eb35632cfba4abacbed419fc815f5a5afd26efa21d67eae3413e9f003a8a459c9a90368cce64284cc527107df654e8ec9f4747f92eaf570c736aa7fea66"
    ["0.62.3/arm64"]="cab0885d85d2d7c0dfe6bdbf4ccf16ab4d217fe7d412bc9f11438f611f6b486996ba711a8c59ad221c044c01cce9ad3a5d8c816b4b9acfea7bac52fc84294c78"
    ["0.62.2/amd64"]="7af5d1810507af46bc8f04b6ddfc1a4b708cc2c9f52950ac12f6ce8b1dda893bda632aa63b4276cd92c2e13cbe9b4b2e1eb9f07672d90a282f4c4f9761b067db"
    ["0.62.2/arm64"]="5a091d645293fb1ff193b8bde389b632775c0f2a960337b84ec3e354b8fcbb1eb7b3bdc24beba490c1b7c134f9f4de5622d6c73dbed2edee1c7217412c5006db"
    ["0.62.1/amd64"]="8b069c830f78dd918edc4a574beea773e4a61326cf86ce70f0a835003c9f39fd5c925866393c3074c1628aa3f0b6b50f1895bbee7fb4ea9a376434c94ebae41a"
    ["0.62.1/arm64"]="0abe2b42e3f380dc562717240456e370283aebb544f5399bc301a18bb13e75b19d36fc18aa149861fef35f99cc080129b411ae2f6d1e5d3083bb86e09a680562"
    ["0.62.0/amd64"]="d7534067373318db2833f5bebb89eac7a8b63c28b92772c133d5446351b0c462dd1c10547794597d70d93a6221a3cbdc43eb96af388959c49d7bdefea8049ca2"
    ["0.62.0/arm64"]="35ca3304a8dde247e4d1c06a09d7d7ff961c12371109983d2ed19d238f8bc5f90ba1d8e995aa1d85e73a624aaf6dbbd4b316da9db60e9698e53e2e1ffa7c7ba9"
    ["0.61.0/amd64"]="b324d73e6aa9bdac3d4bfb335f025c88c6fba1dce723a358aef3154ad248036d3dcd1da9f7f4ca991397e2829a1aca5212503fff923728dcddae73a69f173a55"
    ["0.61.0/arm64"]="f413f89e9b720c61f487e1d4a8a3f2c0f7b2294a1b8cd951e69735aa3c901228933478b456223115e3872c3291c26604aebc3b88457e6ab48be2576f1ee342e2"
    ["0.60.3/amd64"]="460af0041046d1944128324c12068e19816f9e48edda3e28e927df20217b5eabebf06ac551464612be31104f599dc1012f63cbdbfb3766461a98c22c004a9909"
    ["0.60.3/arm64"]="ca2f305c5093b7b3002cd03a2ef7fc6f37b215721c1b24082d924c836e9686f52c74c3499456d4aefcfe12b02a77c258f1415aa8323cf59f92294dc953298c54"
    ["0.60.2/amd64"]="2d3b3b12a74a97b2be96edf2baa6ca16af6ca39fdd92e7f0313e2277cf99168075809ea19ef1cb2dd393cbb9753d9c8317520e487d2336c05ad1f7935bc9c69e"
    ["0.60.2/arm64"]="d20105c3b2b2a69582ded9c69cd744ac433b1fb9f11bccc6869dbee0487f8a28f2eee5496202360698daf3477885eab613b3e050fed37802eeb8d3553982db11"
    ["0.60.1/amd64"]="517766e1cedea55fa7e1ed780d0cb81d3f272eb4433368be5d09f521f5cdb91e14645d8110bf2b1097ce3f6c347feb6cc55b2ce397ae7a194e7582218bfdb9be"
    ["0.60.1/arm64"]="8b000bc12464a4c81109d39938b33b5dbb7955c2ab30ba359037f8851855af954898cd4774b37d2b79996f7bb6cebf1df9d7a049bbca8fbfc383e513ed3643ac"
    # Version 0.60.0 was not released correctly.
    ["0.59.0/amd64"]="723fd0536bd06ea73f29bb1f7f7bfc029ce1b7be95ecb2ab008ce74328ef1874dd796c5ca3f924a25365970ccd932077c1eb2c3f092a69d1b2586ca76f4f1ac7"
    ["0.59.0/arm64"]="3cd4d8728f9f2398cbf6a4efbe57a8487c18149b27a58c8c3d849e83ab9dd1572cf83446e9c580cb2f28bf5651580af4cb7cad8f38e4dc65580b18005fd715b5"
    ["0.58.0/amd64"]="640ac17acca75e8c5505b3287806737cf669c9b694eb2874e97016472942f18d7a50cc4f9c2553fbf9b3b73de574c2769297dd1321988445d4d57442fb8f1a51"
    ["0.58.0/arm64"]="8d8053d8eced4eea582da765229e4470fc1bb707d10fd490fcb4b48eb125ed50cf2051ca88d3f9409f566aeabcec06f5b955e285c9194021f124ac78858e0339"
    ["0.57.0/amd64"]="12718b777402bbbcd916c4e959b6243f1a12f8b15b72e2a78442f8b274588ec8886fd4d4d62c9e57b357ba8c011380720120d09ee96ee8c4332edd5f76df793f"
    ["0.57.0/arm64"]="5ff3e69bcd2215a639a51f8d1a1f2d65f84ce326f89401870b7751aa669ced5559a8a7d7db48c7425bd8a0e7b4a611fb57b569d77220453b38bb03c5b59c086f"
    ["0.56.0/amd64"]="f6f05206e1ebdb7c71a7c51ff6047c6f8235e6dded9a99a4633c579cd3a6f86def5871a2e742928197d93400e43ca18b20a0ccf1a75d21d1df70df97e1c8ba7f"
    ["0.56.0/arm64"]="a0e8bbde5cbfbe60d239807e9a5a1f9d23f9d196109fdf36f05b0895dafa57e18c27d4a923e4c18d5636f851e4d2d92591c29ba1f66ae27fdea70381db8794b4"
    ["0.55.0/amd64"]="22fab10492a7d3ac83ef904e8b2fb6b082405959dacbc1532ee5084e330f494c0aaf770a177e3fad015ee076240b216627690b2d6d2cf0d4f5e4fb5cab76e36e"
    ["0.55.0/arm64"]="148cda1f1e1e08c501f091f67ed87628f698a8245f9009331f13c2c41b35d73c7ddf520e4f238e7fef129449aee1d3cbd7588a66f74baa4c66d5f79a825c6ecf"
    ["0.54.0/amd64"]="ac463d3bfc0cf38dd464bab38b50eadf3ce7cbce79cc96f7b658599ace731d3ee64200f2acf3c23bee2f97066b88dce8fbf00033b120b3c0f596c3517ba8d4e2"
    ["0.54.0/arm64"]="6d6d7fc4fa93923153c727b4f44b7c20a81c785c3e2cb7a54f1cd3776995f054752418ccd7b12088ac5a371017ea6a63607a5490cc1a0346fd52c08c5afc1104"
    ["0.53.4/amd64"]="f5023720e9ec5d1d63bbca798a83fd99428479e2c29f8d04662c29e5783d3fd800b4f76f4f235e2a7671ce41284b51e85eaa466c00acee4da4a6737189f884d4"
    ["0.53.4/arm64"]="241e3282a2a05a100f6056bf3766c9f8fe4ff5e137a462f6af86629bf29983d4844226323a10a7eb123e9dbad164784a52e7b0f4f328d234671dca534bb0f557"
    ["0.53.3/amd64"]="d79e93ba8f7a5d4b7eb459460a44776f0fd5b93cb9daf3e5fd3189b3a9d6632aeb440c60d11949e3f1573e6d0c2af0982b79d2ddf780e18119b565b417558d2e"
    ["0.53.3/arm64"]="64020a597e5fc8bffb2d193046bd6d8bc4267e51be58da31cfd1ad83d56dc702ca8ca3d1337d6e59ab4fb439e5ad8dc92909a4b2e394e08d37bc379894512bae"
    ["0.53.2/amd64"]="c484aabb6c90c026094ef26b660af9dee0a414f6a51cda9ea225dae01a2155fae5d25fb6b3d80ae8663577d0088d7627ec503940577196ad85f483560208cd65"
    ["0.53.2/arm64"]="1598a2af484e1b1a05ebcaca912f3c284423cfa09201ce664dc0dcbf34ec7de2fed6e111f7a093281acc75232407eed85986606d57eef28c4a4bd8de64065eea"
    ["0.53.1/amd64"]="84ef445eb00d996790db0581d9ef9b04473a72f968ab47186e30ca8b5c226bd7b84133060940a775cbdde601e58950f44b1d2d2888de021e535a826d12adc92b"
    ["0.53.1/arm64"]="40a253d29435fe5536c13711414458ad4c0c920dbdbb2cc76a40c8b069a7db7b850183d76617ea638a201be669f7ebe3e402f703afda1619ea1921743cbbd21b"
    ["0.53.0/amd64"]="d8039e0d16b654bcfa944838402cab5c45e3e48245054b8423d83b21bcce312223aa029be0de4fa50cbcb8856d15c006618472b1c9ca7f57471ac5dc89f98149"
    ["0.53.0/arm64"]="7cc5ae0d4971a8d60f984588ab08164f05b6b2a381f3a86cc87bcc61049673402e66c71d36195e7186af8daf924a8fe4c56ad9fe1bfed37fec922ac47bbe2049"
    ["0.52.0/amd64"]="1711c09dd4ed36fa45cc0d53246ab3a0efc50d3e0235480eec87a1131e2b6809de6a30811654bca06957806c01e707909d1823bbb6efee8ec26c633d78e3917e"
    ["0.52.0/arm64"]="0c4ce02e284152681eca005661500b988865d3861de4ce33409a86bb1956a7d07170b7d89b3b3569e78c5b106997992a2f7cd2d5f21290ee3cab9a0f4e966c91"
    ["0.51.0/amd64"]="0cb397521f447b7712d265ed06e32fbf1afdcdeeadb864e81ce991fd71f8cb90c4428456c4e38d95e72b2a61cfe24f76d04dbb5090fe184f1adf062b79c9726e"
    ["0.51.0/arm64"]="2381375ca12441ee94c2fcbcac388fd8dce565fc0a4953ef34bbaf6423d10387ce7d3cbd1df936407ef7f2e993ca9b531fcbed2f554a1530f86fe60aa66b57a2"
    ["0.50.0/amd64"]="cbb6da5019a5dfe71dfd0b1f6d70b70c53b22aa89d0ff51f6ec236693d782bed9a3a41e31ea5131e24914f9279793496654246ed409343f3a0a76af3d3771c05"
    ["0.50.0/arm64"]="b8b17a6a8f5d7fca6a1be3bacc3a9e6d67e3094b826bbda68218770e8523271d89173278fa4e47ca8adbaf64e2ad46a16ce6972f3fbf947f5514c0677f1b6497"
    ["0.49.0/amd64"]="3e2c29320a028494b6097c9650666d1661e7ed92db26ba1aa9918f157e42280f0a68d91c58e1632f0bb2f814ab12dc24ec86a2c2688e6a50bbf8706c540f82e0"
    ["0.49.0/arm64"]="7046aba03d07a0167ef6bbf749f2125a5968017add3d23aae85cef5c86c0cd9bd847394d0960dbc4a4d6aaeacdb740f1eda7a13cccb33846df58d5493fe0506f"
    ["0.48.1/amd64"]="3f6fff5ac80469d6077123cf013e15557da053243a805f22e8e7df8b131ff9e433527ac9becf0d00a9b644d121c3b9f0821ac480956fdfa521ba0718cca2fb10"
    ["0.48.1/arm64"]="9fa3b725a077b3a7213c922da5406f142b79790538e27064af0044d74cd4b6dd6e784ca31cd6c58daa981725d42c934174b9e1c157fb05c76580fd4c334d0628"
    ["0.48.0/amd64"]="4312ff98fe71dea6a303f872f6ad050630ae327ba11641000d59c210180dc0b3c3d8438465f938cdc44450d4aafd8214d30cec179f2502304a8a5f0622180527"
    ["0.48.0/arm64"]="b8e28fa28a83ecc6f49cf791f2318561968dc6d7e20f83d0830bc242e1c18a44e82e3d38b7d346cd21fc953afd4f7202c7dbc13774398c6f0d799f247582fb3d"
    ["0.47.0/amd64"]="7210e150725dc73c95bff4f9b2c6cc192682cb7b96f28c31dfb8f660103e5f77c786d0a0d4c3fd1e8dcda7b19ad040fd996367d258b83ceabec3f36b276ee049"
    ["0.47.0/arm64"]="461868e99e1d98aeb3a348bb8e9c5fce465d394d96f104480ff43518ae91cf85262c1436c5f4082dd23a410cf08a24a4f3311b0a9375df724d435dd1184fc61a"
    ["0.46.3/amd64"]="f70b3c157eaf0e826b5a7db31f74334d17470af7b012baf3385501fd463b1d48ee150617d565c9cc1118fb35c3f580f8d7f74acb5deaf5dd699ad14cddb74dd4"
    ["0.46.3/arm64"]="a6f334f1013a65ee2837b5255db237f4d5e9126c635fcb3e02ec0c0f1ace28d6803e1185ee2ecb5630ec8f7b4375e267cc8fd4c0a97b0fe7c1a2b626a9d252ab"
    ["0.46.2/amd64"]="fb51fc67ecc6b4586c86165bfbb3b8835da71da7bbf00b0201a2bd540ee15b718cf90b1bd49749c8be2b7ffc366d99c0c5338784c06974e1e71cf3d8d6f1499a"
    ["0.46.2/arm64"]="e361cbd75ab2880ba1ed126f09d3749737c46a8c3364a14c6e4f28378a0f730f5e7a45bfbffb17c4bb702f9870cd3b80f93e42faa877ee1872d72899b3f96938"
    ["0.46.1/amd64"]="08f5f611ad73dbe003a2c49243907d3d9f9ec496fece8944b7c508307e3495ac645a857e4a84225028379aace7555654181895554ac55d2b239e23f94155209e"
    ["0.46.1/arm64"]="acfe631c2f792b4f14a805166fb2b55520dedbd25eac245b6ad0853823948e3b9dfcb44113f5e81fb412dfbfb6309dce2218a3233a882b75a08003f9d9dce5ce"
    ["0.46.0/amd64"]="b8bf8e0f53979c1e50cda75607739626098c6477b57d2587b70f947cd632ba4fad4959d425d2497d3b59504d9a6c307eb6523c24978d128899a3552adb47436c"
    ["0.46.0/arm64"]="5c5f4179c4b319cdcf49277decac5d271d4c7385d826f679f9261c5983193c1fdb405a6ae2ef6ffe80860c8cb4a51eeda1dcf21fd73a0d75b0b3028a9f346671"
    ["0.45.1/amd64"]="2db2c3cefa73c0eb9ca5102ee9db21356d2e29553de9952f086f12d73e9a47e1addd4c067f1ffe2c7a851582e60cdcc44bc24509998ba768a508bd94471410fb"
    ["0.45.1/arm64"]="77dc127b6899ab069d94a5682ca83021bd0c10d8f80152f146e14ac5d2cb5cd91932775a2e97b818e383ad5911b5cb458d02db77e199f3e1e4ec16fcd7c58fc8"
    ["0.45.0/amd64"]="a647066af27039ae5d3fc4e2dd00a1cc93a86f14e633186810d07c612990e0bbabea631c9b98b08d69ab009f0cc5b10262ded1badac5efd80c907bb5793dd397"
    ["0.45.0/arm64"]="ec3ee3d4cea41f9dbc32c01e69b33d51dffbe7cf170ecaf83dd4f5c7ae4f9b688d2f6f2d7a3bec544adcacaf302347aa883990c6ec08958f12aec64f15fdd948"
    ["0.44.1/amd64"]="9d36bfb760773386d236ca5b93a5821d4f3b5af1edebf9d61de3e76dcfb5a8b34741cf688590cc1c3cb9c01b2d85676ffdcd1e11a086723ca21e2679fd3119c3"
    ["0.44.1/arm64"]="383a3d1eae03e68201797b5ce514538b5586cb40656dd96ee7c3dc473029b7abd35f2d2f567b7218a235387bb8c246bad32a639d987fe0ca4cd7d237ef16f55b"
    ["0.44.0/amd64"]="3902a38f9590338822d2d7b559a88fedc99f6def076cdb8da01ced4059f6c61855f7cfea25d837f386b309bd759961d27f3ddb67aa49d5f01a637d1d9c12e237"
    ["0.44.0/arm64"]="0524adc27ea30a22bd443adf51b9f6aedee1218028fada91fd38644fddc2c2098303f925bcd73d6b0c059f26203b5e61323557753d80ab6a48038f49312aeb0a"
    ["0.43.2/amd64"]="327081a6add245800e719236535bb127811946041123d4ebe281dbc043833b49bacb232e2544f8323dfdbe04c40634277c2f9f30ce38c043c847871c877af615"
    ["0.43.2/arm64"]="bf4cca9b766b49744b87aabed7c8c61924848f8c81e404b109362fa84d4095a1b2cc3099eaba5754bff3f83f9cd671474a4ef3b52d44ebced65003f6c63e06cd"
    # Version 0.43.1 was not released correctly.
    ["0.43.0/amd64"]="0b153a570c10a7bfed3455d4414b8da3fd967a00ad6a4449a8f34a1b4a8341dc79b1e8a0e466cdba68c28a05545104f1979f6b784266ff2f0db87c4e945eb409"
    ["0.43.0/arm64"]="74bee468e80094ccc938fe18ff50b07dfde7d66e724514ceb9a46029f844efd7b021493092a9b698a5c071013222fe20df0b075b9926a884d496c29b1f5fff03"
    ["0.42.4/amd64"]="2d95048432162f0fd947447c2ddb5c7f70e7150c38b554bb8c1ccaaec5dd94192b3412649f5e0a3c55c7d9186047a6ceb5767a6e8c5ea0492eaba0dbb3773ada"
    ["0.42.4/arm64"]="34462518a5c4bd52a0e6d6baa9318fc1169cc35dbb903210b64719f7684f9dee981fe2595bb42dc2bc73bffefa8755ea7294162db18952a0d83a6e5df9cd7b2e"
    ["0.42.3/amd64"]="b691da0034807cff41122ff935290447f8a097e4d7e26679debbf77569ccd2ffc99592acf3c4fe7109f4b1fe446d56b2bba4293bcd00587fb3e5bc3eb9846f4b"
    ["0.42.3/arm64"]="ab00dd6f4cd14004e8498428d56ce95ca00a3c7ad37cbc1ef5f7d5324b84f2e08e03fdca99848d9d86ca081b0c8d61d8cc75c20031f71841054d52c8742d48fa"
    ["0.42.2/amd64"]="44a16340eecbbfff6b3f13bcabfb5c4d47842bf44f2e17477a10f93aebfc9863bd4837acaa06b2668f4360aa6d3c94a7be6dd9e2a311ee997f8eaf30d59c4fed"
    ["0.42.2/arm64"]="a9289d9833475e51dd1ff1feb8ed8455369790a234e63c825558c0eb3d9e4afb24564932e0f1165606563f7705897a3dc05ae143c3269088b19d197bbb6eaa4a"
    ["0.42.1/amd64"]="01cf1c8eb14744f7cd67cda938236043cad0216e0095edb8474f636d6afae8541114b7ad7f69cb050c8df12c07c81e00b20ca349e16537f9b810433fc939239e"
    ["0.42.1/arm64"]="03100f857cdd1d8cf9bd8c81ac2b0fcf23aa94cc1d8a1e3254a85540f7152c1015d5607ecc3a97c8f901abbf1adb4f9417ed838ea0ff0ebc8778c8c4a4d50797"
    ["0.42.0/amd64"]="322026255159df81ecdd99a1cf895393a1c534c07dc028d0a612dcc0ad088fb8fb0ff840972bdb2fb89800967e8dc5d290c38c6871942c78625a1b5ae8ca4029"
    ["0.42.0/arm64"]="0f7ad20c1481982c02c291c6303f7ddad8369739de285250045ac2b16b06e1c66a8c1abf77cbea5af486a98b69e39d5ac0e4b6ce02f75ce2703f32a62ac5fd8f"
    ["0.41.6/amd64"]="eecf811c084003867c9bfb1f01463ff1ccf48d01b510bed8f80b5f0d1f5bf06e35332c6ed5e28bc352fda971b62b2f0cc044492371233ef5f7eaac959e01e5bb"
    ["0.41.6/arm64"]="a9511580f03505e55564d07cdae69c0e8a84778995ef61ca7019eb6e76935b0264cbc1000cd83a8eb56dd19478ab75e2bf8254d917f6587acc26f6845a60e114"
    ["0.41.5/amd64"]="5d499735778b777b4a464631e1f3b555fa2f39d76b9f9b6c0feef49b3609df5dc50a9779fae12fedc13b63bea1a0341b3c9c2a69e803a094f05b897e1137dca8"
    ["0.41.5/arm64"]="050b4a4423a1ec377e00422535c6c86659fe5cdb4345af2389bc3a85f2e046d51d8af43c3e2b6eea00e4706ba974fdfec667fa5d23296045a97970d8908dd169"
    ["0.41.4/amd64"]="29f06325ce9bcf810d9d999ecb985fc07ece8d196ab440e0c8e8c5cd610bd90e8f1dc007e55f20062395f274e11b004e030088a8c2ac516a71eb30e538298ca4"
    ["0.41.4/arm64"]="56d36a2c1e895124a97ace3032e4a5d5ad9f071804dca17bcf84dfa7644f289722b1976acdc4deeaa35aa27a8ffe3f2bdc1c474e7a9c864c1580a6ad288a94d6"
    # Versions 0.43.2 and 0.43.3 were not released correctly.
    ["0.41.1/amd64"]="fe578bc9a27fc16d6c5f9788cd82b8200ef905e2a70daa0ebdea9e466aba833ed24acba7690f94314f11e39bb51e20b5072f68302a0743e1c7ce08691e4f9483"
    ["0.41.1/arm64"]="83cbe99c6b3438ee8a934c11b88077b889816a53507dcf6ed9e7ca984a6aa8344e2e33362d94178e9785b74572005c49f9aafbad256a935bc1d54969332cdf3c"
    ["0.41.0/amd64"]="a962f85a6b164c4f91ba7acec2bd27b9d306a93d7621cb95ab5d222b5be588bdbf80503808208e3533196d00a6d4d83b0b75d5f4dcd323dec51e10ba406d00cf"
    ["0.41.0/arm64"]="12334b930f8e6fc898d0f04c1d77a159538941a2984a976d5df9f5d3ffd2c4a991cb560e45ee9d7303056fc6fc8e868ebb86e096721b91d69dd87fd154963ac9"
    ["0.40.1/amd64"]="6a638da02e5e3a349b48a373b22a392077b1cd5a2aa562af4b0b0816dbeb25df2a6702031b496494669bd90a15da8d59e2dea61aaf52fcdd899dc3b5efe6619c"
    ["0.40.1/arm64"]="748e9765b6239685251405700dd06ab0a8294c972b9d5a069a12a5f29b707378e2c82cc1ee37f8bf7191f1a7c8074e1aa1ea3561849646fb04f04cf7b2228a67"
    ["0.40.0/amd64"]="b671e0c08de917795e8e939f5242d5a155fc01a13a0ea976a7a0242f222fbe5cee41a1a0cdf06d497974f7816ee6b4247bae6b45db03c46927074955717bc8ac"
    ["0.40.0/arm64"]="11ffd0a9696eedf6bc5c207a8f409492ad718f04b6e57c05b8546ed69488bce45ce30087a90445034f5db9e0ab3a571997c07334d0d8bcbcc69e58707bc28265"
    ["0.39.3/amd64"]="d1b90bd25fab4a2500bb37e81e44abd8e55d7cad21d926faa9b5c633a89c16b619a9fb293f23814addc8864c765767db5b2095dc64971083338277afb42f432c"
    ["0.39.3/arm64"]="15c828fbf802a4d0b3d3975eb234d31cff3a228902b0a7b6e18b1cd766492574b355a03e1f97db7d1eae09adc75e750b310bc272e2879fe92ccb17c3638c1214"
    # Versions 0.38.1 and 0.38.2 were not released correctly.
    ["0.38.0/amd64"]="895d788eb53850913df49bd4da18497a6fcf279a87626e4ad5447823d0bf4c8c255b929319b9b217fd91230e67e4f9ff0a5da682c3854cde011336b98e670bc9"
    ["0.38.0/arm64"]="bb1c5d8e714a6116b8f41ba37c0ca2c6f08296d5cff8925ed8526fd69905ff92017d7f527dd47e90815b2a7256d6155ba74d89d93272d169924da0f5346c2f7d"
    ["0.37.10/amd64"]="5e5fa74c2fd0a5f4fb078674c1d9dadca6d0cda4f17129fffc6ecf8e42614fe69ce7f1a46c1b0c63bee337f3c944e250b6bee191604504e891a1c308d8f9e35d"
    ["0.37.10/arm64"]="db0a7edd9d7bb60614b61d6339dc2a8a1dbce34250e757bf1055f06dbf6c657541789ceb78ef37da7a19f1180dd53c297f8962eda4666d03882f98aeaed9f6d9"
    # Versions 0.37.0 through 0.37.9 were not released correctly.
    ["0.36.0/amd64"]="7ccc4df6fe04f1c5f57acbc054c358911e7e4fc55a1b72bb057a982206f492a5dbb32201e3314b5c90b0466e9c2da3509b342b799f91174e0ad9bf95d446fddb"
    ["0.36.0/arm64"]="96a91b4251a695f678b2f60d4104bd83f3cf8b0ecbae42d707607c407b573bd45a5bf47fbebc461b1f10608698ee64dd89335b47405d9601bad59c9c8aa9c4a6"
    ["0.35.1/amd64"]="8e55ee6d953346b507e0a60966c8008b7c8fcb329ac8fceecb965f55d7b0e05622ad4bba2a2aaaaac7c2e4a004b94749c1c9ab136182a6038ff601150a723e6e"
    ["0.35.1/arm64"]="18d94c8be02c739bf3e727430ac4d0be839bc40be7222c3b510ccd24a214b848e60baf85ad9798b28e11abdcfb720619a7db20b15fcf0e3d3c3775a0e7df5e43"
    ["0.35.0/amd64"]="d15abd920615d8534e426ecc29908a7d8c637a40e87d74c83bd72f279d0f2754336e81ada970b06177bca9be7661513f09b542f1fa487e24ff4aa29c621eb899"
    ["0.35.0/arm64"]="46ea6e69835fad84a7bf55b4b29997438cfb23ee15c603aa1db0a1d6cb6aa0d12b59b962e57d9f30fb851b5e4ccf21da20f52d89faf54de74cd1c3e0fca0a166"
    ["0.34.0/amd64"]="d4815a8ff3cc6718fc3f8e21fc25399471787a505c78c1e8711f16cb8d8defdc4437564561d6b1f707a5d1c86ee0d5358d22b880bc11ef528da38f1a495d06b1"
    ["0.34.0/arm64"]="910089564d2e6b0162118e5bc83223c97f5470374862bd225caa06a3c18e4036d443bc4d174d5827a6cd4aeaf8cf3b44ca8c96b581bb237103a24c967fcc273a"
    ["0.33.0/amd64"]="0bb84332b78068be74506d478bdf654e6f21a307a675170fc24dfb380aeca7ddda54de4d6a6ec17beede0f01c4e9bfceab83a2b42b4d8f1c73a58c7292635756"
    ["0.33.0/arm64"]="6f6958da2fd8593fec2656bc4bc9166718f714522d7e82a5c9ebcb3a13118a434e04e267415af7f343d7068f5910b4d7e322d96525a1faef8bb76c536ba2cf35"
    ["0.32.2/amd64"]="6913d0c0342f0de8025b876471d9c63942392f24fedc93c1d4f3f87c5049cf79545353dcabd151de634a83801bebce6cc21fb31100c675ac9a5ac27a482c2e79"
    ["0.32.2/arm64"]="7ab662006eefb162c37502a7f96d370113bd4cbd3a95ef0769ccf79f0089a030545976ccdfecde92e38d7767c71d72f4eae11d32278f3ee3a7e28da3026e2b8e"
    ["0.32.1/amd64"]="ac4ac41c330e40675e3b8f72cac7f854147184214304e017a9a4891328d38a444b6d39aac9a0a16f570a7abb25c674770b475ea2a6341202ec3c528fe0a3a022"
    ["0.32.1/arm64"]="94da356cee9ca97ef26f307d9d2d8f092e386cf7e7537d998d676f0abac74e287d34ff590a641296930492c398abcb3de0b29ae305c5a401b7809e849bd34823"
    ["0.32.0/amd64"]="697f208b6a6b552218d7d171f6d94d63cb80eff95262d2c037d900f0234e21401a426fef599dbb1d99ca291353f95ac1775e8d3d934463cd1c12067ffbdd9b73"
    ["0.32.0/arm64"]="a2bef6e24d841b970735acabe145cc8ae71508f4e304465581f2ba8fc629e555a63fb58ef82f25958f2bcfa40303c35b365cdf2f34a1bbb232797725934977f5"
    ["0.31.0/amd64"]="9f972f350ced01298ed5b0f83bbb0f010a75d8bcc5ed5b90dd859fe34c024697c00b81c63f409f7f5a1277555f715a2526e25a72738b352beebccb589d4285c3"
    ["0.31.0/arm64"]="a17ad9363ee0b9d57099d10de65b1b54c5376ea92c125a8d567328059ad26a169b1336f058a3b2f478b88af87dab9a313f041c253a0095d74c710d7d0894cb91"
    ["0.30.1/amd64"]="de7f1a885955e310e73a5c15066b793434f46787b0a0dd7eae91d7fec4d2ea19ebe2abd008d1c5708648a1d4d78153ddf8639b3bea8965503372482c01e983cc"
    ["0.30.1/arm64"]="d1d58c4aa85b030b870e6d6f9c5f0a78f12e7d6edef2976e367c3f1c9c873d0a5ece1678d5a473ba1b7293cef8c7c061adf9de283268c72d4788f0713de522b4"
    # Version 0.30.0 was not released correctly.
    ["0.29.0/amd64"]="7d50f36b6ecbd870b73c48ff8cbfc6b2f96e577fa1b06ce3d7dc145b2fbda5e87313fb34c0e5c7596c20e4c1144f7064d730175e0c87b3e8d85faa0d2ca5b983"
    ["0.29.0/arm64"]="f850a37fea6774c2b9693f7491ea2a6a779d8abff38d9002e36394680c87430f91c2cf37919f08e27d82c451114c65ae528f21110de93e004ddabc63ae5ebacb"
    ["0.28.0/amd64"]="13132394dfff163a32d8159313ef8b9281be0cd00980f89525ab62ec661e716a215397a5800e0c07abc8d3d67b1570312b9ca19d49997c4da4801263e4e1f2d2"
    ["0.28.0/arm64"]="523122bde331678176d2d63df55a26b2132069d0ae724bfd0d41d94f9708babdb510f2df845343145b053f135cf71159e91550b2021cda03b1c40dec3562888a"
    ["0.27.0/amd64"]="152062f5d3c9dbeffe78c89a0cc95a41b6aee270b871e0ec88f9b85f30cbfad53168cf5b7cab722b37a716c19880c9f670c537078d03cc3d231ad8ff0c79ed41"
    ["0.26.0/amd64"]="a21be2972af09fcfc10a7fda4415f0d2513f3c2f88a3b5565f50926a40621339566034c201e6eaaf6fbd952300b0de01a6b88f85bfd2160a4965851377d773e7"
    ["0.25.0/amd64"]="2ff0a3fe32dffd7a049f346e00572b1312083e79199d8eaf96a0a75cc27d9cb53e68def30dc149298f5133a51cd0530274e1f56bbd796e1100f65c34d89be432"
    ["0.24.1/amd64"]="af79d27c358281a885e36c669b510a800d07d8ef5570adb9d873071a50eb99c1b2d6514280db1b922277e4d8d0c2204ca88069e811eb20bd52ed26b4d3d55700"
    ["0.24.0/amd64"]="1cbbbb3e8f810ec8ddc21b78abfbe3773029b3a1a70676c859960d35e2419d500c278da0b8a16bbd03b3f2751dc1c65bd96f9364b9365f67629a3b62cd6f7eae"
    ["0.23.0/amd64"]="b69bfa7088cbc97db46cbd9c0cbe6ca6661ba34a7187cda8d0d29ef7f7efbebc93575c037a9d76fd3a5bc789db51a52c6ff749e95de9464df66789e540843c4f"
    # Version 0.22.0 was not released correctly.
    ["0.21.0/amd64"]="6f04e03c48f8e957f0a3a5dbcbb5c15d5617c5dde2a0f5942710d9c3c18366decc01e919376084d652d0c48288fa6383a9cd948724226d55c846d45838c19a19"
    ["0.20.0/amd64"]="6c5345c03833d6c9d0336b694fb10072b65f5c36d8498a690112b0445a69eac7869d6e215d739f2753c8295519ac8a2d66223752e65a7dba0a3dd6fbded6ba9d"
    ["0.19.1/amd64"]="e3fb0e1f38acc6973a56c6e4a1fe9403474d7a82db3df9e78bc5286eb483ad7c483bbcccdb47b8d731a92429758976e80e5ab20803374a730b674dac360e13fc"
    ["0.19.0/amd64"]="5460540c917e9f3b4449527f90fce52d54e51df11ee1088a54589ec3797490cf96a227858084500d5e76f6b432ced6fc8129af851c296b0bcd04c32acf84cdd3"
    ["0.18.0/amd64"]="d629012aeb2028de479fab8724e94d6e8d53fc549e1d76f956a873fad1f58b54b9f050cba9a62ad8a08964b96901e321d9959f2b8fb8e2f60e048a117daa9e97"
    ["0.17.1/amd64"]="00f996e20eb9033edbe8ffc19792753e05b5a0f16ef8e70c43c1a5cad1cb575bdd7c44788c936d9f5b3d34d4221d822d97672dc1af4e57bb1b0dec39b29b8d2d"
    ["0.17.0/amd64"]="50c2c3f7ad0a620d4801747595c3cac27de64a5057ec1fe4632a50633d11c31e244a7281e9a57f60e5c092487e1bd47e3660728071d7a07c017c96815b926fcf"
    ["0.16.1/amd64"]="4e1e17a41ef1fab3d66b4b6f2ee49fd140f530b2fa7860d82248985cc3be226a2aa28aa06d24e46f7528153544ea3f618db081eb5e3f07f95a40322f25d178ec"
    # Version 0.16.0 was not released correctly.
    ["0.15.2/amd64"]="f1c43ea254ce7950bef0deeaa6f59a57fb4e1dd3760f7c5a96596fb2f3cd7d5124ea16ff0bcb7e68673ba9f2654e8d9cef1b4753648d0091e73a0bdffcd0c62e"
    ["0.15.1/amd64"]="de19ce2669e5ae2939d602d5256543a7ab3aa223b0b7f8ec9c78260715015c1fcb499c9a5f8d5a3b1c1d66d8766e5777932deab7c2d50172a8370b2badfe10cd"
    # Version 0.15.0 was not released correctly.
    ["0.14.0/amd64"]="1cd2f920a43ae740176e1505c7a3cf15ccc68f0f0678ab9562603ac491640f021e25ea3bc987dc22ebff9e8a764efffec6858cd4a032e1bf69952f9622dbe1f3"
    ["0.13.1/amd64"]="b48b7280c2f089b129c47649631de1fe9278a10930c5ae13730d232937a2e297ca0fd3191a5e3f40eed94088fc8ed950e61bbf9b55bf24f1751563aeb9ff9a1b"
    ["0.13.0/amd64"]="90402a4907042281fee8b7a10f58c58846a7b03b4a5fe2e768f6a6ed434544fb4276def294fe40c3a1bfa0a5393837aa70cd4ac3b12f03be5207447ac055f103"
    ["0.12.7/amd64"]="e61aa979b671de4078b34dc52ff0bd42a8bf878a5d356c82dd5b1d3c8c72317dd149b9adef53bc972175d231865775fc5d0798f524e766dc7b5a0e6fa8a15f60"
    ["0.12.6/amd64"]="13f8f765d0b6d9f5f3ec3b62e140a63f55df62f2f25ee350f583f25ea6fdae3001806d1d4f20a321f69cc2b131dd8596e02bdc529d84c0c0141400823d52f890"
    ["0.12.5/amd64"]="25ee8f269825a2202645959f17bae88cd78301da74d140acd5156efd51ed2ec7faad9e4ae25e3060e24fde9ab231b617688ebd8b8f813e60f310748f4b2c7d88"
    ["0.12.4/amd64"]="08f816d552cff9925e766aba3ba9bd28f77b01ad340bffe41d75e42137e7ce32ca317f2e621c050fa649086ff053ad6da62a5c6d3294436f62de67120bcb0016"
    ["0.12.3/amd64"]="5c2b3e80072e2afef9cef80ffba8677c2b6146ade23033448c001ae0bc2f36b4c28775ba78403cea5154ea07855da70240fe4471995b5d038ca0076834186655"
    ["0.12.2/amd64"]="34e55b8248ac6d81562dfb652c1f40a4796705cadff9e5c022c7f025016457b3727a6d6a3b07c18e3a0ad5a1ffcd08a51aa7960ddee07c3c12d6059c356823ce"
    ["0.12.1/amd64"]="2e5e4554f31648404f6a63c866835763b4aa5e07cb301b85619100d99b4dd66a8c00564469a95ba225daa206190fe9b04e929bea93a0e4425837dd793548feeb"
    ["0.12.0/amd64"]="7f4238bcc6e3368156d0cc197cce98dfaafa903c712437c5b62b2be0a62648c310e44f54f54a5ceda0f4feb66b55254ee7f70e3f025541acd7a09ea752946159"
    ["0.11.1/amd64"]="4d5eb7f2de3d5d67178ba0680c17f411f1fc490ec3a33b7950c620168e84d605c9c56ea20e85ad59de4bd8b24897b41f4e5129922b484c206e92c12ae490c30a"
    ["0.11.0/amd64"]="b14c2f9a5a7927134b30bfed56f53327c223c789059a9f4363ec084d2d34972baec43eb5abe4f37ca7dc796a0841f30a21e5b3e16a25e11f2d8eea2ce47b9a26"
    ["0.10.0/amd64"]="fe759b90008cd9b70327cd9480365f10ad1e873cf7ede94f98f3593c09a16102cca74f3a29b60a035b14e6be1d9c6951f6e78b7df6b455845a263f62ac1d1831"
    ["0.9.2/amd64"]="d1630be5ef0f9a4ec9eea6e2758569f6f249781fb0afcba6673574767fcccfb4103df7e7fbf8901ddb7768c097340011e4ee157687c9506e557768b203419124"
    ["0.9.1/amd64"]="fd42b46c6797899c13a8b36c0af2f27c92ae9cae2eabec034901033c75b548933e06ed252ec5e2acf3026af1a762dee4ec75e06a4de4eeede671a56d1ef418e5"
    ["0.9.0/amd64"]="5d3eed441794c978206e5709340538667af1348f9e09d3a114cdb00a0f96b504bea51d32c0631aa6f679719d11df3789068ee02c68df287a886748737d172513"
    ["0.8.0/amd64"]="16706a73dc76c7c3fba2a4e86b4ac5001c9349e5d375ddaa8780944eb5276a92696f84966d2a12a258003cccb175971ea9ada11dfde3a2ee378baeab8a50cf3c"
    ["0.7.1/amd64"]="1ac22316f963c881f1629cb62e49d6e7baeac84a49c378d01442cc8f21116ade1b46f5cf7bf18d7908e85b59bdd3e55486e6932a72dcb5f13970afa75643c119"
    ["0.7.0/amd64"]="2e407eb220bd76c6f70eda040d0ec081ca44fa64abe13a71a9689a04328c96adf58a8cd22d97e9c34574d523e88de90c563c641b2835abb641e8079e84539b86"
    ["0.6.0/amd64"]="0d36a8370e36b00ce96a1b938038b5000b79301515152c52e40ad46e881ce8606812f11ec58e03d73a8d358b7957004cb664005bbc9c4baece343db34e10d467"
    ["0.5.1/amd64"]="cdea5fcf1747b22337722cbacbaa3723c0a98952f65210a48901706edd5243c779dcb49635d25fb89ee6f99926531a060c00982387936f36b8cfffb96de919cf"
    ["0.5.0/amd64"]="ee42c7c227e7711b017d0a1213518a6eb546bc0af99d9570fee5134980866c55e9c0020835c6e8df59e7e78f8221fa0161f4c8fb90892ebf8ca0371c48d7313f"
    ["0.4.1/amd64"]="a97cad37b59fe46755cbf0172edbb939a8e59f805a06c287202072925369fa5885daf7cd39ba38d5de0dde6fd45c66cc99ab11ce52d77935562effa82568c078"
    ["0.4.0/amd64"]="a448b227ee3086922df990dc4e79d7d159f2f8ace6c15045f7bc345f3a64a630d05bc40c65adf9b21164b965acfc7eab59bb5a602530ba3a4d383a47a18a4d63"
    ["0.3.0/amd64"]="bfaf57a31bb31cd120c4e8ec80df553d2213049760c9b8a9bc2c1295f968040112c8e53f4494ff3f9769dece1e573161669fef37351457106e616add321ec8dc"
    ["0.2.0/amd64"]="66e502ac2001a6cac8a06dc240cafc0ad2c6e66fcbc402d486b02096a0e71918b4d9db5142e2cb37befda29713348029fc052982dc0ea36a6e46e65bf9927778"
    ["0.1.0/amd64"]="a0dc4bcc9c2ebe8e446e4e70b5cc6afd3bec51f6f785aba1ffd94eace5bd20166af6e82845a9d48b0a36f7bdc31203930e931368f2e0b2fdb0a991d9ab25386d"
)
# <<< checksum table <<<

orb_install_main
