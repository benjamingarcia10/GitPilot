# GitPilot

A macOS menu bar app that watches your GitHub PRs and pings you the moment one needs attention — behind the base branch, ready to merge, or blocked by failing CI. Click the notification's **Rebase** button and GitPilot calls GitHub's `updatePullRequestBranch` GraphQL mutation directly. Same effect as picking *"Update with rebase"* from the dropdown on the PR page, without leaving your current task.

The merge button stays in your hands by default. Opt in to auto-merge per PR if you want it.

## Features

### Menu bar surface
- Status glyph + attention-count badge: at a glance you can tell how many PRs are ready / behind / conflicted / blocked. The icon swaps between *checkmark* (ready), *circular arrows* (behind), *triangle* (conflicts), *lock* (blocked), and the default PR glyph.
- Four tabs in the popover:
  - **My PRs** — PRs you authored
  - **Reviewing** — PRs where you (or a team you're a member of) are requested as reviewer. Reviewer pills show *why* you're on the list (`you` or `@team-slug`).
  - **Activity** — chronological log of every state transition, every action you took, and every failure (capped at 200 entries / 7 days). Click any row to open the PR.
  - **Worktrees** — every worktree this app manages, with clean / dirty / missing status.
- Search bar with **regex toggle**, **repo filter** (persists across launches), and **5 sort orders** (updated, PR # asc/desc, title A–Z, status priority).
- Inline-expandable check list per PR — every CI check or status context with deep links to wherever it ran (Buildkite, GitHub Actions, CircleCI, etc.).
- Refresh button shows a small red dot when one or more per-PR enrichments failed; hover for the count.

### Per-PR controls (right-click any row, or the ⋯ overflow menu)
- **Pin** — when any PR is pinned, only pinned PRs trigger notifications. Pinned PRs always sort to the top regardless of the chosen sort order.
- **Snooze** — 30 min / 2 hr / until tomorrow 9 AM. Suppresses notifications and auto-rebase. Live countdown on the row.
- **Auto-rebase** — when the PR is behind base, rebase silently. **If the PR is already behind when you turn this on, the rebase fires immediately** (instead of waiting for the next BEHIND transition). Notifies only on failure.
- **Auto-merge** — tries GitHub-native `enablePullRequestAutoMerge` first; if the repo doesn't allow it, falls back to **client-side auto-merge** (calls `mergePullRequest` from this app whenever the PR becomes ready). If the PR is already mergeable when you turn it on, GitHub merges immediately (or the client-side fallback does so explicitly).
- **Worktree** — create a worktree for the PR's branch under your configured root (default `~/worktrees/gitpilot`), open it in your editor, remove when done. Refuses to remove dirty worktrees without explicit confirmation.

### Notifications (native macOS)

All notifications are **edge-triggered**: one fire per state transition, deduped across app restarts so you don't get re-spammed about the same state every time you relaunch.

| Notification | Trigger | Action button |
|---|---|---|
| Rebase PR? | PR transitions to BEHIND | **Rebase** (calls `updatePullRequestBranch`) / Skip |
| Ready to merge | PR transitions to CLEAN + APPROVED | **Open PR** |
| CI failing | PR transitions to blocked-by-tests | **Open PR** |
| Merge conflict | PR transitions to dirty/conflicting | **Open PR** |
| Auto-rebase failed | Auto-rebase mutation errored | **Open PR** |
| Auto-merge failed | Auto-merge mutation errored / repo allows no methods / not mergeable at merge time | **Open PR** |
| Auto-merge complete | Client-side merge succeeded (opt-in) | **Open PR** |
| Rebase failed | Manual rebase button click failed (opt-in) | **Open PR** |
| Worktree operation failed | Create or remove worktree errored | **Open PR** |

When a PR has auto-merge enabled, the "Ready to merge" notification is **suppressed** — you opted into silent merging, so we don't ping you about something you've delegated.

When any PR is pinned, notifications fire **only** for pinned PRs.

When a PR is snoozed, notifications and auto-rebase are both suppressed. Expired snoozes are cleared at the start of each refresh (so the post-snooze refresh fires the right notification if state warrants).

### What gets recorded where (failure-state matrix)

Every meaningful event lands in the **Activity** tab. The activity row shows the PR title, an icon, the action label, and a `detail` line that wraps to 3 lines, is selectable for copy, and shows full text on hover. So even when an error message is long, the full text is reachable.

| Event | Activity entry | Notification | Toggle | Default |
|---|---|---|---|---|
| PR became behind base | `behind base` | ✓ Rebase PR? | Notify on rebase needed | on |
| PR became ready to merge | `ready to merge` | ✓ Ready to merge (suppressed if auto-merge on for that PR) | Notify when ready to merge | on |
| PR tests started failing | `tests failing` | ✓ CI failing | Notify on CI failure | on |
| PR became conflicted | `merge conflict` | ✓ Merge conflict | Notify on merge conflict | on |
| PR appeared in list | `appeared` | — | — | — |
| PR left list | `left list` | — | — | — |
| Manual rebase succeeded | `rebased` | — | — | — |
| Manual rebase failed | `rebase failed` | ✓ Rebase failed | Notify on manual rebase failure | **off** |
| Auto-rebase succeeded | `auto-rebased` | — | — | — |
| Auto-rebase failed | `auto-rebase failed` | ✓ Auto-rebase failed | Notify on auto-rebase failure | on |
| Auto-merge enabled | `auto-merge enabled` | — | — | — |
| Auto-merge disabled | `auto-merge disabled` | — | — | — |
| Auto-merge succeeded (client-side) | `merged` | ✓ Auto-merge complete | Notify when auto-merge completes | **off** |
| Auto-merge succeeded (server-side won race) | `merged` (server-side) | ✓ Auto-merge complete | Notify when auto-merge completes | **off** |
| Auto-merge failed (no method allowed) | `auto-merge failed` | ✓ Auto-merge failed | Notify on auto-merge failure | on |
| Auto-merge failed (not mergeable at merge time, drops flag) | `auto-merge failed` | ✓ Auto-merge failed | Notify on auto-merge failure | on |
| Auto-merge failed (generic error) | `auto-merge failed` | ✓ Auto-merge failed | Notify on auto-merge failure | on |
| Auto-merge GH-side disable failed (non-benign) | `auto-merge failed` | ✓ Auto-merge failed | Notify on auto-merge failure | on |
| Worktree create failed | `worktree create failed` | ✓ Worktree operation failed | Notify on worktree failure | on |
| Worktree remove failed | `worktree remove failed` | ✓ Worktree operation failed | Notify on worktree failure | on |
| Pin / Unpin | `pinned` / `unpinned` | — | — | — |
| Snooze / Unsnooze | `snoozed` / `snooze cancelled` | — | — | — |
| GitHub auth failure | — (auth banner shown instead) | banner | — | — |
| Persisted state save failed | — (settings banner shown instead) | banner in Settings | — | — |
| `gh` team-slug refresh failed | — (silent; only affects pill display) | — | — | — |
| `refreshReviewing` non-auth error | — (red error line at top of Reviewing tab) | — | — | — |
| Per-PR enrichment failed | — (red dot on refresh button + tooltip count) | — | — | — |

The "—" rows are intentionally silent: they're either successes (which would be noise to notify on every poll) or low-stakes background failures that have a different surface (banner, error line, tooltip).

### Settings reference

The Settings disclosure at the bottom of the menu exposes everything user-tunable. All settings persist atomically to disk and survive restarts.

| Setting | Default | Notes |
|---|---|---|
| **Poll interval** | 30s | 10s / 30s / 1m / 2m / 5m. Same interval is used for both the My PRs poll and the Reviewing-tab background poll. |
| **Notify on rebase needed** | on | Suppressed automatically when auto-rebase is on for that PR. |
| **Notify when ready to merge** | on | Suppressed automatically when auto-merge is on for that PR. |
| **Notify on CI failure** | on | |
| **Notify on merge conflict** | on | Conflicts require a local resolve. |
| **Notify on auto-rebase failure** | on | |
| **Notify on auto-merge failure** | on | Independent of auto-rebase failure since they're separate decisions. |
| **Notify when auto-merge completes** | **off** | Activity log already records every merge; opt-in if you specifically want closure. Only fires for client-side merges (GitHub-side merges happen server-side and the PR just disappears from the list). |
| **Notify on manual rebase failure** | **off** | When you click the inline Rebase button, the button itself gives contextual feedback. Opt in if you tend to walk away after clicking. |
| **Notify on worktree failure** | on | Covers both create and remove failures. |
| **Auto-merge method per repo** | Default → SQUASH > MERGE > REBASE among allowed | Per-repo override. Single-method repos render as a static label since there's nothing to override. |
| **Worktree root** | `~/worktrees/gitpilot` | Per-PR worktrees live at `<root>/<repo>/<branch>` (slashes in branch names become `__`). |
| **Editor** | Auto | Auto detects Cursor → VSCode → Sublime, falls back to Finder. Or pick one explicitly. |
| **Send test notification** | (button) | Fires every notification kind against a synthetic PR so you can verify the notification pipeline. The synthetic PR id never matches a real PR, so notification action buttons (Rebase, Open PR) safely no-op. |

A few non-toggle behaviors that are persisted but don't need explicit settings UI:
- **Repo filter** — the filter dropdown above the PR list persists across launches.
- **Tab selection** — the active tab (My PRs / Reviewing / Activity / Worktrees) persists across launches via UserDefaults.
- **Sort order** — the Sort picker in the filter row persists.
- **Pinned PR set / Snooze map / Auto-rebase set / Auto-merge set** — all persisted.
- **Worktree registry** — paths the app created and is responsible for cleaning up.
- **Activity log** — capped at 200 entries / 7 days (currently not user-tunable).
- **PR fetch limit** — paginates with no app-side cap up to a 1000-PR safety ceiling. If you have more, you'll see a warn-level log line.

If a save to disk fails, an inline orange banner appears at the top of the Settings disclosure with the error message. The banner persists until the next successful save (or you dismiss it manually).

### Under the hood
- Two-phase fetch: a fast list query followed by parallel per-PR enrichment for `mergeStateStatus` / review decision / CI rollup. Up to 32 concurrent connections.
- Pagination: both `viewer.pullRequests` and the Reviewing search query paginate with `first: 100` + cursor until exhausted (capped at 1000 for safety).
- Retries on GitHub's lazy `UNKNOWN` mergeStateStatus (0.5s → 1s → 2s, max 4 attempts per PR).
- Debounced atomic JSON persistence at `~/Library/Application Support/GitPilot/state.json` (250ms coalescing window), with a synchronous flush on app termination.
- Defensive Codable: `PersistedSettings` uses `decodeIfPresent` for every key, so adding new settings doesn't reset existing state files (Swift's synthesized decoder ignores property defaults).
- Auth via the `gh` CLI; explicit reauth banner with one-click retry on 401. Token cleared on 401 so the next call re-reads from `gh`.
- Hourly refresh of viewer team-membership for the Reviewing-tab pill filter.
- Spam-click protection: every async action button (rebase, auto-merge toggle, worktree create/remove, auth retry, send test notification) has an in-flight guard so a fast double-click can't queue duplicate work.

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

`GITPILOT_DEBUG=1` enables verbose timings (`Log.debug`). Without it, only `warn` and above print to stderr.

## Distribute

```bash
./scripts/package.sh           # writes dist/GitPilot-<version>.zip + .sha256
./scripts/package.sh 0.2.0     # override version
```

The bundle is ad-hoc code-signed. Recipients will see a Gatekeeper warning the first time they open it; right-click → Open clears it. To skip that, sign with a Developer ID Application cert and notarize via `xcrun notarytool submit`.

## Architecture

```
GitPilotApp.swift          SwiftUI app entry; menu bar surface + tab body
AppState.swift             Single owner of all UX policy: transitions, dedupe,
                           snooze, pin, auto-rebase, auto-merge, persistence
PRMonitor.swift            Pure fetcher with a 30s poll loop; emits per-PR
                           enrichment + list-settled events
GitHubClient.swift         GraphQL client over URLSession; paginated PR fetch;
                           auth via `gh auth token`
NotificationService.swift  Wraps UNUserNotificationCenter; routes action
                           button taps back to AppState
WorktreeManager.swift      git fetch + worktree add/remove via async Process
                           continuations
PersistedState.swift       JSON-on-disk schema + atomic debounced writes;
                           defensive decoder
TabContents.swift          Activity + Worktrees tabs
PRRowView.swift            PR row + inline check list
AuxViews.swift             Search bar, refresh button, pinned banner, auth
                           banner, settings disclosure
ViewHelpers.swift          Hover modifiers + button styles
Log.swift                  Stderr logger; debug gated by GITPILOT_DEBUG
```

PR list flow:
1. `PRMonitor.refresh()` calls `fetchMyOpenPRs` (paginated light list).
2. UI updates immediately so rows render with placeholder status.
3. `enrichPR` runs per PR in parallel; each result is applied as it arrives.
4. After each apply, `AppState.handle(prUpdated:)` decides whether to notify, auto-rebase, or auto-merge based on dedupe + snooze + pin + auto flags.
