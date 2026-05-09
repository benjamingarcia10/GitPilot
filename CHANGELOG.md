# Changelog

## [0.2.0](https://github.com/benjamingarcia10/GitPilot/compare/v0.1.2...v0.2.0) (2026-05-09)


### Features

* app icon, fixed reviewing-tab loop, hourly team-slug refresh ([4137181](https://github.com/benjamingarcia10/GitPilot/commit/41371814bc941730cbe1ac35c12d575a0ec5713f))
* comprehensive failure-state coverage + auto-merge UX fixes ([ffa1f13](https://github.com/benjamingarcia10/GitPilot/commit/ffa1f13a391603561c07fc81088fd91d436b4d47))
* comprehensive failure-state coverage + immediate-fire auto toggles + pagination ([f044395](https://github.com/benjamingarcia10/GitPilot/commit/f04439571c97742ee38db0f37a8e25c7f8cc9935))
* dedicated Settings window (⌘,) replacing the popover disclosure ([91ba20b](https://github.com/benjamingarcia10/GitPilot/commit/91ba20b40084d533806839974a253c85dcaaedf2))
* explicit auth status with reauth banner ([4177319](https://github.com/benjamingarcia10/GitPilot/commit/4177319fd88a768bd7eec725861dd6d66d4d3116))
* install.sh reports gh CLI install + auth status ([647173a](https://github.com/benjamingarcia10/GitPilot/commit/647173ac556812f5e2b8cf56d00a7e24f849c2a5))
* persistence, pin/snooze/auto-rebase/auto-merge, inline checks, polish ([afd2cd5](https://github.com/benjamingarcia10/GitPilot/commit/afd2cd577d2bcaa07dd4b0d018901b8520f4b781))
* progressive PR loading and idempotent bootstrap ([1b25384](https://github.com/benjamingarcia10/GitPilot/commit/1b25384fb22f4a5684eadfa46f2b37da547bf05b))
* repo filter dropdown in menu bar ([b9c6ea1](https://github.com/benjamingarcia10/GitPilot/commit/b9c6ea159d33fc90ee89121f30e6697b33d4403e))
* scripts/package.sh for distribution + collapse single-method repo rows ([59f68a9](https://github.com/benjamingarcia10/GitPilot/commit/59f68a9360e0c87c8cb5dc0c923e86ee237b32c3))
* search bar with regex toggle ([5843853](https://github.com/benjamingarcia10/GitPilot/commit/5843853370d7ae76ef195f6a6625e329cad46308))
* Sparkle auto-update + GitHub Actions release pipeline + curl install ([c6d499a](https://github.com/benjamingarcia10/GitPilot/commit/c6d499af2f20a21ee16ce332adcc0df2566f9392))
* spinning refresh button with disabled-while-refreshing ([8bde2ed](https://github.com/benjamingarcia10/GitPilot/commit/8bde2ed6da85941b4ed3c3ab5af95702f272bd90))
* tabs (My PRs / Reviewing / Activity / Worktrees) + diff size ([a0d1275](https://github.com/benjamingarcia10/GitPilot/commit/a0d1275e068d8952133e54c187642387a4f3277c))


### Bug Fixes

* 5 latent bugs + post-rebase refresh deadlock ([7584b45](https://github.com/benjamingarcia10/GitPilot/commit/7584b455657f01517cf055eb9270b404b6613cc3))
* detect arm64 hardware via sysctl, not uname -m ([4fe3602](https://github.com/benjamingarcia10/GitPilot/commit/4fe360299ab24d8039f54bb9fd6ff2e2ac52c7af))
* hide CFBundleVersion from Settings, expose on hover ([a6e3b64](https://github.com/benjamingarcia10/GitPilot/commit/a6e3b6490323990c74c3ed7838994349a444ad6b))
* live-updating 'Updated Xs ago' label ([5c62cde](https://github.com/benjamingarcia10/GitPilot/commit/5c62cdeaa502475ab6fa5b2080a07eac1565e204))
* release.yml parse error blocked release event from firing ([50f268a](https://github.com/benjamingarcia10/GitPilot/commit/50f268ac664671026ec964b8a8968028011fa10f))
* row layout with title on its own line, atomic log writes ([76da17c](https://github.com/benjamingarcia10/GitPilot/commit/76da17c69df1bdb336242ed8c28c8272ec4595dd))
* Settings caption text spans full width ([c819505](https://github.com/benjamingarcia10/GitPilot/commit/c819505b2f4197140d340b515d1b8b30fee7fabf))
* Settings footer text now spans full section width ([4ef5aba](https://github.com/benjamingarcia10/GitPilot/commit/4ef5abaa4c4d5b7c7f107883d800ad0e882ec203))
* subprocesses inherit Homebrew PATH after Sparkle relaunch ([6813317](https://github.com/benjamingarcia10/GitPilot/commit/6813317c26cda9dbc37937cca5cc5e1444d5dbb7))
* valid release-please draft key + PAT for downstream trigger ([c56596f](https://github.com/benjamingarcia10/GitPilot/commit/c56596f241baa190df574c1d7f03e9b1c08a16eb))


### Performance

* batched PR enrichment via nodes(ids:) to avoid secondary rate limits ([0bb325c](https://github.com/benjamingarcia10/GitPilot/commit/0bb325c944efea595b90e0ac08834730edd918d8))
* parallelize PR enrichment, wrap titles ([b7d77e6](https://github.com/benjamingarcia10/GitPilot/commit/b7d77e6d30926c6f8eb86aff0b71c5502c99db5e))


### Refactors

* code review round 1 — concurrency, dedup, safety fixes ([0670f86](https://github.com/benjamingarcia10/GitPilot/commit/0670f86a8109899aab59879af69f49a5d3407207))
* code review round 2 — diagnostics, log levels, dedup ([8b29e03](https://github.com/benjamingarcia10/GitPilot/commit/8b29e0307760beae172b9f8c923600a3e2d199bf))
* code review round 3 — real bug fixes from second-pass review ([df6f227](https://github.com/benjamingarcia10/GitPilot/commit/df6f227afec9c6598f20d9b0611ff96e1e7eb56f))
* split GitPilotApp.swift into focused view files ([8ebe7fa](https://github.com/benjamingarcia10/GitPilot/commit/8ebe7faeaba5aef5caac6a77901369e3415d5045))


### Documentation

* refresh WorktreeManager type-doc to match async API contract ([df8b58c](https://github.com/benjamingarcia10/GitPilot/commit/df8b58c7565ac9e6d0d14d3940b7a0a90708916a))

## [0.1.2](https://github.com/benjamingarcia10/GitPilot/compare/v0.1.1...v0.1.2) (2026-05-09)


### Bug Fixes

* Settings caption text spans full width ([c819505](https://github.com/benjamingarcia10/GitPilot/commit/c819505b2f4197140d340b515d1b8b30fee7fabf))
* subprocesses inherit Homebrew PATH after Sparkle relaunch ([6813317](https://github.com/benjamingarcia10/GitPilot/commit/6813317c26cda9dbc37937cca5cc5e1444d5dbb7))
* valid release-please draft key + PAT for downstream trigger ([c56596f](https://github.com/benjamingarcia10/GitPilot/commit/c56596f241baa190df574c1d7f03e9b1c08a16eb))

## [0.1.1](https://github.com/benjamingarcia10/GitPilot/compare/v0.1.0...v0.1.1) (2026-05-08)


### Bug Fixes

* detect arm64 hardware via sysctl, not uname -m ([4fe3602](https://github.com/benjamingarcia10/GitPilot/commit/4fe360299ab24d8039f54bb9fd6ff2e2ac52c7af))
* hide CFBundleVersion from Settings, expose on hover ([a6e3b64](https://github.com/benjamingarcia10/GitPilot/commit/a6e3b6490323990c74c3ed7838994349a444ad6b))
* release.yml parse error blocked release event from firing ([50f268a](https://github.com/benjamingarcia10/GitPilot/commit/50f268ac664671026ec964b8a8968028011fa10f))
* Settings footer text now spans full section width ([4ef5aba](https://github.com/benjamingarcia10/GitPilot/commit/4ef5abaa4c4d5b7c7f107883d800ad0e882ec203))
