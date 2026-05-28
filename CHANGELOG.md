# Changelog

## [0.3.0](https://github.com/benjamingarcia10/GitPilot/compare/v0.2.0...v0.3.0) (2026-05-28)


### Features

* notify when GitHub auth fails and PR tracking pauses ([9a0e600](https://github.com/benjamingarcia10/GitPilot/commit/9a0e60086ef9c8edf8c2099631a41593d53edecd))


### Bug Fixes

* retry GraphQL once with a fresh gh token on 401 ([796a3ce](https://github.com/benjamingarcia10/GitPilot/commit/796a3ce37bcbf3076fefe01776d929e5d38d57ff))

## [0.2.0](https://github.com/benjamingarcia10/GitPilot/compare/v0.1.3...v0.2.0) (2026-05-15)


### Features

* pull Settings window to active Space + front on open ([90789b5](https://github.com/benjamingarcia10/GitPilot/commit/90789b55507a2f32e5b7051118cc4fcb3b6fa503))

## [0.1.3](https://github.com/benjamingarcia10/GitPilot/compare/v0.1.2...v0.1.3) (2026-05-13)


### Bug Fixes

* dedupe paginated PR lists to prevent Dictionary crash ([0fb631c](https://github.com/benjamingarcia10/GitPilot/commit/0fb631ce4b619e9ef328e097f4b6cf2694cdc77e))
* drop pin entries when PRs disappear from the list ([8d99a44](https://github.com/benjamingarcia10/GitPilot/commit/8d99a444d2f69361eb888bd50f25a7c083306935))
* hold Rebase button in "Rebasing…" through post-mutation refresh ([c290142](https://github.com/benjamingarcia10/GitPilot/commit/c2901423ea7293b7b67fa084db14013f01ea0356))

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
