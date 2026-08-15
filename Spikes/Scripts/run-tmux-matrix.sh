#!/usr/bin/env bash

set -euo pipefail

if [[ ${BASH_XTRACEFD:-} == 3 ]]; then
    export -n BASH_XTRACEFD
fi

usage() {
    echo "usage: $0 [--lane TAG] -- COMMAND [ARGUMENT ...]" >&2
    exit 2
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "no SHA-256 utility is available" >&2
        return 1
    fi
}

matrix_parent_supports_fixture_paths() {
    local parent=$1
    local tag
    local candidate
    local byte_count
    # The deepest endpoint a lane can bind: the sandbox TMPDIR child, a
    # test-owned scope directory, then the fixture run directory and socket.
    # A rejected parent falls back to /tmp rather than failing a bind at 103
    # bytes of sun_path midway through a lane.
    local fixture_suffix=/tmp/lt-XXXXXXXX/f-XXXXXXXXXXXXXXXXXXXXXX/s/s

    while IFS= read -r tag; do
        candidate="$parent/libtmux-matrix-$tag.XXXXXX$fixture_suffix"
        byte_count=$(LC_ALL=C printf '%s' "$candidate" | wc -c)
        ((byte_count <= 103)) || return 1
    done < <(jq -r '.[]' "$lane_declaration")
}

try_create_matrix_parent() {
    local requested_base=$1
    local base
    local candidate
    local parent

    base=$(cd "$requested_base" 2>/dev/null && pwd -P) || return 1
    [[ "$base" != "/" ]] || return 1
    candidate=$(mktemp -d "$base/l.XXXXXX") || return 1
    if ! chmod 700 "$candidate"; then
        if ! rmdir -- "$candidate"; then
            echo "matrix parent validation failed; artifacts preserved at $candidate" >&2
            return 2
        fi
        return 1
    fi
    parent=$(cd "$candidate" && pwd -P) || {
        if ! rmdir -- "$candidate"; then
            echo "matrix parent validation failed; artifacts preserved at $candidate" >&2
            return 2
        fi
        return 1
    }
    if [[ "$parent" != "$base"/l.* ]] \
        || ! matrix_parent_supports_fixture_paths "$parent"; then
        if ! rmdir -- "$parent"; then
            echo "matrix parent validation failed; artifacts preserved at $parent" >&2
            return 2
        fi
        return 1
    fi
    REPLY=$parent
}

create_matrix_parent() {
    local preferred_base=${TMPDIR:-/tmp}
    local preferred_status
    local preferred_canonical=""
    local system_canonical

    if try_create_matrix_parent "$preferred_base"; then
        return 0
    else
        preferred_status=$?
    fi
    ((preferred_status == 1)) || return "$preferred_status"

    preferred_canonical=$(cd "$preferred_base" 2>/dev/null && pwd -P) || true
    system_canonical=$(cd /tmp && pwd -P) || return 1
    [[ "$preferred_canonical" != "$system_canonical" ]] || return 1
    try_create_matrix_parent "$system_canonical"
}

job_is_owned() {
    local expected=$1
    local job
    while IFS= read -r job; do
        [[ "$job" == "$expected" ]] && return 0
    done < <(jobs -p)
    return 1
}

capture_owned_job_handle() {
    local expected=$1
    local listing
    local label
    local observed

    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 1
    listing=$(jobs -l %+ 2>/dev/null) || return 1
    IFS=' ' read -r label observed _ <<<"$listing"
    [[ "$label" =~ ^\[([1-9][0-9]*)\][+-]?$ ]] || return 1
    [[ "$observed" == "$expected" ]] || return 1
    REPLY="%${BASH_REMATCH[1]}"
}

capture_concrete_job_handle() {
    local expected=$1
    local listing
    local line
    local match=""

    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 1
    listing=$(LC_ALL=C jobs -l 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ $line =~ ^\[([1-9][0-9]*)\][+-]?[[:space:]]+([1-9][0-9]*)[[:space:]] ]]; then
            if [[ ${BASH_REMATCH[2]} == "$expected" ]]; then
                [[ -z "$match" ]] || return 1
                match="%${BASH_REMATCH[1]}"
            fi
        elif [[ $line == \[* ]]; then
            return 1
        fi
    done <<<"$listing"
    [[ -n "$match" ]] || return 3
    REPLY=$match
}

