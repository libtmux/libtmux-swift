#!/usr/bin/env bash

set -euo pipefail

swift_version="$(swift --version)"
if [[ "$swift_version" != *"Swift version 6.2.4 "* ]]; then
    printf '%s\n' "expected Swift 6.2.4" >&2
    exit 1
fi

if rg --quiet 'unsafeFlags|\.plugin\(|\.macro\(' Spikes/Package.swift; then
    printf '%s\n' "manifest contains a forbidden setting or target" >&2
    exit 1
fi

swift package dump-package --package-path Spikes |
    jq --exit-status '
        .swiftLanguageVersions == ["6"] and
        ([.targets[] | select(.type == "plugin" or .type == "macro")] | length == 0) and
        ([.targets[].settings[]? | select(has("unsafeFlags"))] | length == 0) and
        ([.dependencies[].sourceControl[]
          | select(.identity == "swift-subprocess")
          | .requirement.range[]
          | .lowerBound, .upperBound] == ["1.0.0", "1.1.0"])
    ' >/dev/null
