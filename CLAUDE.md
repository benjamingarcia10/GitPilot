# CLAUDE.md

Project-level guidance for Claude Code in this repo. Loaded automatically into every conversation.

## What this is

GitPilot — a macOS menu bar app that watches your GitHub PRs and notifies you when one needs attention. Single-author personal project; ad-hoc-signed (no paid Apple Developer ID); arm64-only Apple Silicon; ships via Sparkle for in-app updates.

## Commit conventions

This repo uses **Conventional Commits**. `.github/workflows/release-please.yml` parses commit prefixes to derive semver bumps and auto-generate the changelog. Getting the prefix right is the *only* thing that determines whether your work shows up in the next release notes.

### Prefix → bump → changelog section

We're pre-1.0, so `bump-minor-pre-major: true` is set — breaking changes bump *minor* (not major) until we explicitly graduate to 1.0.

| Prefix | Pre-1.0 bump | Changelog section |
|---|---|---|
| `feat:` | minor (0.1.0 → 0.2.0) | **Features** |
| `fix:` | patch (0.1.0 → 0.1.1) | **Bug Fixes** |
| `feat!:` or `BREAKING CHANGE:` footer | minor (capped by `bump-minor-pre-major`) | **Features** with `!` marker |
| `perf:` | none | **Performance** |
| `refactor:` | none | **Refactors** |
| `docs:` | none | **Documentation** |
| `chore:` / `build:` / `ci:` / `test:` / `style:` | none | hidden |

If a release range contains both `feat:` and `fix:` commits, the higher bump wins (minor).

### Rules for writing commits

- Always lead with a Conventional-Commit prefix followed by a colon and a short imperative summary: `feat: add foo`, not `Add foo` or `Adding foo`.
- One *type* per commit. Don't bundle a `feat:` and a `fix:` into one commit — release-please treats it as a single `feat:` and the fix gets miscategorized.
- Body and footers optional. Use the body to explain *why*; release-please surfaces the title only.
- For breaking changes, prefer the `!` form (`feat!: rename foo to bar`) over a `BREAKING CHANGE:` footer — both work, but `!` is more discoverable in `git log --oneline`.
- **Never include `Co-Authored-By: Claude` or any AI co-author trailer.** This is a personal/published project; commits should read as the author's own. The repo's git config strips these by default; don't re-add them.
- Don't squash unrelated changes into one commit — the changelog quality is exactly as good as commit hygiene.

### Examples

✓ Good:
```
feat: Sparkle auto-update + GitHub Actions release pipeline
fix: prevent race in post-rebase refresh
perf: batched PR enrichment via nodes(ids:) to avoid secondary rate limits
chore: bump Sparkle to 2.9.1
```

✗ Bad:
```
update stuff                                    ← no prefix → not in changelog
feat: add updates AND fix the race              ← two types in one commit
fix(critical)!: typo                            ← `!` forces a breaking-change bump for a typo
WIP                                             ← no prefix, no value to a user
```

### Manual version override

To force a specific version on the next release (skipping the auto-derived one), add a footer to any commit on `main`:

```
feat: do the thing

Release-As: 0.5.0
```

The next release-please PR will use `0.5.0` instead of the computed bump.

## Release flow

Two-stage pipeline:

1. **`release-please`** (`.github/workflows/release-please.yml`) — runs on every push to `main`. Maintains an open PR titled `chore(main): release vX.Y.Z` whose body is the auto-generated changelog. Updates `CHANGELOG.md` and `.release-please-manifest.json` as part of the PR.
2. **Merge the release PR** — release-please tags `vX.Y.Z` and creates a **draft** GitHub Release (because `release-as-draft: true` is set in the config).
3. **Edit the draft body** in the GitHub UI — paste polished prose, screenshots, install instructions. Your edits aren't overwritten by anything.
4. **Click "Publish release"** — fires `.github/workflows/release.yml` (the existing build pipeline). That workflow builds the bundle, ad-hoc-signs it, ed25519-signs the zip, uploads to the release, prepends an `<item>` to `appcast.xml`, and commits the appcast back to `main`.
5. Existing users on older versions see the Sparkle update prompt within 24h (or immediately on manual check from Settings → Updates).