# A child whose handle could not be captured is still owned, but the current-job
# shorthand now names something else, so it is retired through the handle that
# resolves to its exact process identity. The caller reaps it.
retire_uncaptured_job() {
    local expected=$1
    local capture_status=0

    capture_concrete_job_handle "$expected" || capture_status=$?
    ((capture_status != 3)) || return 0
    ((capture_status == 0)) || return 1
    owned_job_handle_is_active "$REPLY" "$expected" || return 1
    builtin kill -s KILL -- "$REPLY" 2>/dev/null
}

owned_job_handle_is_active() {
    local job_handle=$1
    local expected=$2

    [[ "$job_handle" =~ ^%[1-9][0-9]*$ ]] || return 1
    [[ "$expected" =~ ^[1-9][0-9]*$ ]] || return 1
    jobs -x test "$job_handle" = "$expected" 2>/dev/null
}

signal_owned_job_handle() {
    local edge=$1
    local signal=$2
    local job_handle=$3
    local expected=$4

    owned_job_handle_is_active "$job_handle" "$expected" || return 1
    builtin kill -s "$signal" -- "$job_handle" 2>/dev/null
}

authentication_failure_is_injected() {
    local edge=$1
    local tag=$2

    [[ ${LIBTMUX_MATRIX_INJECT_AUTHENTICATION_FAILURE:-} == "$edge" \
        && ${LIBTMUX_MATRIX_FAILURE_TAG:-} == "$tag" ]]
}

prompt_term_exit_is_injected() {
    local edge=$1
    local tag=$2

    [[ ${LIBTMUX_MATRIX_INJECT_PROMPT_TERM_EXIT:-} == "$edge" \
        && ${LIBTMUX_MATRIX_FAILURE_TAG:-} == "$tag" ]]
}

publish_injected_checkpoint() {
    local checkpoint=${LIBTMUX_MATRIX_FAILURE_CHECKPOINT:-}
    local pending

    [[ -n "$checkpoint" && ! -e "$checkpoint" && ! -L "$checkpoint" ]] || return 94
    pending="$checkpoint.pending.$$-$RANDOM"
    (
        umask 077
        set -C
        printf 'ready\n' >"$pending"
    ) || return 94
    mv "$pending" "$checkpoint"
}

publish_lane_identity() {
    local identity_path=$1
    local process_id=$2
    local pending

    [[ "$process_id" =~ ^[1-9][0-9]*$ ]] || return 94
    [[ ! -e "$identity_path" && ! -L "$identity_path" ]] || return 94
    pending="$identity_path.pending.$$-$RANDOM"
    (
        umask 077
        set -C
        printf '%s\n' "$process_id" >"$pending"
    ) || return 94
    chmod 600 "$pending" || {
        rm -f -- "$pending"
        return 94
    }
    if ! ln "$pending" "$identity_path"; then
        rm -f -- "$pending"
        return 94
    fi
    rm -f -- "$pending"
}

read_lane_identity() {
    local identity_path=$1
    local deadline=$((SECONDS + 5))
    local extra=""

    while [[ ! -f "$identity_path" || -L "$identity_path" ]] \
        && ((SECONDS < deadline)); do
        sleep 0.01 || true
    done
    [[ -f "$identity_path" && ! -L "$identity_path" ]] || return 94
    IFS=' ' read -r REPLY extra <"$identity_path" || return 94
    [[ "$REPLY" =~ ^[1-9][0-9]*$ && -z "$extra" ]] || return 94
    rm -f -- "$identity_path" || return 94
}

hold_before_top_authentication() {
    local tag=$1

    authentication_failure_is_injected top-to-lane "$tag" || return 0
    publish_injected_checkpoint || return $?
    if prompt_term_exit_is_injected top-to-lane "$tag"; then
        trap '' HUP INT
        trap 'exit 143' TERM
    else
        trap '' HUP INT TERM
    fi
    while :; do
        sleep 1
    done
}

