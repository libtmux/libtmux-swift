#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
spikes_directory=$(cd "$script_directory/.." && pwd)
repository_directory=$(cd "$spikes_directory/../.." && pwd)
fixture_directory="$spikes_directory/Fixtures"
source_directory="$spikes_directory/Sources/KeyPathBakeoff"
generator="$script_directory/generate-key-path-switch.swift"
group_wrapper="$script_directory/run-process-group.sh"
generated_source="$source_directory/GeneratedSwitch.swift"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/libtmux-keypath-diagnostics.XXXXXX")
active_child=""
active_job_handle=""
active_group=""
active_group_authenticated=0
active_status_path=""
active_token=""
active_waited=0
active_status=0
active_cleanup_started=0
termination_requested=0
pending_signal_status=0
command_index=0
set -m

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

leader_alive() {
    owned_job_handle_is_active "$active_job_handle" "$active_child"
}

defer_script_signal() {
    (( pending_signal_status != 0 )) || pending_signal_status=130
}

restore_script_signal_traps() {
    trap 'terminate_script' INT TERM HUP
}

retire_current_job_after_capture_failure() {
    local capture_status=0
    local cleanup_failed=0
    local recovered_job_handle=""
    local wait_status=0

    capture_concrete_job_handle "$active_child" || capture_status=$?
    if (( capture_status == 0 )); then
        recovered_job_handle=$REPLY
        if owned_job_handle_is_active "$recovered_job_handle" "$active_child"; then
            builtin kill -s KILL -- "$recovered_job_handle" 2>/dev/null \
                || cleanup_failed=1
        else
            cleanup_failed=1
        fi
    elif (( capture_status != 3 )); then
        return 1
    fi
    builtin wait "$active_child" 2>/dev/null || wait_status=$?
    active_waited=1
    active_child=""
    active_job_handle=""
    active_group=""
    active_group_authenticated=0
    (( cleanup_failed == 0 && wait_status != 127 ))
}

reap_active_child() {
    (( active_waited == 0 )) || return 0
    local child=$active_child
    active_status=0
    wait "$child" 2>/dev/null || active_status=$?
    active_waited=1
    active_child=""
    active_job_handle=""
    (( active_status != 127 ))
}

stop_active_child_impl() {
    [[ $active_child =~ ^[1-9][0-9]*$ ]] || return 0
    (( active_waited == 0 )) || return 0
    local cleanup_failed=0
    if (( active_group_authenticated == 0 )); then
        if leader_alive; then
            signal_owned_job_handle KILL "$active_job_handle" "$active_child" || {
                leader_alive && cleanup_failed=1
            }
        fi
        reap_active_child || cleanup_failed=1
        return "$cleanup_failed"
    fi

    if ! leader_alive; then
        cleanup_failed=1
    else
        signal_owned_job_handle \
            TERM "$active_job_handle" "$active_child" || cleanup_failed=1
        signal_owned_job_handle \
            CONT "$active_job_handle" "$active_child" || cleanup_failed=1
    fi
    local attempt=0
    while leader_alive && (( attempt < 8 )); do
        sleep 0.05
        (( attempt += 1 ))
    done
    if leader_alive; then
        signal_owned_job_handle \
            KILL "$active_job_handle" "$active_child" || cleanup_failed=1
    else
        cleanup_failed=1
    fi
    reap_active_child || cleanup_failed=1
    (( cleanup_failed == 0 ))
}

stop_active_child() {
    trap '' INT TERM HUP
    (( active_cleanup_started == 0 )) || return 0
    active_cleanup_started=1
    local result=0
    stop_active_child_impl || result=$?
    active_cleanup_started=0
    if (( termination_requested == 0 )); then
        trap 'terminate_script' INT TERM HUP
    fi
    return "$result"
}

cleanup() {
    trap '' INT TERM HUP
    termination_requested=1
    if stop_active_child; then
        rm -rf -- "$temporary_directory"
    fi
}
terminate_script() {
    trap '' INT TERM HUP
    termination_requested=1
    local cleanup_status=0
    stop_active_child || cleanup_status=$?
    (( cleanup_status == 0 )) || exit 125
    exit 130
}
trap cleanup EXIT
trap 'terminate_script' INT TERM HUP

