#!/usr/bin/env bash
#
# Runs src/scripts/log_sbom.sh on a few small files and checks that:
#
#   - pretty takes CircleCI's 1 and 0 and a GitHub Action's true and false,
#     and refuses anything else before logging
#   - without the CircleCI CLI, as on a GitHub Actions runner, sbom_dir and
#     sbom_file are used as they are: a $NAME is not expanded
#   - sbom_dir logs the SBOM files it holds
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
mkdir -p "${WORK}/sboms"
printf '{"spdxVersion":"SPDX-2.3","name":"demo"}\n' > "${WORK}/sboms/demo.spdx.json"
printf 'SPDXVersion: SPDX-2.3\n' > "${WORK}/sboms/demo.spdx"

# A PATH without circleci: links to every other command on the PATH.
# CircleCI's executors have the real CLI in a system directory.
mkdir -p "${WORK}/nocli"
IFS=: read -r -a PATH_DIRS <<< "${PATH}"
for dir in "${PATH_DIRS[@]}"; do
    for tool in "${dir}"/*; do
        name=$(basename "${tool}")
        if [[ "${name}" != circleci && -x "${tool}" && ! -d "${tool}" && ! -e "${WORK}/nocli/${name}" ]]; then
            ln -s "${tool}" "${WORK}/nocli/${name}"
        fi
    done
done
NO_CLI_PATH="${WORK}/nocli"

FAILURES=0

# run PRETTY SBOM_DIR SBOM_FILE: runs log_sbom.sh without the CLI; sets RC.
run() {
    RC=0
    (
        cd "${WORK}"
        PATH="${NO_CLI_PATH}" PARAM_PRETTY="$1" PARAM_SBOM_DIR="$2" PARAM_SBOM_FILE="$3" \
            bash "${ROOT}/src/scripts/log_sbom.sh"
    ) > "${WORK}/out.txt" 2> "${WORK}/err.txt" || RC=$?
}

# expect NAME WANT_RC OUT_OR_ERR TEXT: the script exited WANT_RC (0, or any
# failure for "fail") and its stdout or stderr has the line TEXT.
expect() {
    local name=$1 want=$2 stream=$3 text=$4 problem=""
    if [[ "${want}" == fail && ${RC} -eq 0 ]]; then
        problem="succeeded, wanted a failure"
    elif [[ "${want}" != fail && ${RC} -ne ${want} ]]; then
        problem="exited ${RC}, wanted ${want}"
    elif ! grep -qxF -- "${text}" "${WORK}/${stream}.txt"; then
        problem="${stream} has no line '${text}'"
    fi
    if [[ -n "${problem}" ]]; then
        echo "FAIL: ${name}: ${problem}"
        sed 's/^/  out: /' "${WORK}/out.txt"
        sed 's/^/  err: /' "${WORK}/err.txt"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok: ${name}"
    fi
}

if PATH="${NO_CLI_PATH}" command -v circleci > /dev/null 2>&1; then
    echo "FAIL: the PATH for these checks still has a circleci"
    FAILURES=$((FAILURES + 1))
else
    echo "ok: the PATH for these checks has no circleci"
fi

# jq pretty-prints JSON with two-space indents. Without jq, the file is
# printed as it is, whatever pretty says.
if command -v jq > /dev/null 2>&1; then
    PRETTY_LINE='  "name": "demo"'
else
    echo "skip: no jq, so pretty-printing is not checked"
    PRETTY_LINE='{"spdxVersion":"SPDX-2.3","name":"demo"}'
fi
RAW_LINE='{"spdxVersion":"SPDX-2.3","name":"demo"}'

for value in true 1; do
    run "${value}" "" sboms/demo.spdx.json
    expect "pretty ${value} pretty-prints JSON" 0 out "${PRETTY_LINE}"
done
for value in false 0; do
    run "${value}" "" sboms/demo.spdx.json
    expect "pretty ${value} prints JSON as it is" 0 out "${RAW_LINE}"
done
run yes "" sboms/demo.spdx.json
expect "an unknown pretty value is refused" fail err "ERROR: pretty must be true or false, not 'yes'."
if grep -q demo "${WORK}/out.txt"; then
    echo "FAIL: an unknown pretty value still logged the file"
    FAILURES=$((FAILURES + 1))
fi

# shellcheck disable=SC2016 # literal $NAME on purpose
NAME=sboms run false "" '$NAME/demo.spdx.json'
# shellcheck disable=SC2016
expect "without the CircleCI CLI, a \$NAME in sbom_file stays as it is" 0 err 'WARN: File not found: $NAME/demo.spdx.json'

run true sboms ""
expect "sbom_dir logs every SBOM file in the directory" 0 out "Logged 2 SBOM file(s)"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All log_sbom tests passed."
