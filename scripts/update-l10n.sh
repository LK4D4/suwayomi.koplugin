#!/usr/bin/env bash
set -euo pipefail

domain="suwayomi"
template="l10n/templates/$domain.pot"
locales=(
    ar
    de
    es
    fa
    fr
    hu
    id
    it
    ja
    ko
    pl
    pt
    ru
    vi
    zh_CN
    zh_TW
)

for tool in xgettext msgmerge msgattrib msginit; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing required gettext tool: %s\n' "$tool" >&2
        exit 1
    }
done

mkdir -p l10n/templates

mapfile -t runtime_lua < <(find suwayomi -type f -name '*.lua' | LC_ALL=C sort)
lua_files=(_meta.lua main.lua "${runtime_lua[@]}")

xgettext \
    --language=Lua \
    --from-code=UTF-8 \
    --add-comments=Translators: \
    --sort-output \
    --no-location \
    --package-name="Suwayomi Client for KOReader" \
    --package-version="1.0.4" \
    --msgid-bugs-address="https://github.com/Suwayomi/Suwayomi-Server/issues" \
    --keyword=_ \
    --keyword=I18n.t:1 \
    --keyword=I18n.f:1 \
    --keyword=I18n.c:1c,2 \
    --keyword=I18n.cf:1c,2 \
    --keyword=I18n.n:1,2 \
    --keyword=I18n.count:2,3 \
    --keyword=I18n.nf:2,3 \
    --output="$template" \
    "${lua_files[@]}"

sed -i 's/POT-Creation-Date: .*/POT-Creation-Date: 1970-01-01 00:00+0000\\n"/' "$template"

for locale in "${locales[@]}"; do
    locale_dir="l10n/$locale"
    po="$locale_dir/$domain.po"
    mkdir -p "$locale_dir"
    if [ ! -f "$po" ]; then
        msginit \
            --no-translator \
            --locale="$locale" \
            --input="$template" \
            --output-file="$po"
    else
        msgmerge --update --backup=none "$po" "$template"
    fi
    msgattrib --no-obsolete --output-file="$po" "$po"
    sed -i \
        -e 's/PO-Revision-Date: .*/PO-Revision-Date: 1970-01-01 00:00+0000\\n"/' \
        -e 's/POT-Creation-Date: .*/POT-Creation-Date: 1970-01-01 00:00+0000\\n"/' \
        -e 's/Content-Type: text\/plain; charset=.*/Content-Type: text\/plain; charset=UTF-8\\n"/' \
        -e 's/Plural-Forms: .*/Plural-Forms: nplurals=2; plural=(n != 1);\\n"/' \
        "$po"
done