usage() {
    echo "usage: test-diagnostics.sh [--modules DIRECTORY | --supervisor-probe MARKER]" >&2
    exit 64
}

modules_directory=""
supervisor_probe_marker=""
if [[ $# -gt 0 ]]; then
    if [[ $# -eq 2 && $1 == "--modules" ]]; then
        modules_directory=$2
    elif [[ $# -eq 2 && $1 == "--supervisor-probe" ]]; then
        supervisor_probe_marker=$2
    else
        usage
    fi
fi
if [[ -z "$modules_directory" ]]; then
    modules_directory="$spikes_directory/.build/debug/Modules"
fi

host_group=$(ps -o pgid= -p $$ 2>/dev/null || true)
host_group=${host_group//[[:space:]]/}
[[ $host_group =~ ^[1-9][0-9]*$ ]] || {
    echo "unable to authenticate diagnostic host process group" >&2
    exit 1
}

run_bounded() {
    local output_path=$1
    shift
    (( command_index += 1 ))
    active_group=""
    active_job_handle=""
    active_group_authenticated=0
    active_status_path="$temporary_directory/status-$command_index"
    active_token="$$-$RANDOM-$RANDOM-$command_index"
    active_waited=0
    active_status=0
    active_cleanup_started=0
    pending_signal_status=0
    trap 'defer_script_signal' INT TERM HUP
    bash "$group_wrapper" \
        --supervise \
        --cwd "$PWD" \
        --status "$active_status_path" \
        --token "$active_token" \
        -- "$@" >"$output_path" 2>&1 &
    active_child=$!
    if ! capture_owned_job_handle "$active_child"; then
        retire_current_job_after_capture_failure || true
        restore_script_signal_traps
        return 125
    fi
    active_job_handle=$REPLY
    restore_script_signal_traps
    (( pending_signal_status == 0 )) || terminate_script
    local handshake_deadline=$((SECONDS + 5))
    while leader_alive && (( SECONDS < handshake_deadline )); do
        local process_record child_state child_group
        process_record=$(ps -o stat= -o pgid= -p "$active_child" 2>/dev/null || true)
        read -r child_state child_group <<<"$process_record"
        child_group=${child_group//[[:space:]]/}
        if [[ $child_state == *T* && $child_group == "$active_child" \
            && $child_group != "$host_group" ]] \
            && leader_alive; then
            active_group=$child_group
            active_group_authenticated=1
            break
        fi
        sleep 0.01
    done
    if (( active_group_authenticated == 0 )); then
        stop_active_child || true
        active_child=""
        return 125
    fi
    if [[ -n $supervisor_probe_marker ]]; then
        if ! printf '%s %s\n' "$$" "$active_child" \
            >"$supervisor_probe_marker.supervisor.pending" \
            || ! mv "$supervisor_probe_marker.supervisor.pending" \
                "$supervisor_probe_marker.supervisor"; then
            stop_active_child || true
            active_child=""
            return 125
        fi
    fi
    signal_owned_job_handle CONT "$active_job_handle" "$active_child" || {
        stop_active_child || true
        active_child=""
        return 125
    }
    local timed_out=0
    local deadline=$((SECONDS + 15))
    while leader_alive; do
        [[ -r $active_status_path ]] && break
        if ((SECONDS >= deadline)); then
            timed_out=1
            break
        fi
        sleep 0.05
    done
    local payload_status=""
    if [[ -r $active_status_path ]]; then
        local marker_token extra
        read -r marker_token payload_status extra <"$active_status_path"
        if [[ -n ${extra:-} || $marker_token != "$active_token" \
            || ! $payload_status =~ ^[0-9]+$ || $payload_status -gt 255 ]]; then
            payload_status=""
        fi
    fi
    if ! stop_active_child; then
        return 125
    fi
    active_child=""
    active_job_handle=""
    active_group=""
    active_group_authenticated=0
    active_status_path=""
    active_token=""
    (( timed_out == 0 )) || return 124
    [[ -n $payload_status ]] || return 125
    return "$payload_status"
}

if [[ -n $supervisor_probe_marker ]]; then
    probe_output="$temporary_directory/supervisor-probe.out"
    run_bounded "$probe_output" bash -c '
        marker=$1
        mkfifo "$marker.descendant-release"
        mkfifo "$marker.payload-release"
        trap "" TERM
        bash -c '\''trap "" TERM; read -r _ < "$1"'\'' \
            bash "$marker.descendant-release" &
        descendant=$!
        printf "%s %s\n" "$$" "$descendant" >"$marker.payload.pending"
        mv "$marker.payload.pending" "$marker.payload"
        read -r _ < "$marker.payload-release"
    ' bash "$supervisor_probe_marker"
    exit $?
fi

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

require_no_infrastructure_error() {
    local output_path=$1
    local contents
    contents=$(<"$output_path")
    case "$contents" in
        *"no such module"* | *"error opening input file"* | *"unable to load standard library"* \
        | *"Stack dump"* | *"PLEASE submit a bug report"* | *"swift-frontend command failed due to signal"* \
        | *"Segmentation fault"* | *"Assertion failed"*)
            echo "diagnostic probe failed before type checking" >&2
            return 1
            ;;
    esac
}

sanitize_output() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line//"$modules_directory"/<modules>}
        line=${line//"$repository_directory"/<repo>}
        line=${line//"$temporary_directory"/<temp>}
        printf '%s\n' "$line"
    done <"$1"
}

version_output="$temporary_directory/swiftc-version.out"
if ! run_bounded "$version_output" swiftc --version; then
    echo "swiftc version probe failed" >&2
    sanitize_output "$version_output" >&2
    exit 1
fi
if ! rg -q '^(Apple )?Swift version 6\.2\.4 ' "$version_output"; then
    echo "diagnostics require Swift 6.2.4" >&2
    sanitize_output "$version_output" >&2
    exit 1
fi

[[ -r "$modules_directory/KeyPathBakeoff.swiftmodule" ]] || {
    echo "KeyPathBakeoff module is unavailable; build Spikes first" >&2
    exit 1
}
[[ -r "$modules_directory/SpikeSupport.swiftmodule" ]] || {
    echo "SpikeSupport module is unavailable; build Spikes first" >&2
    exit 1
}

supervisor_control_output="$temporary_directory/supervisor-control.out"
supervisor_control_fifo="$temporary_directory/supervisor-control.fifo"
if ! run_bounded "$supervisor_control_output" bash -c '
    mkfifo "$1"
    bash -c '\''read -r _ < "$1"'\'' bash "$1" &
    exit 0
' bash "$supervisor_control_fifo"; then
    echo "shell supervisor failed to clean a descendant after payload exit" >&2
    exit 1
fi
echo "SHELL_SUPERVISOR stopped-auth=passed payload-exit-cleanup=passed"

qualified_fixture="$temporary_directory/qualified.swift"
printf '%s\n' \
    'import KeyPathBakeoff' \
    'func qualified() throws {' \
    '    let expression = try FilterExpr<Pane>.where(\.command, .in(["nvim", "vim"]))' \
    '    _ = expression' \
    '}' \
    >"$qualified_fixture"

concise_fixture="$temporary_directory/concise.swift"
printf '%s\n' \
    'import KeyPathBakeoff' \
    'func concise() throws {' \
    '    let expression: FilterExpr<Pane> = try `where`(\.title, .contains("logs"))' \
    '    _ = expression' \
    '}' \
    >"$concise_fixture"

for valid_fixture in "$qualified_fixture" "$concise_fixture"; do
    output="$temporary_directory/valid-$(basename "$valid_fixture").out"
    if ! run_bounded "$output" swiftc \
        -typecheck \
        -parse-as-library \
        -module-name KeyPathDiagnosticFixture \
        -no-color-diagnostics \
        -module-cache-path "$temporary_directory/module-cache" \
        -package-name spikes \
        -swift-version 6 \
        -strict-concurrency=complete \
        -warnings-as-errors \
        -I "$modules_directory" \
        "$valid_fixture"; then
        require_no_infrastructure_error "$output"
        sanitize_output "$output" >&2
        exit 1
    fi
done

invalid_fixtures=(
    "evaluation-only-root-wire.swift"
    "string-operator-on-int.swift"
    "relation-operator-on-scalar.swift"
    "wrong-root-field.swift"
)
invalid_categories=(
    "error: .*requires that 'EvaluationOnlyRoot' conform to 'WireQueryRoot'"
    "error: referencing static method 'contains'.*requires the types 'Int' and 'String' be equivalent"
    "error: .*has no member 'some'"
    "cannot convert value of type 'KeyPath<.*PaneSession"
)
invalid_authorities=(
    "JSONEncoder"
    "FilterOperator<Int>"
    "FilterOperator<String>"
    "KeyPath<Pane, Projected<String>>"
)

for index in "${!invalid_fixtures[@]}"; do
    fixture=${invalid_fixtures[$index]}
    category=${invalid_categories[$index]}
    authority=${invalid_authorities[$index]}
    output="$temporary_directory/$fixture.out"
    status=0
    run_bounded "$output" swiftc \
        -typecheck \
        -parse-as-library \
        -module-name KeyPathDiagnosticFixture \
        -no-color-diagnostics \
        -module-cache-path "$temporary_directory/module-cache" \
        -package-name spikes \
        -swift-version 6 \
        -strict-concurrency=complete \
        -warnings-as-errors \
        -I "$modules_directory" \
        "$fixture_directory/CompileFail/$fixture" || status=$?
    if [[ $status -eq 0 ]]; then
        echo "$fixture unexpectedly compiled" >&2
        exit 1
    fi
    if [[ $status -ne 1 ]]; then
        echo "$fixture compiler probe failed as infrastructure (status $status)" >&2
        sanitize_output "$output" >&2
        exit 1
    fi
    require_no_infrastructure_error "$output"
    if ! rg -q -- 'error:' "$output" || ! rg -q -- "$category" "$output" \
        || ! rg -F -q -- "$authority" "$output"; then
        echo "$fixture failed outside its intended diagnostic category: $category" >&2
        sanitize_output "$output" >&2
        exit 1
    fi
done

global_output="$temporary_directory/process-global.out"
global_status=0
run_bounded "$global_output" swiftc \
    -typecheck \
    -parse-as-library \
    -module-name KeyPathDiagnosticFixture \
    -no-color-diagnostics \
    -module-cache-path "$temporary_directory/module-cache" \
    -package-name spikes \
    -swift-version 6 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -I "$modules_directory" \
    "$fixture_directory/Diagnostics/process-global-erased-map.swift" || global_status=$?
require_no_infrastructure_error "$global_output"
if [[ $global_status -eq 0 ]]; then
    echo "NEUTRAL_PROBE status=0 outcome=accepted"
elif [[ $global_status -eq 1 ]]; then
    if ! rg -q -- "error: .*concurrency-safe|error: .*non-.*Sendable.*AnyKeyPath" \
        "$global_output"; then
        echo "process-global-erased-map failed outside the concurrency category" >&2
        sanitize_output "$global_output" >&2
        exit 1
    fi
    echo "NEUTRAL_PROBE status=1 outcome=rejected"
    sanitize_output "$global_output"
else
    echo "process-global-erased-map probe failed as infrastructure (status $global_status)" >&2
    sanitize_output "$global_output" >&2
    exit 1
fi

[[ -r "$generator" && -r "$generated_source" ]] || {
    echo "generated-switch inputs are unavailable" >&2
    exit 1
}
before_hash=$(hash_file "$generated_source")
generator_output="$temporary_directory/generator.out"
cd "$temporary_directory"
if ! run_bounded "$generator_output" swift \
    -module-cache-path "$temporary_directory/generator-module-cache" \
    "$generator" \
    --check; then
    sanitize_output "$generator_output" >&2
    exit 1
fi
after_hash=$(hash_file "$generated_source")
[[ "$before_hash" == "$after_hash" ]] || {
    echo "generator --check mutated generated output" >&2
    exit 1
}

echo "key-path diagnostics: passed"
