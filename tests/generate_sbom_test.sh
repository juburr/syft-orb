#!/usr/bin/env bash
#
# Runs src/scripts/generate_sbom.sh with stub syft and circleci commands on
# the paths where it expands an empty array, and checks that it succeeds and
# passes syft exactly the expected arguments. It also scans a small DEB with
# a relative TMPDIR (see check_deb_relative_tmpdir).
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

# A DEB scan extracts the package into a mktemp -d directory and cds into it.
# With a relative TMPDIR, mktemp returns a relative path, so the script must
# make it absolute first: otherwise --base-path points below the scratch
# directory, and the EXIT trap can't find the directory to remove it.
mkdir -p "${WORK}/debroot/DEBIAN" "${WORK}/debroot/usr/share/doc/demo"
printf 'Package: demo\nVersion: 1.0\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: test package\n' \
    > "${WORK}/debroot/DEBIAN/control"
echo "demo" > "${WORK}/debroot/usr/share/doc/demo/README"
dpkg-deb --build "${WORK}/debroot" "${WORK}/demo.deb" > /dev/null

# check_deb_relative_tmpdir NAME SYFT_EXIT: scans demo.deb with TMPDIR=scratch
# and a syft that exits SYFT_EXIT.
check_deb_relative_tmpdir() {
    local name=$1 syft_exit=$2 rc=0 base_path
    rm -rf "${WORK}/syft.args" "${WORK}/scratch"
    mkdir "${WORK}/scratch"
    (
        cd "${WORK}"
        PATH="${WORK}/bin:${PATH}" TMPDIR=scratch SYFT_EXIT="${syft_exit}" PARAM_BASE_PATH="" \
            PARAM_CONFIG="" PARAM_ENRICH=all PARAM_EXCLUDE="" PARAM_SOURCE=demo.deb PARAM_OUTPUT_DIR="" \
            PARAM_OUTPUT_FORMATS=spdx-json PARAM_SCOPE=squashed PARAM_SELECT_CATALOGERS="" \
            bash "${ROOT}/src/scripts/generate_sbom.sh"
    ) > "${WORK}/output.txt" 2>&1 || rc=$?
    base_path=$(sed -n '/^--base-path$/{n;p;}' "${WORK}/syft.args" 2> /dev/null)
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

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All generate_sbom tests passed."