wait_for_injected_checkpoint() {
    local checkpoint=${LIBTMUX_MATRIX_FAILURE_CHECKPOINT:-}
    local deadline=$((SECONDS + 5))

    [[ -n "$checkpoint" ]] || {
        echo "matrix post-spawn failure checkpoint is missing" >&2
        return 94
    }
    while [[ ! -f "$checkpoint" ]] && ((SECONDS < deadline)); do
        sleep 0.01 || true
    done
    [[ -f "$checkpoint" ]] || {
        echo "matrix post-spawn failure checkpoint timed out" >&2
        return 94
    }
}

inject_post_spawn_failure() {
    local edge=$1
    local tag=$2
    local status=$3

    [[ ${LIBTMUX_MATRIX_INJECT_POST_SPAWN_FAILURE:-} == "$edge" ]] || return 0
    [[ ${LIBTMUX_MATRIX_FAILURE_TAG:-} == "$tag" ]] || return 0
    wait_for_injected_checkpoint || return $?
    return "$status"
}

selected_tag=""
if [[ ${1:-} == "--lane" ]]; then
    (($# >= 2)) || usage
    selected_tag=$2
    [[ -n "$selected_tag" ]] || usage
    shift 2
fi
[[ ${1:-} == "--" ]] || usage
shift
(($#)) || usage
command_arguments=("$@")

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
process_group_runner="$script_directory/run-process-group.sh"
lane_declaration="$script_directory/../Fixtures/tmux-matrix.json"
binary_root_argument=${LIBTMUX_MATRIX_BINARY_ROOT:-"$script_directory/../.build/tmux-matrix"}
command_working_directory=$(pwd -P)
[[ -f "$process_group_runner" ]] || {
    echo "bounded process-group runner is unavailable" >&2
    exit 1
}
[[ -d "$binary_root_argument" ]] || {
    echo "authenticated tmux matrix is missing; run build-tmux-matrix.sh" >&2
    exit 1
}
binary_root=$(cd "$binary_root_argument" && pwd -P)
[[ "$binary_root" != "/" ]] || {
    echo "authenticated tmux matrix root is unsafe" >&2
    exit 1
}
manifest_argument=${LIBTMUX_MATRIX_MANIFEST:-"$binary_root/manifest.json"}
manifest=$(cd "$(dirname "$manifest_argument")" && pwd -P)/$(basename "$manifest_argument")
timeout_seconds=${LIBTMUX_MATRIX_TIMEOUT_SECONDS:-300}

[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "LIBTMUX_MATRIX_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
}
[[ -f "$lane_declaration" && -f "$manifest" ]] || {
    echo "authenticated tmux matrix is missing; run build-tmux-matrix.sh" >&2
    exit 1
}

expected_tags=$(jq -c '.' "$lane_declaration")
actual_tags=$(jq -c '[.lanes[].tag]' "$manifest")
[[ "$actual_tags" == "$expected_tags" ]] || {
    echo "tmux matrix lanes do not match the declaration" >&2
    exit 1
}
if [[ -n "$selected_tag" ]] \
    && ! jq -e --arg tag "$selected_tag" \
        '[.lanes[] | select(.tag == $tag)] | length == 1' \
        "$manifest" >/dev/null; then
    echo "requested tmux matrix lane is unavailable: $selected_tag" >&2
    exit 2
fi

if ! jq -e '
    .documentKind == "libtmux.tmux-matrix-manifest"
    and .schemaVersion == 1
    and .source.originURL == "https://github.com/tmux/tmux.git"
    and .source.initialStatus == ""
    and .source.finalStatus == ""
    and (.source.initialRefsSHA256 | test("^sha256:[0-9a-f]{64}\\z"))
    and (.source.finalRefsSHA256 | test("^sha256:[0-9a-f]{64}\\z"))
    and (.source.initialIndexSHA256 | test("^sha256:[0-9a-f]{64}\\z"))
    and (.source.finalIndexSHA256 | test("^sha256:[0-9a-f]{64}\\z"))
    and .source.initialRefsSHA256 == .source.finalRefsSHA256
    and .source.initialIndexSHA256 == .source.finalIndexSHA256
    and .source.sourceUnchanged == true
' "$manifest" >/dev/null; then
    echo "tmux matrix source evidence is invalid" >&2
    exit 1
fi

while IFS=$'\t' read -r tag tag_object peeled binary_path binary_sha reported status; do
    [[ "$tag_object" =~ ^[0-9a-f]{40}$ && "$peeled" =~ ^[0-9a-f]{40}$ ]] || {
        echo "tmux $tag has invalid source objects" >&2
        exit 1
    }
    [[ "$reported" == "tmux $tag" && "$status" == "passed" ]] || {
        echo "tmux $tag has invalid build evidence" >&2
        exit 1
    }
    [[ "$binary_path" != /* && "$binary_path" != *".."* ]] || {
        echo "tmux $tag has an unsafe binary path" >&2
        exit 1
    }
    binary="$binary_root/$binary_path"
    [[ -x "$binary" ]] || {
        echo "tmux $tag binary is unavailable" >&2
        exit 1
    }
    [[ $(sha256_file "$binary") == "$binary_sha" ]] || {
        echo "tmux $tag binary hash does not match the manifest" >&2
        exit 1
    }
done < <(
    jq -r '.lanes[] | [
        .tag,
        .tagObject,
        .peeledSourceObject,
        .binaryPath,
        .binarySHA256,
        .reportedVersion,
        .buildStatus
    ] | @tsv' "$manifest"
)

logs_directory="$binary_root/runner-logs"
[[ "$logs_directory" == "$binary_root"/* ]] || {
    echo "tmux matrix log path is unsafe" >&2
    exit 1
}
rm -rf -- "$logs_directory"
mkdir -p "$logs_directory"
combined_status=0
matrix_parent=""
matrix_parent_created=0
matrix_pid=$$
matrix_trace_owner=$matrix_pid

run_lane() {
    local tag=$1
    local binary_path=$2
    local lane_identity_path=$3
    local binary="$binary_root/$binary_path"
    local lane_parent
    local lane_root
    local log="$logs_directory/$tag.log"
    local timeout_marker
    local lane_status
    local lane_succeeded=0
    local bounded_child=""
    local bounded_job_handle=""
    local bounded_child_spawned=0
    local bounded_child_authenticated=0
    local reaped_bounded_status=0
    local requested_signal_status=0
    local requested_signal_name=""
    local signal_relayed=0
    local relay_marker
    local relay_pending
    local lane_process_id
    local matrix_trace_owner=$matrix_pid
    local prompt_term_exit=0
    local -a bounded_arguments

    hold_before_top_authentication "$tag"

    reap_bounded_child() {
        local terminate_child=$1
        local deadline
        local child_status

        ((bounded_child_spawned == 1)) || return 0
        if ((terminate_child == 1)); then
            if owned_job_handle_is_active "$bounded_job_handle" "$bounded_child"; then
                signal_owned_job_handle \
                    lane-to-bounded TERM "$bounded_job_handle" "$bounded_child" || true
                signal_owned_job_handle \
                    lane-to-bounded CONT "$bounded_job_handle" "$bounded_child" || true
                deadline=$((SECONDS + 2))
                while owned_job_handle_is_active \
                    "$bounded_job_handle" "$bounded_child" \
                    && ((SECONDS < deadline)); do
                    sleep 0.01 || true
                done
            fi
            if owned_job_handle_is_active "$bounded_job_handle" "$bounded_child"; then
                signal_owned_job_handle \
                    lane-to-bounded KILL "$bounded_job_handle" "$bounded_child" || true
            fi
        fi

        if wait "$bounded_child"; then
            child_status=0
        else
            child_status=$?
        fi
        bounded_child=""
        bounded_job_handle=""
        bounded_child_authenticated=0
        bounded_child_spawned=0
        reaped_bounded_status=$child_status
    }

    relay_lane_signal() {
        local signal=$1
        local status=$2

        trap '' INT HUP TERM
        requested_signal_name=$signal
        requested_signal_status=$status
        if ((bounded_child_authenticated == 1)) \
            && [[ -n $bounded_job_handle ]]; then
            if signal_owned_job_handle \
                lane-to-bounded "$signal" "$bounded_job_handle" "$bounded_child"; then
                signal_owned_job_handle \
                    lane-to-bounded CONT "$bounded_job_handle" "$bounded_child" || true
                signal_relayed=1
            fi
        fi
    }

    cleanup_lane() {
        local lane_exit_status=$?

        trap - EXIT
        trap '' INT HUP TERM

        if ((bounded_child_spawned == 1)); then
            reap_bounded_child 1
            if ((lane_exit_status == 0)); then
                lane_exit_status=1
            fi
        fi

        if ((lane_exit_status == 0 && lane_succeeded == 1)) \
            && [[ -n ${lane_root:-} && "$lane_root" != "/" ]] \
            && [[ ! -e ${timeout_marker:-} && ! -L ${timeout_marker:-} ]]; then
            if ! rm -rf -- "$lane_root"; then
                echo "[$tag] lane cleanup failed; artifacts preserved" >&2
                exit 1
            fi
            exit 0
        fi

        if ((lane_exit_status == 0)); then
            exit 1
        fi
        exit "$lane_exit_status"
    }

    trap cleanup_lane EXIT
    trap 'relay_lane_signal INT 130' INT
    trap 'relay_lane_signal HUP 129' HUP
    trap 'relay_lane_signal TERM 143' TERM

    lane_parent=$matrix_parent
    lane_root=$(mktemp -d "$lane_parent/libtmux-matrix-$tag.XXXXXX")
    chmod 700 "$lane_root"
    mkdir -p "$lane_root/tmp" "$lane_root/run" "$lane_root/config"
    timeout_marker="$lane_root/timed-out"
    bounded_arguments=(
        --bounded
        --timeout "$timeout_seconds"
        --output "$log"
        --cwd "$command_working_directory"
        --timeout-marker "$timeout_marker"
    )
    if [[ -n ${LIBTMUX_MATRIX_BEFORE_RELEASE_GATE:-} ]]; then
        bounded_arguments+=(--before-release-gate "$LIBTMUX_MATRIX_BEFORE_RELEASE_GATE")
    fi
    if [[ -n ${LIBTMUX_MATRIX_AFTER_STATUS_GATE:-} ]]; then
        bounded_arguments+=(--after-status-gate "$LIBTMUX_MATRIX_AFTER_STATUS_GATE")
    fi

    set -m
    if authentication_failure_is_injected lane-to-bounded "$tag"; then
        if prompt_term_exit_is_injected lane-to-bounded "$tag"; then
            prompt_term_exit=1
        fi
        bash -c '
            checkpoint=$1
            [[ -n $checkpoint && -n ${2:-} && ! -e $checkpoint && ! -L $checkpoint ]] \
                || exit 94
            if [[ ${3:-0} == 1 ]]; then
                trap "" HUP INT
                trap "exit 143" TERM
            else
                trap "" HUP INT TERM
            fi
            pending="$checkpoint.pending.$$-$RANDOM"
            (umask 077; set -C; printf "ready\n" >"$pending") || exit 94
            mv "$pending" "$checkpoint" || exit 94
            while :; do sleep 1; done
        ' bash \
            "${LIBTMUX_MATRIX_FAILURE_CHECKPOINT:-}" \
            "${LIBTMUX_MATRIX_RECOVERY_TOKEN:-}" \
            "$prompt_term_exit" 3>&- &
    else
        TMPDIR="$lane_root/tmp" bash "$process_group_runner" \
            "${bounded_arguments[@]}" \
            -- \
            env \
            "LIBTMUX_TMUX_BIN=$binary" \
            "LIBTMUX_TMUX_TAG=$tag" \
            "LIBTMUX_MATRIX_ROOT=$lane_root" \
            "LIBTMUX_MATRIX_MANIFEST=$manifest" \
            "LIBTMUX_MATRIX_BINARY_ROOT=$binary_root" \
            "TMPDIR=$lane_root/tmp" \
            "XDG_RUNTIME_DIR=$lane_root/run" \
            "XDG_CONFIG_HOME=$lane_root/config" \
            "${command_arguments[@]}" 3>&- &
    fi
    bounded_child=$!
    bounded_child_spawned=1
    bounded_capture_status=0
    capture_owned_job_handle "$bounded_child" || bounded_capture_status=$?
    set +m
    if ((bounded_capture_status == 0)); then
        bounded_job_handle=$REPLY
        bounded_child_authenticated=1
    else
        retire_uncaptured_job "$bounded_child" || true
        reap_bounded_child 0
        return 1
    fi
    if authentication_failure_is_injected lane-to-bounded "$tag"; then
        bounded_child_authenticated=0
    fi
    if [[ -n $requested_signal_name ]] && ((signal_relayed == 0)) \
        && ((bounded_child_authenticated == 1)); then
        if signal_owned_job_handle \
            lane-to-bounded \
            "$requested_signal_name" \
            "$bounded_job_handle" \
            "$bounded_child"; then
            signal_owned_job_handle \
                lane-to-bounded CONT "$bounded_job_handle" "$bounded_child" || true
            signal_relayed=1
        fi
    fi
    if [[ ${LIBTMUX_MATRIX_RELAY_PROBE:-0} == 1 ]]; then
        relay_marker="$lane_root/relay-ownership"
        read_lane_identity "$lane_identity_path" || return $?
        lane_process_id=$REPLY
        matrix_trace_owner=$lane_process_id
        relay_pending="$relay_marker.pending.$lane_process_id"
        (
            umask 077
            set -C
            printf '%s %s %s\n' "$matrix_pid" "$lane_process_id" "$bounded_child" \
                >"$relay_pending"
        )
        mv "$relay_pending" "$relay_marker"
    fi

    inject_post_spawn_failure lane-to-bounded "$tag" 91 || return $?
    while job_is_owned "$bounded_child"; do
        sleep 0.01 || true
    done

    reap_bounded_child 0
    lane_status=$reaped_bounded_status

    if ((requested_signal_status != 0)); then
        return "$requested_signal_status"
    fi

    if [[ -e "$timeout_marker" ]]; then
        lane_status=124
        echo "[$tag] command timed out after ${timeout_seconds}s" >&2
    fi

    sed "s/^/[$tag] /" "$log" || return 125
    if ((lane_status == 0)); then
        lane_succeeded=1
    fi
    return "$lane_status"
}

lane_child=""
lane_job_handle=""
lane_child_spawned=0
lane_child_authenticated=0
lane_identity_path=""
reaped_lane_status=0
requested_matrix_signal_status=0
requested_matrix_signal_name=""
matrix_signal_relayed=0

reap_lane_child() {
    local terminate_child=$1
    local deadline
    local child_status

    ((lane_child_spawned == 1)) || return 0
    if ((terminate_child == 1)); then
        if owned_job_handle_is_active "$lane_job_handle" "$lane_child"; then
            signal_owned_job_handle \
                top-to-lane TERM "$lane_job_handle" "$lane_child" || true
            signal_owned_job_handle \
                top-to-lane CONT "$lane_job_handle" "$lane_child" || true
            deadline=$((SECONDS + 2))
            while owned_job_handle_is_active "$lane_job_handle" "$lane_child" \
                && ((SECONDS < deadline)); do
                sleep 0.01 || true
            done
        fi
        if owned_job_handle_is_active "$lane_job_handle" "$lane_child"; then
            signal_owned_job_handle \
                top-to-lane KILL "$lane_job_handle" "$lane_child" || true
        fi
    fi

    if wait "$lane_child"; then
        child_status=0
    else
        child_status=$?
    fi
    lane_child=""
    lane_job_handle=""
    lane_child_authenticated=0
    lane_child_spawned=0
    reaped_lane_status=$child_status
}

cleanup_matrix() {
    local matrix_exit_status=$?

    trap - EXIT
    trap '' INT HUP TERM
    if ((lane_child_spawned == 1)); then
        reap_lane_child 1
        if ((matrix_exit_status == 0)); then
            matrix_exit_status=1
        fi
    fi
    if [[ -n "$lane_identity_path" ]]; then
        rm -f -- "$lane_identity_path"
    fi
    if ((matrix_parent_created == 1)); then
        if ((matrix_exit_status == 0 && combined_status == 0)); then
            if rmdir -- "$matrix_parent"; then
                matrix_parent=""
                matrix_parent_created=0
            else
                echo "matrix parent cleanup failed; artifacts preserved at $matrix_parent" >&2
                matrix_exit_status=1
            fi
        else
            echo "matrix artifacts preserved at $matrix_parent" >&2
        fi
    fi
    exit "$matrix_exit_status"
}

relay_matrix_signal() {
    local signal=$1
    local status=$2

    trap '' INT HUP TERM
    requested_matrix_signal_name=$signal
    requested_matrix_signal_status=$status
    if ((lane_child_authenticated == 1)) \
        && [[ -n $lane_job_handle ]]; then
        if signal_owned_job_handle \
            top-to-lane "$signal" "$lane_job_handle" "$lane_child"; then
            signal_owned_job_handle \
                top-to-lane CONT "$lane_job_handle" "$lane_child" || true
            matrix_signal_relayed=1
        fi
    fi
}

trap cleanup_matrix EXIT
trap 'relay_matrix_signal INT 130' INT
trap 'relay_matrix_signal HUP 129' HUP
trap 'relay_matrix_signal TERM 143' TERM

if ! create_matrix_parent; then
    echo "unable to create a short private matrix parent" >&2
    exit 1
fi
matrix_parent=$REPLY
matrix_parent_created=1

while IFS=$'\t' read -r tag binary_path; do
    echo "[$tag] starting"
    lane_identity_path="$logs_directory/$tag.lane-process"
    [[ ! -e "$lane_identity_path" && ! -L "$lane_identity_path" ]] || exit 94
    set -m
    run_lane "$tag" "$binary_path" "$lane_identity_path" &
    lane_child=$!
    lane_child_spawned=1
    lane_capture_status=0
    capture_owned_job_handle "$lane_child" || lane_capture_status=$?
    set +m
    if ((lane_capture_status == 0)); then
        lane_job_handle=$REPLY
        lane_child_authenticated=1
    else
        retire_uncaptured_job "$lane_child" || true
        reap_lane_child 0
        exit 125
    fi
    if authentication_failure_is_injected top-to-lane "$tag"; then
        lane_child_authenticated=0
    fi
    if [[ ${LIBTMUX_MATRIX_RELAY_PROBE:-0} == 1 ]]; then
        publish_lane_identity "$lane_identity_path" "$lane_child" || exit $?
    fi
    if [[ -n $requested_matrix_signal_name ]] && ((matrix_signal_relayed == 0)) \
        && ((lane_child_authenticated == 1)); then
        if signal_owned_job_handle \
            top-to-lane \
            "$requested_matrix_signal_name" \
            "$lane_job_handle" \
            "$lane_child"; then
            signal_owned_job_handle \
                top-to-lane CONT "$lane_job_handle" "$lane_child" || true
            matrix_signal_relayed=1
        fi
    fi
    inject_post_spawn_failure top-to-lane "$tag" 92 || exit $?
    while job_is_owned "$lane_child"; do
        sleep 0.01 || true
    done

    reap_lane_child 0
    lane_status=$reaped_lane_status
    rm -f -- "$lane_identity_path"
    lane_identity_path=""

    if ((requested_matrix_signal_status != 0)); then
        exit "$requested_matrix_signal_status"
    fi
    if ((lane_status == 0)); then
        echo "[$tag] passed"
    else
        echo "[$tag] failed with status $lane_status" >&2
        combined_status=1
    fi
done < <(
    jq -r --arg selected_tag "$selected_tag" '
        .lanes[]
        | select(($selected_tag == "") or (.tag == $selected_tag))
        | [.tag, .binaryPath]
        | @tsv
    ' "$manifest"
)

exit "$combined_status"
