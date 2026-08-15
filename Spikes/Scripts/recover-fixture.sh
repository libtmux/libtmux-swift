#!/bin/bash

set -eu

reject_invalid_arguments() {
    printf '%s\n' '{"mode":"recover","outcome":"rejected","protocolVersion":2,"reason":"invalid-arguments"}'
    exit 2
}

reject_invalid_run_directory() {
    printf '%s\n' '{"mode":"recover","outcome":"rejected","protocolVersion":2,"reason":"invalid-run-directory"}'
    exit 2
}

reject_helper_authentication() {
    printf '%s\n' '{"mode":"recover","outcome":"rejected","protocolVersion":2,"reason":"helper-authentication-failed"}'
    exit 2
}

if [ "$#" -ne 2 ] || [ "$1" != "--run-directory" ]; then
    reject_invalid_arguments
fi

run_directory=$2
case "$run_directory" in
    /*) ;;
    *) reject_invalid_run_directory ;;
esac
case "$run_directory" in
    / | */ | *//* | */./* | */. | */../* | */..)
        reject_invalid_run_directory
        ;;
esac
run_name=${run_directory##*/}
case "$run_name" in
    f-?*) ;;
    *) reject_invalid_run_directory ;;
esac
if [ -L "$run_directory" ]; then
    reject_invalid_run_directory
fi
if [ -e "$run_directory" ] && [ ! -d "$run_directory" ]; then
    reject_invalid_run_directory
fi

helper=${LIBTMUX_FIXTURE_OWNER_HELPER-}
case "$helper" in
    /*/fixture-owner-helper) ;;
    *) reject_helper_authentication ;;
esac
case "$helper" in
    */ | *//* | */./* | */. | */../* | */..)
        reject_helper_authentication
        ;;
esac
if [ -L "$helper" ] || [ ! -f "$helper" ] || [ ! -x "$helper" ]; then
    reject_helper_authentication
fi

if ! platform=$(/usr/bin/uname -s 2>/dev/null); then
    reject_helper_authentication
fi
case "$platform" in
    Darwin)
        if ! helper_identity=$(/usr/bin/stat -f '%u %p' "$helper" 2>/dev/null); then
            reject_helper_authentication
        fi
        ;;
    Linux)
        if ! helper_identity=$(/usr/bin/stat -c '%u %f' -- "$helper" 2>/dev/null); then
            reject_helper_authentication
        fi
        ;;
    *) reject_helper_authentication ;;
esac
IFS=' ' read -r helper_uid helper_mode extra_identity <<< "$helper_identity"
case "$helper_uid" in
    '' | *[!0-9]*) reject_helper_authentication ;;
esac
case "$helper_mode" in
    '' | *[!0-9a-fA-F]*) reject_helper_authentication ;;
esac
if [ -n "${extra_identity-}" ]; then
    reject_helper_authentication
fi
if ! effective_uid=$(/usr/bin/id -u 2>/dev/null); then
    reject_helper_authentication
fi
case "$effective_uid" in
    '' | *[!0-9]*) reject_helper_authentication ;;
esac
case "$platform" in
    Darwin) helper_mode_value=$((8#$helper_mode)) ;;
    Linux) helper_mode_value=$((16#$helper_mode)) ;;
esac
if [ "$helper_uid" -ne "$effective_uid" ] \
    || (( (helper_mode_value & 18) != 0 )); then
    reject_helper_authentication
fi

exec /usr/bin/env -i \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    "$helper" recover --run-directory "$run_directory"
