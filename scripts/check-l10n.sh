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

expected_plural_forms() {
    case "$1" in
        ar) printf '%s\n' 'nplurals=6; plural=n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 && n%100<=99 ? 4 : 5;' ;;
        fa|id|ja|ko|vi|zh_CN|zh_TW) printf '%s\n' 'nplurals=1; plural=0;' ;;
        fr) printf '%s\n' 'nplurals=2; plural=(n > 1);' ;;
        pl) printf '%s\n' 'nplurals=3; plural=n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;' ;;
        ru) printf '%s\n' 'nplurals=3; plural=n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<12 || n%100>14) ? 1 : 2;' ;;
        *) printf '%s\n' 'nplurals=2; plural=(n != 1);' ;;
    esac
}

check_plural_header() {
    local po="$1"
    local locale expected actual
    locale="$(basename "$(dirname "$po")")"
    expected="$(expected_plural_forms "$locale")"
    actual="$(awk '
        /^"Plural-Forms: / { collecting = 1 }
        collecting && /^"/ {
            line = $0
            sub(/^"/, "", line)
            sub(/"$/, "", line)
            text = text line
            if (line ~ /\\n$/) {
                sub(/^Plural-Forms: /, "", text)
                sub(/\\n$/, "", text)
                print text
                exit
            }
            next
        }
        collecting { exit }
    ' "$po")"
    if [ "$actual" != "$expected" ]; then
        printf 'Unexpected plural header for %s: expected %s, got %s\n' "$locale" "$expected" "${actual:-<missing>}" >&2
        return 1
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
    check_plural_header "$po"
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
