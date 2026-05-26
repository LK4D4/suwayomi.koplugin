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
    if find l10n -type f -name 'suwayomi.mo' 2>/dev/null | grep -q .; then
        mkdir "$payload_dir/l10n"
        while IFS= read -r mo; do
            locale="${mo#l10n/}"
            locale="${locale%/suwayomi.mo}"
            mkdir -p "$payload_dir/l10n/$locale"
            cp "$mo" "$payload_dir/l10n/$locale/suwayomi.mo"
        done < <(find l10n -type f -name 'suwayomi.mo' | LC_ALL=C sort)
    fi
fi

mapfile -t top_level < <(find "$payload_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
expected=(README.md _meta.lua main.lua suwayomi)
if [ -d "$payload_dir/l10n" ]; then
    expected=(README.md _meta.lua l10n main.lua suwayomi)
fi

for forbidden in .github .git docs spec AGENTS.md; do
    if [ -e "$payload_dir/$forbidden" ]; then
        fail "Dev-only path entered release payload: $forbidden"
    fi
done

if [ -d "$payload_dir/l10n" ]; then
    while IFS= read -r file; do
        case "$file" in
            "$payload_dir"/l10n/*/suwayomi.mo) ;;
            *) fail "Unexpected l10n release payload entry: ${file#$payload_dir/}" ;;
        esac
    done < <(find "$payload_dir/l10n" -type f | LC_ALL=C sort)
fi

if [ "${#top_level[@]}" -ne "${#expected[@]}" ]; then
    fail "Release payload top-level entry count mismatch"
fi

for index in "${!expected[@]}"; do
    if [ "${top_level[$index]}" != "${expected[$index]}" ]; then
        fail "Unexpected release payload entry: ${top_level[$index]} (expected ${expected[$index]})"
    fi
done

find "$payload_dir" -print | sort
