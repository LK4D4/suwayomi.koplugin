#!/usr/bin/env bash
set -euo pipefail

payload_dir="${1:-suwayomi.koplugin}"
mode="${2:-stage}"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

if [ "$mode" != "validate-only" ]; then
    rm -rf "$payload_dir"
    mkdir "$payload_dir"

    cp _meta.lua main.lua README.md "$payload_dir"/
    cp -R suwayomi "$payload_dir"/
fi

mapfile -t top_level < <(find "$payload_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
expected=(README.md _meta.lua main.lua suwayomi)

for forbidden in .github .git docs spec AGENTS.md; do
    if [ -e "$payload_dir/$forbidden" ]; then
        fail "Dev-only path entered release payload: $forbidden"
    fi
done

if [ "${#top_level[@]}" -ne "${#expected[@]}" ]; then
    fail "Release payload top-level entry count mismatch"
fi

for index in "${!expected[@]}"; do
    if [ "${top_level[$index]}" != "${expected[$index]}" ]; then
        fail "Unexpected release payload entry: ${top_level[$index]} (expected ${expected[$index]})"
    fi
done

find "$payload_dir" -print | sort
