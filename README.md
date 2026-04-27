# GitPilot

macOS menu bar app that watches your open GitHub PRs and pings you with a native notification the moment one needs a rebase or is ready to merge. Click the notification's **Rebase** button and GitPilot calls GitHub's `updatePullRequestBranch` GraphQL mutation with `updateMethod: REBASE` — same effect as picking "Update with rebase" from the dropdown on the PR page.

The merge button stays in your hands. GitPilot only opens the window; you walk through it.

## Prerequisites

- macOS 13 or later
- Xcode command line tools (`xcode-select --install`)
- [`gh`](https://cli.github.com/) authenticated: `gh auth login`

## Build

```bash
./scripts/build-app.sh
open GitPilot.app
```

The first launch will ask for notification permission. Allow it.

## Develop

```bash
swift build           # debug build, fast
swift run gitpilot    # run in-place (notifications work but action buttons may not)
./scripts/build-app.sh && open GitPilot.app   # full bundle, action buttons work
```

For action buttons on notifications to work, you need the bundled `.app`. The plain `swift run` binary works for the menu bar UI but not the rich notification UX.

## How it works

- `GitHubClient` reads your token from `gh auth token` and queries the GraphQL `search` API for `is:pr is:open author:<you>`.
- `PRMonitor` polls every 30s and emits edge-triggered transitions: `needsBranchUpdate` and `readyToMerge`.
- `NotificationService` registers two notification categories with action buttons and routes user choices back to the app.
- `AppState` glues them together; the **Rebase** action calls `updatePullRequestBranch(updateMethod: REBASE)`.

## Roadmap

- Notification when a watched PR fails CI
- Per-PR pinning so you only watch the one you care about
- Auto-rebase when CI is idle, opt-in per PR
- Generic "git helper" home for related personal tooling
