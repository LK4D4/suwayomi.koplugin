# Chinese Mainland Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Simplified Chinese translations for the KOReader/Suwayomi plugin catalog used by Chinese mainland locale `zh_CN`.

**Architecture:** Runtime locale mapping already routes `zh-Hans`, `zh_Hans`, `zh-CN`, and `zh_CN` to `l10n/zh_CN/suwayomi.po`. This change only fills that catalog; no runtime module, release packaging, or locale fallback behavior changes.

**Tech Stack:** GNU gettext PO catalogs, LuaJIT, Busted, Luacheck.

---

### Task 1: Fill zh_CN Catalog

**Files:**
- Modify: `l10n/zh_CN/suwayomi.po`
- Modify: `l10n/zh_CN/suwayomi.mo`
- Review: `docs/TRANSLATING.md`

- [ ] **Step 1: Confirm locale target**

Run: `rg -n "zh_CN|zh_TW|zh-Hans|zh-Hant" docs/TRANSLATING.md suwayomi/i18n/locales.lua spec/suwayomi_i18n_locales_spec.lua`

Expected: `zh_CN` maps Simplified Chinese aliases and `zh_TW` maps Traditional Chinese aliases.

- [ ] **Step 2: Translate plugin-authored strings**

Fill `msgstr` and plural `msgstr[n]` entries in `l10n/zh_CN/suwayomi.po` with Simplified Chinese.

Keep these rules:
- Preserve `%1`, `%2`, `%3` exactly.
- Preserve quotes around user-visible inserted titles where source text uses them.
- Do not translate external/user/server data inserted through placeholders.
- Leave brand names `Suwayomi` and `KOReader` unchanged.
- Prefer matching Suwayomi WebUI `zh-Hans` terms for shared navigation and domain words such as `Library` (`书架`), `Browse` (`浏览`), `Extensions` (`扩展`), `Source` (`源`), `Updates` (`更新`), and `Installed` (`已安装`).

- [ ] **Step 3: Verify catalog freshness**

Run: `bash ./scripts/check-l10n.sh`

Expected: command exits 0, reports `344 translated messages.` for `zh_CN`, and refreshes the tracked compiled catalog at `l10n/zh_CN/suwayomi.mo`.

- [ ] **Step 4: Verify Lua project**

Run: `luacheck --codes spec suwayomi main.lua _meta.lua`

Expected: command exits 0 with all files clean.

Run: `busted spec`

Expected: command exits 0 with all specs passing.

- [ ] **Step 5: Commit**

Run:

```bash
git add docs/superpowers/plans/2026-05-26-zh-cn-translation.md l10n/zh_CN/suwayomi.po l10n/zh_CN/suwayomi.mo
git commit -m "l10n: add zh_CN translations"
```
