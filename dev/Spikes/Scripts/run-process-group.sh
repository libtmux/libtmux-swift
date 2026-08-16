#!/usr/bin/env bash

set -uo pipefail

run_bounded() {
    shift
    [[ ${1:-} == "--timeout" && $# -ge 3 ]] || exit 64
    local timeout_seconds=$2
    shift 2
    [[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || exit 64
    [[ ${1:-} == "--output" && $# -ge 3 ]] || exit 64
    local output_path=$2
    shift 2
    [[ ${1:-} == "--cwd" && $# -ge 3 ]] || exit 64
    local working_directory=$2
    shift 2
    local timeout_marker=""
    local before_release_gate=""
    local after_status_gate=""
    while [[ ${1:-} == "--timeout-marker" \
        || ${1:-} == "--before-release-gate" \
        || ${1:-} == "--after-status-gate" ]]; do
        (( $# >= 3 )) || exit 64
        case $1 in
            --timeout-marker)
                [[ -z $timeout_marker ]] || exit 64
                timeout_marker=$2
                ;;
            --before-release-gate)
                [[ -z $before_release_gate ]] || exit 64
                before_release_gate=$2
                ;;
            --after-status-gate)
                [[ -z $after_status_gate ]] || exit 64
                after_status_gate=$2
                ;;
        esac
        shift 2
    done
    if [[ -n $timeout_marker ]]; then
        local timeout_marker_directory timeout_marker_name
        timeout_marker_directory=$(cd "$(dirname "$timeout_marker")" && pwd -P) \
            || exit 125
        timeout_marker_name=$(basename "$timeout_marker")
        [[ $timeout_marker == "$timeout_marker_directory/$timeout_marker_name" \
            && $timeout_marker_name != "." && $timeout_marker_name != ".." \
            && ! -e $timeout_marker && ! -L $timeout_marker ]] || exit 125
    fi
    local gate gate_directory gate_name
    for gate in "$before_release_gate" "$after_status_gate"; do
        [[ -n $gate ]] || continue
        gate_directory=$(cd "$(dirname "$gate")" && pwd -P) || exit 125
        gate_name=$(basename "$gate")
        [[ $gate == "$gate_directory/$gate_name" \
            && $gate_name != "." && $gate_name != ".." \
            && -p $gate && ! -L $gate \
            && ! -e $gate.ready && ! -L $gate.ready ]] || exit 125
    done
    [[ ${1:-} == "--" ]] || exit 64
    shift
    (( $# > 0 )) || exit 64
    [[ -d $working_directory ]] || exit 125

    local script_directory script_path
    script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 125
    script_path="$script_directory/$(basename "${BASH_SOURCE[0]}")"
    local temporary_directory
    temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/libtmux-bounded.XXXXXX") || exit 125
    chmod 700 "$temporary_directory" || {
        rm -rf -- "$temporary_directory"
        exit 125
    }

    local child=""
    local child_job_handle=""
    local group=""
    local group_authenticated=0
    local payload_released=0
    local waited=0
    local stopping=0
    local pending_signal_status=0
    local status_path="$temporary_directory/status"
    local status_token="$$-$RANDOM-$RANDOM"

    capture_owned_job_handle() {
        local expected=$1
        local listing
        local label
        local observed

        [[ $expected =~ ^[1-9][0-9]*$ ]] || return 1
        listing=$(jobs -l %+ 2>/dev/null) || return 1
        IFS=' ' read -r label observed _ <<<"$listing"
        [[ $label =~ ^\[([1-9][0-9]*)\][+-]?$ ]] || return 1
        [[ $observed == "$expected" ]] || return 1
        REPLY="%${BASH_REMATCH[1]}"
    }

    capture_concrete_job_handle() {
        local expected=$1
        local listing
        local line
        local match=""

        [[ $expected =~ ^[1-9][0-9]*$ ]] || return 1
        listing=$(LC_ALL=C jobs -l 2>/dev/null) || return 1
        while IFS= read -r line; do
            if [[ $line =~ ^\[([1-9][0-9]*)\][+-]?[[:space:]]+([1-9][0-9]*)[[:space:]] ]]; then
                if [[ ${BASH_REMATCH[2]} == "$expected" ]]; then
                    [[ -z $match ]] || return 1
                    match="%${BASH_REMATCH[1]}"
                fi
            elif [[ $line == \[* ]]; then
                return 1
            fi
        done <<<"$listing"
        if [[ -z $match ]]; then
            return 3
        fi
        REPLY=$match
    }

    owned_job_handle_is_active() {
        local job_handle=$1
        local expected=$2
        local observed

        [[ $job_handle =~ ^%[1-9][0-9]*$ ]] || return 1
        [[ $expected =~ ^[1-9][0-9]*$ ]] || return 1
        jobs -x test "$job_handle" = "$expected" 2>/dev/null || return 1
        observed=$(jobs -p "$job_handle" 2>/dev/null) || return 1
        observed=${observed//[[:space:]]/}
        [[ $observed == "$expected" ]]
    }

    signal_owned_job_handle() {
        local signal=$1
        local job_handle=$2
        local expected=$3

        owned_job_handle_is_active "$job_handle" "$expected" || return 1
        builtin kill -s "$signal" -- "$job_handle" 2>/dev/null
    }

    bounded_leader_alive() {
        owned_job_handle_is_active "$child_job_handle" "$child"
    }

    defer_bounded_signal() {
        local status=$1
        (( pending_signal_status != 0 )) || pending_signal_status=$status
    }

    restore_bounded_signal_traps() {
        trap 'exit 130' INT
        trap 'exit 129' HUP
        trap 'exit 143' TERM
    }

    retire_current_job_after_capture_failure() {
        local capture_status=0
        local cleanup_failed=0
        local recovered_job_handle=""
        local wait_status=0

        capture_concrete_job_handle "$child" || capture_status=$?
        if (( capture_status == 0 )); then
            recovered_job_handle=$REPLY
            if owned_job_handle_is_active "$recovered_job_handle" "$child"; then
                builtin kill -s KILL -- "$recovered_job_handle" 2>/dev/null \
                    || cleanup_failed=1
            else
                cleanup_failed=1
            fi
        elif (( capture_status != 3 )); then
            return 1
        fi
        builtin wait "$child" 2>/dev/null || wait_status=$?
        waited=1
        child=""
        child_job_handle=""
        group=""
        group_authenticated=0
        payload_released=0
        (( cleanup_failed == 0 && wait_status != 127 ))
    }

    bounded_stop() {
        if (( waited == 1 )); then
            return 0
        fi
        (( stopping == 0 )) || return 1
        stopping=1
        trap '' INT HUP TERM
        local cleanup_failed=0
        if (( group_authenticated == 1 )); then
            if ! bounded_leader_alive; then
                cleanup_failed=1
            else
                if (( payload_released == 1 )); then
                    signal_owned_job_handle \
                        TERM "$child_job_handle" "$child" || cleanup_failed=1
                    signal_owned_job_handle \
                        CONT "$child_job_handle" "$child" || cleanup_failed=1
                    sleep 0.5
                fi
                if bounded_leader_alive; then
                    signal_owned_job_handle \
                        KILL "$child_job_handle" "$child" || cleanup_failed=1
                else
                    cleanup_failed=1
                fi
            fi
        elif bounded_leader_alive; then
            signal_owned_job_handle KILL "$child_job_handle" "$child" || {
                bounded_leader_alive && cleanup_failed=1
            }
        fi

        if [[ $child =~ ^[1-9][0-9]*$ ]]; then
            local wait_status
            wait "$child" 2>/dev/null
            wait_status=$?
            (( wait_status != 127 )) || cleanup_failed=1
        fi
        waited=1
        child=""
        child_job_handle=""
        group=""
        group_authenticated=0
        payload_released=0
        (( cleanup_failed == 0 ))
    }

    publish_timeout_marker() {
        [[ -n $timeout_marker ]] || return 0
        local pending="$timeout_marker.pending.$$-$RANDOM"
        umask 077
        (set -C; printf 'timed-out\n' >"$pending") || return 1
        chmod 600 "$pending" || {
            rm -f -- "$pending"
            return 1
        }
        if ! ln "$pending" "$timeout_marker"; then
            rm -f -- "$pending"
            return 1
        fi
        rm -f -- "$pending"
    }

    wait_at_gate() {
        local gate=$1
        [[ -n $gate ]] || return 0
        local pending="$gate.ready.pending.$$-$RANDOM"
        exec 9<>"$gate" || return 1
        umask 077
        (set -C; printf '%s %s\n' "$child" "$group" >"$pending") || {
            exec 9>&-
            return 1
        }
        if ! ln "$pending" "$gate.ready"; then
            rm -f -- "$pending"
            exec 9>&-
            return 1
        fi
        rm -f -- "$pending"
        local gate_status=0
        IFS= read -r _ <&9 || gate_status=$?
        exec 9>&-
        return "$gate_status"
    }

    bounded_exit() {
        local status=$?
        trap - EXIT
        trap '' INT HUP TERM
        if bounded_stop; then
            rm -rf -- "$temporary_directory"
        else
            echo "bounded runner cleanup was incomplete" >&2
            status=125
        fi
        exit "$status"
    }
    trap bounded_exit EXIT
    restore_bounded_signal_traps

    local host_group
    host_group=$(LC_ALL=C ps -o pgid= -p $$ 2>/dev/null || true)
    host_group=${host_group//[[:space:]]/}
    [[ $host_group =~ ^[1-9][0-9]*$ ]] || exit 125

    trap 'defer_bounded_signal 130' INT
    trap 'defer_bounded_signal 129' HUP
    trap 'defer_bounded_signal 143' TERM
    set -m
    bash "$script_path" \
        --supervise \
        --cwd "$working_directory" \
        --status "$status_path" \
        --token "$status_token" \
        -- "$@" >"$output_path" 2>&1 &
    child=$!
    if ! capture_owned_job_handle "$child"; then
        retire_current_job_after_capture_failure || true
        set +m
        restore_bounded_signal_traps
        exit 125
    fi
    child_job_handle=$REPLY
    set +m
    restore_bounded_signal_traps
    (( pending_signal_status == 0 )) || exit "$pending_signal_status"

    local handshake_deadline=$((SECONDS + 5))
    while bounded_leader_alive && (( SECONDS < handshake_deadline )); do
        local process_record child_state child_group
        process_record=$(LC_ALL=C ps -o stat= -o pgid= -p "$child" 2>/dev/null || true)
        read -r child_state child_group <<<"$process_record"
        child_group=${child_group//[[:space:]]/}
        if [[ $child_state == *T* && $child_group == "$child" \
            && $child_group != "$host_group" ]] \
            && bounded_leader_alive; then
            group=$child_group
            group_authenticated=1
            break
        fi
        sleep 0.01
    done
    (( group_authenticated == 1 )) || exit 125
    wait_at_gate "$before_release_gate" || exit 125
    signal_owned_job_handle CONT "$child_job_handle" "$child" || exit 125
    payload_released=1

    local timed_out=0
    local deadline=$((SECONDS + timeout_seconds))
    while bounded_leader_alive; do
        [[ -r $status_path ]] && break
        if (( SECONDS >= deadline )); then
            timed_out=1
            break
        fi
        sleep 0.05
    done

    local payload_status=""
    if [[ -r $status_path ]]; then
        local marker_token extra
        read -r marker_token payload_status extra <"$status_path"
        if [[ -n ${extra:-} || $marker_token != "$status_token" \
            || ! $payload_status =~ ^[0-9]+$ || $payload_status -gt 255 ]]; then
            payload_status=""
        fi
    fi
    if [[ -n $payload_status ]]; then
        wait_at_gate "$after_status_gate" || exit 125
    fi
    local marker_failed=0
    if (( timed_out == 1 )); then
        publish_timeout_marker || marker_failed=1
    fi
    bounded_stop || exit 125
    (( marker_failed == 0 )) || exit 125
    (( timed_out == 0 )) || exit 124
    [[ -n $payload_status ]] || exit 125
    exit "$payload_status"
}

if [[ ${1:-} == "--bounded" ]]; then
    run_bounded "$@"
fi

mode=exec
if [[ ${1:-} == "--supervise" ]]; then
    mode=supervise
    shift
fi
[[ ${1:-} == "--cwd" && $# -ge 3 ]] || exit 64
working_directory=$2
shift 2

status_path=""
status_token=""
if [[ $mode == "supervise" ]]; then
    [[ ${1:-} == "--status" && $# -ge 3 ]] || exit 64
    status_path=$2
    shift 2
    [[ ${1:-} == "--token" && $# -ge 3 ]] || exit 64
    status_token=$2
    shift 2
fi
[[ ${1:-} == "--" ]] || exit 64
shift
(( $# > 0 )) || exit 64
cd -- "$working_directory" || exit 125

if [[ $mode == "exec" ]]; then
    exec "$@"
fi

# The parent authenticates this stopped shell as the private process-group
# leader before allowing it to create the payload.
trap ':' HUP INT TERM
kill -STOP $$ || exit 125
set +m
bash -c 'trap - HUP INT TERM; exec "$@"' bash "$@" &
payload=$!
hold_fifo="$status_path.hold"
if ! mkfifo "$hold_fifo"; then
    while :; do
        kill -STOP $$ || true
    done
fi
status=0
wait "$payload" || status=$?
printf '%s %s\n' "$status_token" "$status" >"$status_path.pending" \
    && mv "$status_path.pending" "$status_path" \
    || {
        while :; do
            kill -STOP $$ || true
        done
    }
while :; do
    read -r _ <"$hold_fifo" || true
done
