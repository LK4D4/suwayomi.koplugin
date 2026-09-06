# Issue tracker: GitHub

Track issues and specs in GitHub Issues for LK4D4/suwayomi.koplugin.
Use the gh CLI from the repository checkout.

## Operations

- Create: `gh issue create --title "..." --body-file <path>`
- Read: `gh issue view <number> --json number,title,body,labels,comments`
- List: `gh issue list --state open --json number,title,body,labels`
- Comment: `gh issue comment <number> --body-file <path>`
- Label: `gh issue edit <number> --add-label "..." --remove-label "..."`
- Close: `gh issue close <number>`

For multiline text, write the exact content to a temporary file and pass
--body-file. Apply the label vocabulary in docs/agents/triage-labels.md.

When a skill says "publish to the issue tracker", create a GitHub issue.
When a skill says "fetch the relevant ticket", read the issue and its comments.

## Pull requests as a triage surface

**PRs as a request surface: no.**
