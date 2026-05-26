#!/usr/bin/env bash
set -euo pipefail

domain="suwayomi"

for tool in xgettext msgmerge msgattrib msgfmt msginit; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing required gettext tool: %s\n' "$tool" >&2
        exit 1
    }
done

git_cmd() {
    if pwd -W >/dev/null 2>&1; then
        git -C "$(pwd -W)" "$@"
    elif [ -f .git ] && grep -q '^gitdir: [A-Za-z]:' .git; then
        local gitdir drive rest
        gitdir="$(sed 's/^gitdir: //' .git)"
        drive="$(printf '%s' "$gitdir" | cut -c1 | tr '[:upper:]' '[:lower:]')"
        rest="$(printf '%s' "$gitdir" | cut -c4-)"
        gitdir="/mnt/$drive/$rest"
        git --git-dir="$gitdir" --work-tree="$PWD" "$@"
    else
        git "$@"
    fi
}

before="$(mktemp)"
after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

git_cmd diff -- l10n ':!l10n/*/suwayomi.mo' > "$before"
./scripts/update-l10n.sh
git_cmd diff -- l10n ':!l10n/*/suwayomi.mo' > "$after"

if ! cmp -s "$before" "$after"; then
    printf '%s\n' 'l10n sources are not current. Run ./scripts/update-l10n.sh and commit the result.' >&2
    git_cmd diff -- l10n ':!l10n/*/suwayomi.mo' >&2
    exit 1
fi

for po in l10n/*/"$domain.po"; do
    [ -f "$po" ] || continue
    msgfmt --check --check-format --statistics --output-file=/dev/null "$po"
done

./scripts/compile-l10n.sh

missing=0
for po in l10n/*/"$domain.po"; do
    [ -f "$po" ] || continue
    mo="$(dirname "$po")/$domain.mo"
    if [ ! -s "$mo" ]; then
        printf 'Compiled catalog missing or empty: %s\n' "$mo" >&2
        missing=1
    fi
done

exit "$missing"
