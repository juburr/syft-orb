#!/usr/bin/env bash
#
# Runs src/scripts/generate_sbom.sh with stub syft and circleci commands on
# the paths where it expands an empty array, and checks that it succeeds and
# passes syft exactly the expected arguments. It also runs it without the
# CircleCI CLI, as on GitHub Actions, checks the enrich and scope values it
# accepts and refuses, and scans a small DEB with a relative TMPDIR (see
# check_deb_relative_tmpdir).
#
# generate_sbom.sh runs under set -u, and bash before 4.4 treats an empty
# array as unset there: a plain "${a[@]}" of an empty array aborts the script
# with "unbound variable". The orb supports bash 4.0 and later, so such arrays
# are expanded as ${a[@]+"${a[@]}"}. A directory scan without an exclude
# parameter has an empty EXCLUDE_PATTERNS, and so does an exclude of only
# separators. On any bash this test checks that neither adds an argument (a
# fix like "${a[@]:-}" would pass syft an empty one); with bash 4.3 or older
# first on the PATH, it also catches the abort.
#
# Run from a checkout:
#   bash <this file>

set -euo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done

WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/project"
# The stub syft records its arguments, one per line.
# It exits with SYFT_EXIT, 0 by default.
cat > "${WORK}/bin/syft" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${WORK}/syft.args"
exit "\${SYFT_EXIT:-0}"
EOF
printf '#!/usr/bin/env bash\ncat\n' > "${WORK}/bin/circleci"
chmod +x "${WORK}/bin/syft" "${WORK}/bin/circleci"

FAILURES=0

# check NAME EXCLUDE: scans dir:./project with the given exclude and every
# other optional parameter empty, as the command's defaults leave them.
check() {
    local name=$1 exclude=$2 rc=0
    rm -f "${WORK}/syft.args"
    (
        cd "${WORK}"
        PATH="${WORK}/bin:${PATH}" PARAM_BASE_PATH="" PARAM_CONFIG="" PARAM_ENRICH=all \
            PARAM_EXCLUDE="${exclude}" PARAM_SOURCE=dir:./project PARAM_OUTPUT_DIR="" \
            PARAM_OUTPUT_FORMATS=spdx-json PARAM_SCOPE=squashed PARAM_SELECT_CATALOGERS="" \
            bash "${ROOT}/src/scripts/generate_sbom.sh"
    ) > "${WORK}/output.txt" 2>&1 || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        echo "FAIL: ${name}: generate_sbom.sh exited ${rc}:"
        sed 's/^/  /' "${WORK}/output.txt"
        FAILURES=$((FAILURES + 1))
    elif ! printf '%s\n' scan -vv --scope squashed --base-path / \
        -o "spdx-json=${WORK}/sboms/project.spdx.json" --enrich all dir:./project |
        diff - "${WORK}/syft.args" > "${WORK}/diff.txt"; then
        echo "FAIL: ${name}: syft got other arguments (< wanted, > got):"
        sed 's/^/  /' "${WORK}/diff.txt"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok: ${name}"
    fi
}

check "a directory scan without exclude, config or select_catalogers" ""
check "an exclude of only separators adds no --exclude" ", ,"

