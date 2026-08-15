#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "usage: $0 --source TMUX_CHECKOUT --output MATRIX_DIRECTORY" >&2
    exit 2
}

normalize_absolute_path() {
    local input=$1
    local component
    local result=""
    local -a components
    local -a normalized=()

    [[ "$input" == /* ]] || input="$PWD/$input"
    IFS='/' read -r -a components <<<"$input"
    for component in "${components[@]}"; do
        case "$component" in
            "" | .)
                ;;
            ..)
                if ((${#normalized[@]})); then
                    unset 'normalized[${#normalized[@]}-1]'
                fi
                ;;
            *)
                normalized+=("$component")
                ;;
        esac
    done

    for component in "${normalized[@]}"; do
        result="$result/$component"
    done
    printf '%s\n' "${result:-/}"
}

canonicalize_path_for_creation() {
    local normalized
    local probe
    local resolved
    local component
    local -a suffix=()

    normalized=$(normalize_absolute_path "$1")
    probe=$normalized
    while [[ ! -e "$probe" && ! -L "$probe" ]]; do
        [[ "$probe" != "/" ]] || break
        suffix=("$(basename "$probe")" "${suffix[@]}")
        probe=$(dirname "$probe")
    done
    [[ -d "$probe" ]] || return 1
    resolved=$(cd "$probe" && pwd -P)
    for component in "${suffix[@]}"; do
        resolved="${resolved%/}/$component"
    done
    normalize_absolute_path "$resolved"
}

paths_overlap() {
    local first=$1
    local second=$2

    [[ "$first" == "/" || "$second" == "/" || "$first" == "$second" \
        || "$first" == "$second"/* || "$second" == "$first"/* ]]
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

source_argument=""
output_argument=""
while (($#)); do
    case "$1" in
        --source)
            (($# >= 2)) || usage
            source_argument=$2
            shift 2
            ;;
        --output)
            (($# >= 2)) || usage
            output_argument=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$source_argument" && -n "$output_argument" ]] || usage
[[ -d "$source_argument/.git" ]] || {
    echo "tmux source is not a Git checkout" >&2
    exit 1
}

source_checkout=$(cd "$source_argument" && pwd -P)
output_directory=$(canonicalize_path_for_creation "$output_argument") || {
    echo "matrix output path cannot be resolved" >&2
    exit 1
}
if paths_overlap "$source_checkout" "$output_directory"; then
    echo "tmux source and matrix output paths overlap" >&2
    exit 1
fi

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
lane_declaration="$script_directory/../Fixtures/tmux-matrix.json"
[[ -f "$lane_declaration" ]] || {
    echo "tmux lane declaration is missing" >&2
    exit 1
}

required_origin="https://github.com/tmux/tmux.git"
snapshot_directory=""
build_directory=""
manifest_temporary=""
snapshot_ready=0
manifest_published=0

capture_source_state() {
    local suffix=$1

    git -C "$source_checkout" remote get-url origin >"$snapshot_directory/origin.$suffix" \
        && git -C "$source_checkout" status --porcelain=v2 \
            >"$snapshot_directory/status.$suffix" \
        && git -C "$source_checkout" rev-parse HEAD >"$snapshot_directory/head.$suffix" \
        && git -C "$source_checkout" show-ref >"$snapshot_directory/refs.$suffix" \
        && git -C "$source_checkout" ls-files -s >"$snapshot_directory/index.$suffix"
}

source_state_matches() {
    local initial=$1
    local final=$2
    local field

    for field in origin status head refs index; do
        cmp -s "$snapshot_directory/$field.$initial" "$snapshot_directory/$field.$final" \
            || return 1
    done
}

remove_temporary_directory() {
    local directory=$1

    [[ -n "$directory" && "$directory" != "/" && -d "$directory" ]] || return 0
    rm -rf -- "$directory"
}

cleanup() {
    local result=$?
    local changed=0

    set +e
    if ((snapshot_ready)); then
        capture_source_state exit || changed=1
        source_state_matches initial exit || changed=1
    fi
    if ((changed)); then
        echo "tmux source checkout changed during the build" >&2
        result=1
        if ((manifest_published)); then
            rm -f -- "$output_directory/manifest.json"
        fi
    fi

    [[ -z "$manifest_temporary" ]] || rm -f -- "$manifest_temporary"
    remove_temporary_directory "$build_directory"
    remove_temporary_directory "$snapshot_directory"
    trap - EXIT
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$output_directory"
snapshot_directory=$(mktemp -d)
build_directory=$(mktemp -d)
manifest_temporary="$output_directory/.manifest.json.$$"
capture_source_state initial
snapshot_ready=1

origin_url=$(<"$snapshot_directory/origin.initial")
[[ "$origin_url" == "$required_origin" ]] || {
    echo "tmux source origin is not the official repository" >&2
    exit 1
}
[[ ! -s "$snapshot_directory/status.initial" ]] || {
    echo "tmux source checkout is dirty before the build" >&2
    exit 1
}

initial_head=$(<"$snapshot_directory/head.initial")
initial_refs_sha256="sha256:$(sha256_file "$snapshot_directory/refs.initial")"
initial_index_sha256="sha256:$(sha256_file "$snapshot_directory/index.initial")"
compiler=${CC:-cc}
compiler_identity=$($compiler --version | sed -n '1p')
jobs=${LIBTMUX_MATRIX_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
mkdir -p "$output_directory/logs"

lanes='[]'
while IFS= read -r tag; do
    [[ "$tag" =~ ^[0-9]+\.[0-9]+[a-z]?$ ]] || {
        echo "unsafe tmux lane tag: $tag" >&2
        exit 1
    }
    tag_reference="refs/tags/$tag"
    git -C "$source_checkout" show-ref --verify "$tag_reference" >/dev/null
    [[ $(git -C "$source_checkout" cat-file -t "$tag_reference") == "tag" ]] || {
        echo "tmux tag $tag is not an annotated tag" >&2
        exit 1
    }
    tag_object=$(git -C "$source_checkout" rev-parse "$tag_reference")
    peeled_source_object=$(git -C "$source_checkout" rev-parse "$tag_reference^{}")
    [[ $(git -C "$source_checkout" cat-file -t "$tag_reference^{}") == "commit" ]] || {
        echo "tmux tag $tag does not peel to a commit" >&2
        exit 1
    }

    lane_build="$build_directory/$tag"
    lane_output="$output_directory/$tag"
    [[ "$lane_output" == "$output_directory"/* ]] || {
        echo "unsafe tmux lane output" >&2
        exit 1
    }
    mkdir -p "$lane_build"
    rm -rf -- "$lane_output"

    git -C "$source_checkout" archive --format=tar "$tag_reference^{}" \
        | tar -xf - -C "$lane_build"

    (
        cd "$lane_build"
        sh autogen.sh
    ) >"$output_directory/logs/$tag-bootstrap.log" 2>&1
    (
        cd "$lane_build"
        ./configure --prefix="$lane_output"
    ) >"$output_directory/logs/$tag-configure.log" 2>&1
    make -C "$lane_build" -j"$jobs" \
        >"$output_directory/logs/$tag-build.log" 2>&1
    make -C "$lane_build" install \
        >"$output_directory/logs/$tag-install.log" 2>&1

    binary="$lane_output/bin/tmux"
    [[ -x "$binary" ]] || {
        echo "tmux $tag did not install an executable" >&2
        exit 1
    }
    reported_version=$($binary -V)
    [[ "$reported_version" == "tmux $tag" ]] || {
        echo "tmux $tag reported unexpected version: $reported_version" >&2
        exit 1
    }
    binary_sha256=$(sha256_file "$binary")

    entry=$(jq -n \
        --arg tag "$tag" \
        --arg tagObject "$tag_object" \
        --arg peeledSourceObject "$peeled_source_object" \
        --arg binaryPath "$tag/bin/tmux" \
        --arg binarySHA256 "$binary_sha256" \
        --arg reportedVersion "$reported_version" \
        --arg compilerIdentity "$compiler_identity" \
        '{
            tag: $tag,
            tagObject: $tagObject,
            peeledSourceObject: $peeledSourceObject,
            binaryPath: $binaryPath,
            binarySHA256: $binarySHA256,
            reportedVersion: $reportedVersion,
            compilerIdentity: $compilerIdentity,
            buildStatus: "passed"
        }')
    lanes=$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$lanes")

    capture_source_state lane
    source_state_matches initial lane || {
        echo "tmux source checkout changed while building $tag" >&2
        exit 1
    }
done < <(jq -r '.[]' "$lane_declaration")

capture_source_state final
source_state_matches initial final || {
    echo "tmux source checkout changed during the build" >&2
    exit 1
}

final_refs_sha256="sha256:$(sha256_file "$snapshot_directory/refs.final")"
final_index_sha256="sha256:$(sha256_file "$snapshot_directory/index.final")"

jq -n \
    --arg originURL "$origin_url" \
    --arg head "$initial_head" \
    --arg initialRefsSHA256 "$initial_refs_sha256" \
    --arg finalRefsSHA256 "$final_refs_sha256" \
    --arg initialIndexSHA256 "$initial_index_sha256" \
    --arg finalIndexSHA256 "$final_index_sha256" \
    --arg operatingSystem "$(uname -s)" \
    --arg architecture "$(uname -m)" \
    --arg compiler "$compiler_identity" \
    --arg make "$(make --version | sed -n '1p')" \
    --arg autoconf "$(autoconf --version | sed -n '1p')" \
    --arg automake "$(automake --version | sed -n '1p')" \
    --arg libevent "$(pkg-config --modversion libevent)" \
    --arg ncurses "$(pkg-config --modversion ncurses)" \
    --argjson lanes "$lanes" \
    '{
        documentKind: "libtmux.tmux-matrix-manifest",
        schemaVersion: 1,
        source: {
            originURL: $originURL,
            head: $head,
            initialStatus: "",
            finalStatus: "",
            initialRefsSHA256: $initialRefsSHA256,
            finalRefsSHA256: $finalRefsSHA256,
            initialIndexSHA256: $initialIndexSHA256,
            finalIndexSHA256: $finalIndexSHA256,
            sourceUnchanged: true
        },
        buildInputs: {
            operatingSystem: $operatingSystem,
            architecture: $architecture,
            compiler: $compiler,
            make: $make,
            autoconf: $autoconf,
            automake: $automake,
            libevent: $libevent,
            ncurses: $ncurses
        },
        lanes: $lanes
    }' >"$manifest_temporary"

mv "$manifest_temporary" "$output_directory/manifest.json"
manifest_published=1
echo "built and authenticated $(jq 'length' <<<"$lanes") tmux lanes"
