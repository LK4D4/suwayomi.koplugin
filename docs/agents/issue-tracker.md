# Issue tracker: GitHub

Track requested work and specs in GitHub Issues for `LK4D4/suwayomi.koplugin`, not PRs or local ticket maps. PRs may carry implementation review. Use `gh` from the repository checkout.

- Read: `gh issue view <number> --json number,title,state,body,labels,comments`
- List open work: `gh issue list --state open --json number,title,body,labels`
- Create: `gh issue create --title "..." --body-file <path>`
- Comment: `gh issue comment <number> --body-file <path>`
- Label: `gh issue edit <number> --add-label "..." --remove-label "..."`
- Close: `gh issue close <number>`

For multiline bodies, pass exact text through a temporary file with `--body-file`. Use the labels in [triage-labels.md](triage-labels.md).

Read the current state and comments before acting; they may amend an older body or checklist. When a skill requests ticket publication or retrieval, use these operations rather than creating another local mirror.
