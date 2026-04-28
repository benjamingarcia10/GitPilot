# GitPilot

A macOS menu bar app that watches your GitHub PRs and pings you the moment one needs attention — behind the base branch, ready to merge, or blocked by failing CI. Click the notification's **Rebase** button and GitPilot calls GitHub's `updatePullRequestBranch` GraphQL mutation directly. Same effect as picking *"Update with rebase"* from the dropdown on the PR page, without leaving your current task.

The merge button stays in your hands by default. Opt in to auto-merge per PR if you want it.

## Features

### Menu bar surface
- Status glyph + attention-count badge: at a glance you can tell how many PRs are ready / behind / conflicted / blocked. The icon swaps between *checkmark* (ready), *circular arrows* (behind), *triangle* (conflicts), *lock* (blocked), and the default PR glyph.
- Four tabs in the popover:
  - **My PRs** — PRs you authored
  - **Reviewing** — PRs where you (or a team you're a member of) are requested as reviewer. Reviewer pills show *why* you're on the list (`you` or `@team-slug`).
  - **Activity** — chronological log of state transitions and your actions (capped at 200 entries / 7 days)
  - **Worktrees** — every worktree this app manages, with clean/dirty/missing status
- Search bar with **regex toggle**, **repo filter**, and **5 sort orders** (updated, PR # asc/desc, title A–Z, status priority).
- Inline-expandable check list per PR — every CI check or status context with deep links to wherever it ran (Buildkite, GitHub Actions, CircleCI, etc.).

### Notifications (native macOS)
- Behind base → action button **Rebase** (calls `updatePullRequestBranch`)
- Ready to merge → action button **Open PR**
- CI failing → action button **Open PR**
- Auto-rebase failed → action button **Open PR**
- Each notification is edge-triggered (one fire per state transition, deduped across restarts) and individually toggleable in Settings.

### Per-PR controls (right-click any row)
- **Pin** — when any PR is pinned, only pinned PRs trigger notifications. Pinned PRs always sort to the top.
- **Snooze** — 30 min / 2 hr / until tomorrow 9 AM. Suppresses notifications and auto-rebase. Live countdown on the row.
- **Auto-rebase** — when the PR transitions to behind base, rebase silently. Notifies only on failure.
- **Auto-merge** — tries GitHub-native `enablePullRequestAutoMerge` first; if the repo doesn't allow it, falls back to **client-side auto-merge** (calls `mergePullRequest` from this app whenever the PR becomes ready).
- **Worktree** — create a worktree for the PR's branch under your configured root (default `~/worktrees/gitpilot`), open it in your editor, remove when done. Refuses to remove dirty worktrees without confirmation.

### Settings
- Poll interval (10s / 30s / 1m / 2m / 5m)
- Per-notification kind toggles
- Per-repo auto-merge method override (SQUASH / MERGE / REBASE — defaults to whatever the repo allows in that order)
- Worktree root + editor command (auto-detects Cursor → VSCode → Sublime → Finder)
- "Send test notification" button to verify the notification pipeline

### Under the hood
- Two-phase fetch: a fast list query (`viewer.pullRequests`) followed by parallel per-PR enrichment for `mergeStateStatus` / review decision / CI rollup. Up to 32 concurrent connections.
- Retries on GitHub's lazy `UNKNOWN` mergeStateStatus (0.5s → 1s → 2s).
- Debounced atomic JSON persistence at `~/Library/Application Support/GitPilot/state.json`, with a synchronous flush on app termination.
- Auth via the `gh` CLI; explicit reauth banner with one-click retry on 401.
- Hourly refresh of viewer team-membership for the Reviewing-tab pill filter.

## Prerequisites

- macOS 13 or later
- Xcode command line tools (`xcode-select --install`)
- [`gh`](https://cli.github.com/) authenticated: `gh auth login`

## Build and run

```bash
./scripts/build-app.sh
open GitPilot.app
```

The first launch asks for notification permission. Allow it.

## Develop

```bash
swift run gitpilot             # debug build, ~1s incremental. Action buttons may not work.
./scripts/build-app.sh         # full bundle. Quit + open GitPilot.app to relaunch.
./scripts/dev.sh               # watch + auto-rebuild + relaunch + tee stderr. Ctrl+C to stop.
```

`dev.sh` is the recommended dev loop: it polls `Sources/` and `scripts/` for changes, rebuilds the bundle, relaunches the app, and tees timing logs to your terminal so you can see what's slow.

Action buttons on notifications require a code-signed bundle, so `swift run` is fine for menu UI iteration but not the full notification UX.

`GITPILOT_DEBUG=1` enables verbose timings (`Log.debug`).

## Distribute

```bash
./scripts/package.sh           # writes dist/GitPilot-<version>.zip + .sha256
./scripts/package.sh 0.2.0     # override version
```

The bundle is ad-hoc code-signed. Recipients will see a Gatekeeper warning the first time they open it; right-click → Open clears it. To skip that, sign with a Developer ID Application cert and notarize via `xcrun notarytool submit`.

## Architecture

```
GitPilotApp.swift     SwiftUI app entry; menu bar surface + tab body
AppState.swift        Single owner of all UX policy: transitions, dedupe, snooze, pin,
                      auto-rebase, auto-merge, persistence
PRMonitor.swift       Pure fetcher with a 30s poll loop; emits per-PR enrichment +
                      list-settled events
GitHubClient.swift    GraphQL client over URLSession; auth via `gh auth token`
NotificationService.swift  Wraps UNUserNotificationCenter; routes action button
                      taps back to AppState
WorktreeManager.swift  git fetch + worktree add/remove via async Process continuations
PersistedState.swift  JSON-on-disk schema + atomic debounced writes
TabContents.swift     Activity + Worktrees tabs
PRRowView.swift       PR row + inline check list
AuxViews.swift        Search bar, refresh button, pinned banner, auth banner, settings
ViewHelpers.swift     Hover modifiers + button styles
Log.swift             Stderr logger gated by GITPILOT_DEBUG
```

PR list flow:
1. `PRMonitor.refresh()` calls `fetchMyOpenPRs` (light list).
2. UI updates immediately so rows render with placeholder status.
3. `enrichPR` runs per PR in parallel; each result is applied as it arrives.
4. After each apply, `AppState.handle(prUpdated:)` decides whether to notify, auto-rebase, or auto-merge based on dedupe + snooze + pin + auto flags.