# A PATH without circleci, as on a GitHub Actions runner: the stub syft, then
# links to every other command on the PATH. CircleCI's executors have the real
# CLI in a system directory, so dropping the stub's directory isn't enough.
mkdir -p "${WORK}/syft-only" "${WORK}/nocli"
ln -s "${WORK}/bin/syft" "${WORK}/syft-only/syft"
IFS=: read -r -a PATH_DIRS <<< "${PATH}"
for dir in "${PATH_DIRS[@]}"; do
    for tool in "${dir}"/*; do
        name=$(basename "${tool}")
        if [[ "${name}" != circleci && -x "${tool}" && ! -d "${tool}" && ! -e "${WORK}/nocli/${name}" ]]; then
            ln -s "${tool}" "${WORK}/nocli/${name}"
        fi
    done
done
NO_CLI_PATH="${WORK}/syft-only:${WORK}/nocli"
if PATH="${NO_CLI_PATH}" command -v circleci > /dev/null 2>&1; then
    echo "FAIL: the PATH for the no-CLI checks still has a circleci"
    FAILURES=$((FAILURES + 1))
else
    echo "ok: the PATH for the no-CLI checks has no circleci"
fi

# gen PATH NAME=VALUE...: runs generate_sbom.sh on dir:./project with the
# command's defaults, overridden by each NAME=VALUE, and sets RC.
gen() {
    local path=$1
    shift
    rm -f "${WORK}/syft.args"
    RC=0
    (
        cd "${WORK}"
        export PARAM_BASE_PATH="" PARAM_CONFIG="" PARAM_ENRICH=all PARAM_EXCLUDE="" PARAM_SOURCE=dir:./project \
            PARAM_OUTPUT_DIR="" PARAM_OUTPUT_FORMATS=spdx-json PARAM_SCOPE=squashed PARAM_SELECT_CATALOGERS=""
        for setting in "$@"; do
            export "${setting?}"
        done
        PATH="${path}" bash "${ROOT}/src/scripts/generate_sbom.sh"
    ) > "${WORK}/output.txt" 2>&1 || RC=$?
}

# expect_args NAME WANTED...: syft ran with exactly these arguments.
expect_args() {
    local name=$1
    shift
    if [[ ${RC} -ne 0 ]]; then
        echo "FAIL: ${name}: generate_sbom.sh exited ${RC}:"
        sed 's/^/  /' "${WORK}/output.txt"
        FAILURES=$((FAILURES + 1))
    elif ! printf '%s\n' "$@" | diff - "${WORK}/syft.args" > "${WORK}/diff.txt"; then
        echo "FAIL: ${name}: syft got other arguments (< wanted, > got):"
        sed 's/^/  /' "${WORK}/diff.txt"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok: ${name}"
    fi
}

# expect_refused NAME MESSAGE: the script failed with MESSAGE before running syft.
expect_refused() {
    local name=$1 message=$2
    if [[ ${RC} -eq 0 || -e "${WORK}/syft.args" ]] || ! grep -qF -- "${message}" "${WORK}/output.txt"; then
        echo "FAIL: ${name}: wanted a failure saying '${message}' before syft ran (exit ${RC}):"
        sed 's/^/  /' "${WORK}/output.txt"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok: ${name}"
    fi
}

# Without the CLI, values are used as they are: nothing is expanded.
# shellcheck disable=SC2016 # literal $NAME on purpose
NAME=expanded gen "${NO_CLI_PATH}" 'PARAM_OUTPUT_DIR=out-$NAME' PARAM_SCOPE=all-layers
# shellcheck disable=SC2016
expect_args "without the CircleCI CLI, a \$NAME in a value stays as it is" \
    scan -vv --scope all-layers --base-path / -o "spdx-json=${WORK}/out-\$NAME/project.spdx.json" --enrich all dir:./project

# yaml_enum PARAMETER: the values of an enum parameter of the generate_sbom command.
yaml_enum() {
    awk -v key="$1" '
        $0 ~ "^  " key ":$" { found = 1; next }
        found && /^  [a-z_]+:$/ { exit }
        found && /^    enum:/ { gsub(/^    enum:[[:space:]]*\[|\]$|"|[[:space:]]/, ""); gsub(/,/, "\n"); print; exit }
    ' "${ROOT}/src/commands/generate_sbom.yml"
}

# The script checks enum values itself, since a GitHub Action's inputs are
# plain strings. Every value the command allows must pass.
ENRICH_VALUES=$(yaml_enum enrich)
SCOPE_VALUES=$(yaml_enum scope)
if [[ $(wc -l <<< "${ENRICH_VALUES}") -lt 7 || $(wc -l <<< "${SCOPE_VALUES}") -lt 3 ]]; then
    echo "FAIL: could not read the enrich and scope enums from src/commands/generate_sbom.yml"
    FAILURES=$((FAILURES + 1))
fi
while IFS= read -r value; do
    gen "${NO_CLI_PATH}" "PARAM_ENRICH=${value}"
    expect_args "enrich ${value} is accepted" \
        scan -vv --scope squashed --base-path / -o "spdx-json=${WORK}/sboms/project.spdx.json" --enrich "${value}" dir:./project
done <<< "${ENRICH_VALUES}"
while IFS= read -r value; do
    gen "${NO_CLI_PATH}" "PARAM_SCOPE=${value}"
    expect_args "scope ${value} is accepted" \
        scan -vv --scope "${value}" --base-path / -o "spdx-json=${WORK}/sboms/project.spdx.json" --enrich all dir:./project
done <<< "${SCOPE_VALUES}"

gen "${NO_CLI_PATH}" PARAM_ENRICH=everything
expect_refused "an unknown enrich value is refused" "ERROR: enrich must be one of"
gen "${NO_CLI_PATH}" PARAM_ENRICH=
expect_refused "an empty enrich value is refused" "ERROR: enrich must be one of"
gen "${NO_CLI_PATH}" PARAM_SCOPE=layers
expect_refused "an unknown scope value is refused" "ERROR: scope must be one of"

# A DEB scan extracts the package into a mktemp -d directory and cds into it.
# With a relative TMPDIR, mktemp returns a relative path, so the script must
# make it absolute first: otherwise --base-path points below the scratch
# directory, and the EXIT trap can't find the directory to remove it.
mkdir -p "${WORK}/debroot/DEBIAN" "${WORK}/debroot/usr/share/doc/demo"
printf 'Package: demo\nVersion: 1.0\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: test package\n' \
    > "${WORK}/debroot/DEBIAN/control"
echo "demo" > "${WORK}/debroot/usr/share/doc/demo/README"
dpkg-deb --build "${WORK}/debroot" "${WORK}/demo.deb" > /dev/null

# check_deb_relative_tmpdir NAME SYFT_EXIT [CDPATH]: scans demo.deb with
# TMPDIR=scratch, a syft that exits SYFT_EXIT, and CDPATH (none by default).
check_deb_relative_tmpdir() {
    local name=$1 syft_exit=$2 cdpath=${3:-} rc=0 base_path
    rm -rf "${WORK}/syft.args" "${WORK}/scratch"
    mkdir "${WORK}/scratch"
    (
        cd "${WORK}"
        PATH="${WORK}/bin:${PATH}" TMPDIR=scratch CDPATH="${cdpath}" SYFT_EXIT="${syft_exit}" PARAM_BASE_PATH="" \
            PARAM_CONFIG="" PARAM_ENRICH=all PARAM_EXCLUDE="" PARAM_SOURCE=demo.deb PARAM_OUTPUT_DIR="" \
            PARAM_OUTPUT_FORMATS=spdx-json PARAM_SCOPE=squashed PARAM_SELECT_CATALOGERS="" \
            bash "${ROOT}/src/scripts/generate_sbom.sh"
    ) > "${WORK}/output.txt" 2>&1 || rc=$?
    # syft.args is missing when the script failed before running syft.
    base_path=$(sed -n '/^--base-path$/{n;p;}' "${WORK}/syft.args" 2> /dev/null || true)
    if [[ ${rc} -ne ${syft_exit} ]]; then
        echo "FAIL: ${name}: generate_sbom.sh exited ${rc}, wanted ${syft_exit}:"
        sed 's/^/  /' "${WORK}/output.txt"
        FAILURES=$((FAILURES + 1))
    elif [[ "${base_path}" != "${WORK}/scratch/"* ]]; then
        echo "FAIL: ${name}: syft got --base-path '${base_path}', not an absolute path in ${WORK}/scratch"
        FAILURES=$((FAILURES + 1))
    elif [[ -n "$(ls -A "${WORK}/scratch")" ]]; then
        echo "FAIL: ${name}: the scratch directory was left behind: $(ls -A "${WORK}/scratch")"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok: ${name}"
    fi
}

check_deb_relative_tmpdir "a DEB scan with a relative TMPDIR uses and removes an absolute scratch path" 0
check_deb_relative_tmpdir "a failed DEB scan with a relative TMPDIR still removes its scratch directory" 1
# With CDPATH set, cd prints the directory it found, which must not end up in
# the scratch path.
check_deb_relative_tmpdir "a DEB scan with a relative TMPDIR and CDPATH set uses one absolute scratch path" 0 "${WORK}"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All generate_sbom tests passed."
