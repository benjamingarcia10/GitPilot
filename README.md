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

Three options, fastest to most production-like:

```bash
swift run gitpilot             # debug build, ~1s incremental. Action buttons may not work.
./scripts/build-app.sh         # full bundle. Quit + open GitPilot.app to relaunch.
./scripts/dev.sh               # watch + auto-rebuild + relaunch + tee stderr. Ctrl+C to stop.
```

`dev.sh` is the recommended dev loop: it polls `Sources/` and `scripts/` for changes, rebuilds the bundle, relaunches the app, and tees timing logs to your terminal so you can see what's slow.

Action buttons on notifications require a code-signed bundle, so `swift run` is fine for menu UI iteration but not the full notification UX.

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
