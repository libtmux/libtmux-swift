#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
group_wrapper="$script_directory/run-process-group.sh"
matrix_runner="$script_directory/run-tmux-matrix.sh"
lane_declaration="$script_directory/../Fixtures/tmux-matrix.json"
test_spikes_script="$script_directory/test-spikes.sh"

lane_environment_count=0
for key in LIBTMUX_TMUX_BIN LIBTMUX_TMUX_TAG LIBTMUX_MATRIX_ROOT; do
    if [[ -n ${!key:-} ]]; then
        ((lane_environment_count += 1))
    fi
done

if ((lane_environment_count == 0)); then
    if ! direct_lane=$(jq -er '
        if type == "array"
            and length > 0
            and (.[-1] | type == "string" and length > 0)
        then .[-1]
        else empty
        end
    ' "$lane_declaration"); then
        echo "tmux matrix lane declaration is invalid" >&2
        exit 1
    fi
    if bash "$matrix_runner" \
        --lane "$direct_lane" \
        -- \
        bash "$test_spikes_script" "$@"; then
        direct_status=0
    else
        direct_status=$?
    fi
    if ((direct_status != 0)); then
        exit "$direct_status"
    fi
    exit 0
fi

if ((lane_environment_count != 3)) \
    || [[ -z ${LIBTMUX_MATRIX_MANIFEST:-} \
        || -z ${LIBTMUX_MATRIX_BINARY_ROOT:-} ]]; then
    echo "incomplete authenticated tmux lane environment" >&2
    exit 2
fi

spikes_directory=$(cd "$script_directory/.." && pwd)
swift build --package-path "$spikes_directory"
binary_directory=$(swift build --package-path "$spikes_directory" --show-bin-path)
fixture_owner_helper="$binary_directory/fixture-owner-helper"
process_probe="$binary_directory/process-probe"
pty_client_probe="$binary_directory/pty-client-probe"
sigpipe_probe="$binary_directory/sigpipe-probe"
repository_directory=$(cd "$spikes_directory/../.." && pwd)
python_reply_oracle="$repository_directory/docs/superpowers/spikes/evidence/transport/python-reply-oracle.json"
python_reply_generator="$repository_directory/docs/superpowers/spikes/evidence/transport/generate_python_reply_oracle.py"
[[ "$fixture_owner_helper" == /* ]] || {
    echo "fixture-owner-helper path is not absolute" >&2
    exit 1
}
[[ -x "$fixture_owner_helper" ]] || {
    echo "fixture-owner-helper was not built" >&2
    exit 1
}
[[ -x "$process_probe" ]] || {
    echo "process-probe was not built" >&2
    exit 1
}
[[ -x "$pty_client_probe" ]] || {
    echo "pty-client-probe was not built" >&2
    exit 1
}
[[ -x "$sigpipe_probe" ]] || {
    echo "sigpipe-probe was not built" >&2
    exit 1
}
[[ -r "$python_reply_oracle" && -r "$python_reply_generator" ]] || {
    echo "Python reply oracle evidence is unavailable" >&2
    exit 1
}
generated_oracle=$(mktemp)
registry_probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/r.XXXXXX")
registry_probe_output="$registry_probe_directory/output"
registry_probe_cleanup_allowed=1
cleanup() {
    rm -f "$generated_oracle"
    if (( registry_probe_cleanup_allowed == 1 )) \
        && [[ -n $registry_probe_directory ]]; then
        rm -rf -- "$registry_probe_directory"
    fi
}
trap cleanup EXIT
(
    cd "$repository_directory"
    uv run --frozen python "$python_reply_generator"
) >"$generated_oracle"
cmp -s "$generated_oracle" "$python_reply_oracle" || {
    echo "Python reply oracle does not match its generator fingerprint" >&2
    exit 1
}
export LIBTMUX_PROCESS_PROBE="$process_probe"
export LIBTMUX_PTY_CLIENT_PROBE="$pty_client_probe"
export LIBTMUX_SIGPIPE_PROBE="$sigpipe_probe"
export LIBTMUX_FIXTURE_OWNER_HELPER="$fixture_owner_helper"
export LIBTMUX_PYTHON_REPLY_ORACLE="$python_reply_oracle"
unset LIBTMUX_REGISTRY_IDENTITY_PROBE
swift test --package-path "$spikes_directory" "$@"

registry_probe_environment=(
    env -i
    "PATH=$PATH"
    "LC_ALL=C"
    "TMPDIR=$registry_probe_directory"
    "LIBTMUX_REGISTRY_IDENTITY_PROBE=1"
)
for key in DEVELOPER_DIR SDKROOT; do
    if [[ -n ${!key:-} ]]; then
        registry_probe_environment+=("$key=${!key}")
    fi
done

registry_probe_cleanup_allowed=0
set +e
TMPDIR="$registry_probe_directory" bash "$group_wrapper" \
    --bounded \
    --timeout 60 \
    --output "$registry_probe_output" \
    --cwd "$spikes_directory/.." \
    -- \
    "${registry_probe_environment[@]}" \
    swift test \
        --package-path "$spikes_directory" \
        --skip-build \
        --filter FixtureFailureTests/registryRejectsDuplicatePublicCaseIdentity
registry_probe_status=$?
set -e

duplicate_issue_count=$(rg -F -c \
    'Caught error: duplicateCaseIdentity' \
    "$registry_probe_output" || true)
summary_count=$(rg -c \
    'Test run with 1 test in 1 suite failed .* with 1 issue\.$' \
    "$registry_probe_output" || true)
case_summary_count=$(rg -c \
    'with 2 test cases failed .* with 1 issue\.$' \
    "$registry_probe_output" || true)
if [[ $registry_probe_status -ne 1 \
    || $duplicate_issue_count -ne 1 \
    || $summary_count -ne 1 \
    || $case_summary_count -ne 1 ]] \
    || rg -q \
        'Stack dump|fatal error|timed out|terminated by signal|Build failed' \
        "$registry_probe_output"; then
    echo "registry identity probe did not produce its exact expected failure" >&2
    rg \
        'Caught error:|Test run with|Stack dump|fatal error|timed out|terminated by signal|Build failed' \
        "$registry_probe_output" >&2 || true
    exit 1
fi

shopt -s nullglob
registry_fixture_residue=("$registry_probe_directory"/f-*)
shopt -u nullglob
if [[ ${#registry_fixture_residue[@]} -ne 0 \
    || ! -f $registry_probe_output \
    || -L $registry_probe_output ]]; then
    echo "registry identity probe left fixture residue" >&2
    exit 1
fi
rm -rf -- "$registry_probe_directory"
registry_probe_directory=""
registry_probe_cleanup_allowed=1
