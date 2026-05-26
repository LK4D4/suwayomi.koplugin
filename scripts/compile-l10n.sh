#!/usr/bin/env bash
set -euo pipefail

domain="suwayomi"

command -v msgfmt >/dev/null 2>&1 || {
    printf 'Missing required gettext tool: msgfmt\n' >&2
    exit 1
}

for po in l10n/*/"$domain.po"; do
    [ -f "$po" ] || continue
    locale_dir="$(dirname "$po")"
    mo="$locale_dir/$domain.mo"
    msgfmt --check --no-hash --output-file="$mo" "$po"
done