### Editing release prose

You have two places you can shape what users see:

- **CHANGELOG.md on the release PR** (before merge): structured changelog. Edits *outside* the `<!-- release-please-... -->` markers persist; edits *inside* are regenerated. Add a "Highlights" section above the auto-generated `### Features` block to add custom prose.
- **Draft release body in the GitHub UI** (after merge, before publish): free-form. Best for screenshots, marketing copy, install commands. The Sparkle prompt embeds the *published* HTML at build time, so the draft body becomes what users see in the in-app update prompt forever after.

## Sparkle / distribution

- **Public key**: `scripts/sparkle-public-key.txt` — committed, embedded into bundles by `scripts/build-app.sh` as `SUPublicEDKey`.
- **Private key**: lives in the maintainer's macOS Keychain *and* in the GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY`. **Do not regenerate.** Running `scripts/sparkle-keys.sh` on a different machine generates a *new* keypair, which would invalidate every previously shipped release's signature and brick auto-update for existing users.
- **Appcast**: `appcast.xml` at the repo root, served via `https://raw.githubusercontent.com/benjamingarcia10/GitPilot/main/appcast.xml`. CI prepends a new `<item>` on every release.
- **Update flow**: in-app via Sparkle 2.x. EdDSA-signed; Sparkle verifies the signature against the embedded public key before installing.
- **Code signing**: ad-hoc only (`codesign --sign -`). No `--options=runtime` (would require notarization). Switch to Developer ID + notarization if going paid.

## Build / dev

| Command | Purpose |
|---|---|
| `swift run gitpilot` | Debug build, ~1s incremental. Action buttons don't work without a bundle. |
| `./scripts/build-app.sh` | Full `.app` bundle. Open `GitPilot.app` to test. |
| `./scripts/dev.sh` | Recommended dev loop: watch + rebuild + relaunch + tee logs. |
| `./scripts/test-update.sh` | Local Sparkle rehearsal — full update flow against a local HTTP server. |
| `./scripts/package.sh [VERSION]` | Build + zip for distribution. |
| `GITPILOT_DEBUG=1` | Verbose log timings. |

## Things to avoid

- **Co-author trailers** — never add `Co-Authored-By:` lines (Claude, anyone).
- **Regenerating Sparkle keys** — would invalidate every shipped release.
- **Committing secrets** — private keys, GH tokens. The private Sparkle key only lives in your Keychain + the GH secret.
- **`cp -R` for `.app` bundles** — use `ditto`. Symlinks inside `Sparkle.framework/Versions/` will be flattened by `cp -R` on some configs and break the framework's signature.
- **Hardcoding x86_64** — only arm64 ships. The release workflow runs on `macos-14` which is arm64-only.
- **Long block comments / multi-paragraph docstrings** — one short line max where the *why* isn't obvious. Don't explain *what*; identifiers do that.

## Architecture invariants

- All UX policy lives in `Sources/GitPilot/AppState.swift`. Per-PR controls (pin, snooze, auto-rebase, auto-merge) gate notifications and auto-actions there, not in `PRMonitor` or `NotificationService`.
- Notifications are **edge-triggered** — one fire per state transition, deduped across app restarts via `PersistedState`.
- Persistence is debounced (250ms) but synchronously flushed on app termination (`TerminationObserver` in `GitPilotApp.swift`).
- The Sparkle updater is initialized on the main actor in `UpdateController.init` — Sparkle uses AppKit and `NSUserDefaults` from `init`, both main-thread-only. Off-main init crashes.
- Two-phase fetch: fast list query, then parallel per-PR enrichment. Up to 32 concurrent connections (`GitHubClient`).
