# Translating Suwayomi Client for KOReader

Suwayomi Client uses gettext catalogs for plugin-authored UI text. English
`msgid` strings are the source text. Translated catalogs can be incomplete;
missing translations fall back to English on KOReader devices.

## Locales

Tracked catalogs:

- `ar`
- `de`
- `es`
- `fa`
- `fr`
- `hu`
- `id`
- `it`
- `ja`
- `ko`
- `pl`
- `pt`
- `ru`
- `vi`
- `zh_CN`
- `zh_TW`

Locale aliases:

- `zh-Hans`, `zh_Hans`, and `zh_CN` use `zh_CN`.
- `zh-Hant`, `zh_Hant`, and `zh_TW` use `zh_TW`.
- `pt_BR` and other Portuguese regions try `pt` first.
- Other regional locales try their full locale, then the base language.

## What To Translate

Translate plugin-authored labels, button text, menu titles, status summaries,
and confirmation messages.

Do not translate server or user data:

- manga titles
- chapter names
- source names
- scanlator names
- category names
- genre names
- URLs
- filesystem paths
- usernames or credentials
- debug keys
- raw API or worker errors

## Placeholders

Keep placeholders exactly as written:

- `%1`
- `%2`
- `%3`

Example:

```po
msgid "Downloading %1/%2"
msgstr "Lade %1/%2 herunter"
```

Do not add, remove, or renumber placeholders.

## Plurals

Plural entries use gettext plural rules from each `.po` header. Translate every
`msgstr[n]` entry shown by your editor. Keep placeholders in every plural form
where the English source has them.

Example:

```po
msgid "%1 chapter"
msgid_plural "%1 chapters"
msgstr[0] "%1 Kapitel"
msgstr[1] "%1 Kapitel"
```

## Context

Some short words include context. Context tells translators where the word is
used and should not be translated as visible text.

Example:

```po
msgctxt "browse action"
msgid "Search"
msgstr "Suchen"
```

## Updating Catalogs

Install GNU gettext tools, then run:

```bash
./scripts/update-l10n.sh
./scripts/check-l10n.sh
```

Before release, compile runtime catalogs:

```bash
./scripts/compile-l10n.sh
```

Compiled `.mo` files are generated artifacts. Do not commit them unless a
maintainer explicitly asks for a release artifact experiment.

## Privacy

Screenshots and bug reports must not expose server URLs, usernames, credentials,
manga library contents, local paths, or downloaded chapter names. Redact private
data before sharing device screenshots.

## Weblate Setup For Maintainers

Create a Weblate component only after repository CI verifies l10n checks.

Recommended component settings:

- File format: Gettext PO file
- File mask: `l10n/*/suwayomi.po`
- Template for new translations: `l10n/templates/suwayomi.pot`
- Source language: English
- Translation license: match repository license
- Push commits: `.po` files only
- Pull requests: enabled if direct push is not desired

Add a README Weblate badge only after the hosted component URL exists.
