# 2026-05-17 Project Review

## Round 1 - Test Suite And Test Process Audit

### Scope

- Reviewed commits: `fbdb0e12`, `2d5f51e7`, `ede9c7a2`.
- Reviewed files:
  - `hibiki/integration_test/app_smoke_test.dart`
  - `hibiki/integration_test/user_path_test.dart`
  - `hibiki/test_driver/integration_test_screenshots.dart`
  - `hibiki/test/goldens/*`
  - `.github/workflows/main.yml`
  - `.github/workflows/release.yml`
  - `melos.yaml`
  - `docs/REGRESSION_BUGS.md`
  - `docs/superpowers/plans/2026-05-16-test-expansion.md`

### Findings

#### HBK-AUDIT-039 - Integration test coverage misses the workflows users actually depend on

- severity: HIGH
- status: open
- files:
  - `docs/superpowers/plans/2026-05-16-test-expansion.md:26`
  - `docs/superpowers/plans/2026-05-16-test-expansion.md:27`
  - `hibiki/integration_test/user_path_test.dart:18`
  - `hibiki/integration_test/app_smoke_test.dart:11`
- root cause: The implemented device tests cover startup, tab tapping, scrolling and rapid tab switching. The plan explicitly listed an EPUB reader integration test, but there is no `integration_test/epub_reader_test.dart`. The test suite never imports a real EPUB through DocumentsUI, never opens the Hoshi reader, never validates WebView content, never checks dictionary lookup, and never exercises audiobook playback/cue following.
- impact: The current "device verified" claim does not protect the highest-risk Hibiki paths: import, reader rendering, restore, WebView resource loading, dictionary media, and audiobook layout. A build can pass all new tests while the real reader is blank, overlapped by the play bar, or unable to load imported content.
- fix: Add device tests for the minimum user-critical flows: real DocumentsUI EPUB import using `.codex-test/fixtures`, open Hoshi reader, assert `window.hoshiReader` state via WebView/DevTools or app-exposed test hook, navigate chapter/page, dictionary lookup from text selection, and audiobook play/next/follow cue with layout bounds.
- verification: Run the new integration targets on the emulator with preserved app data and with a clean app-data variant. Save APK path, device serial/ABI, pushed fixture sizes, screenshots, UI XML, logcat excerpts, and Hoshi DOM/layout bounds under `.codex-test/`.

#### HBK-AUDIT-040 - Integration tests mostly assert that a Scaffold exists

- severity: HIGH
- status: open
- files:
  - `hibiki/integration_test/user_path_test.dart:36`
  - `hibiki/integration_test/user_path_test.dart:43`
  - `hibiki/integration_test/user_path_test.dart:47`
  - `hibiki/integration_test/user_path_test.dart:57`
  - `hibiki/integration_test/user_path_test.dart:61`
  - `hibiki/integration_test/user_path_test.dart:77`
  - `hibiki/integration_test/app_smoke_test.dart:36`
  - `hibiki/integration_test/app_smoke_test.dart:65`
- root cause: The tests use generic framework widgets as success criteria. `hasSearch` and `hasListTiles` are only printed, not asserted. Settings is skipped if the third icon is missing. A page that renders the wrong tab, an error scaffold, or an empty placeholder can still satisfy these checks.
- impact: These are smoke tests, not user-path tests. They catch only catastrophic startup failure and miss broken navigation content, missing search UI, failed settings rendering, empty library states that should show actionable UI, and tab state regressions.
- fix: Use stable semantic keys/labels for tabs and page roots. Assert selected tab identity, expected page-specific controls, expected empty-state copy/actions, and post-navigation state. Convert the logged booleans into failing assertions where the UI is required.
- verification: Temporarily break the Dictionary search field or Settings list root and confirm the integration test fails. Then restore the UI and confirm the test passes.

#### HBK-AUDIT-041 - WebView and renderer failures are filtered out of device tests

- severity: CRITICAL
- status: open
- files:
  - `hibiki/integration_test/user_path_test.dart:147`
  - `hibiki/integration_test/user_path_test.dart:150`
  - `hibiki/integration_test/user_path_test.dart:151`
  - `hibiki/integration_test/app_smoke_test.dart:68`
  - `hibiki/integration_test/app_smoke_test.dart:72`
  - `hibiki/integration_test/app_smoke_test.dart:73`
- root cause: The error filters classify `webview`, `chromium`, and `renderer crash` as ignorable. That might reduce emulator noise, but it also removes the exact failure class that Hibiki's current reader, dictionary popup, resource interception and Hoshi rendering depend on.
- impact: A WebView renderer crash can be reported as a passing test. That is not "graceful"; it is blindfolding the test runner. For Hibiki, WebView failure is app failure unless the test is explicitly scoped to a feature that never touches WebView.
- fix: Split error policy by test scope. Startup smoke tests may allow documented transient network errors, but reader/dictionary tests must fail on WebView, Chromium, renderer, JavaScript and resource-loading errors. If an emulator has a known platform bug, mark that test blocked with evidence instead of converting it into pass.
- verification: Inject or reproduce a controlled WebView error in a reader test and verify the test fails with the captured logcat/FlutterError evidence.

#### HBK-AUDIT-042 - Screenshot infrastructure can produce zero artifacts while tests pass

- severity: HIGH
- status: open
- files:
  - `hibiki/integration_test/user_path_test.dart:31`
  - `hibiki/integration_test/user_path_test.dart:137`
  - `hibiki/integration_test/user_path_test.dart:140`
  - `hibiki/integration_test/user_path_test.dart:142`
  - `hibiki/test_driver/integration_test_screenshots.dart:5`
  - `hibiki/test_driver/integration_test_screenshots.dart:8`
- root cause: `_takeScreenshotSafe()` catches screenshot failures and continues. It has no timeout around `binding.takeScreenshot()`, so an API-level hang can stall the test instead of failing cleanly. The custom screenshot driver writes files only when the test is run through that driver path, but the current summary does not prove that artifact path was used or that PNG files exist.
- impact: Phase 3 can claim screenshot infrastructure while generating no screenshots. For layout regressions, especially reader/play-bar overlap, a passing run without screenshot, UI XML, logcat and bounds evidence is not useful.
- fix: Make screenshot collection a first-class artifact contract. Use a timeout, return a structured skipped/failed reason, and fail layout-sensitive tests when required evidence is missing. For emulator paths where Flutter surface capture is broken, fall back to `adb exec-out screencap`, UI Automator XML, and WebView bounds/DOM extraction.
- verification: Run the integration test once with screenshot support available and assert PNG files are written. Run once on the API 35 emulator and assert the fallback captures `.codex-test/*.png` plus `.xml`, or marks the screenshot check blocked rather than passed.

#### HBK-AUDIT-043 - CI builds APKs but does not run the test suite

- severity: HIGH
- status: open
- files:
  - `.github/workflows/main.yml:41`
  - `.github/workflows/main.yml:50`
  - `.github/workflows/release.yml:55`
  - `.github/workflows/release.yml:64`
  - `melos.yaml:17`
- root cause: `main.yml` performs `flutter pub get`, applies patches, then builds a debug APK. `release.yml` builds release APKs. Neither workflow runs `flutter test`, golden tests, integration tests, `melos run test`, or even `dart analyze`. `melos.yaml` defines a test script, but CI does not use it.
- impact: The new tests are optional local ceremony. A PR can merge with unit/golden failures. A release can be cut without running the regression suite. This is a process hole, not a tooling detail.
- fix: Add CI jobs for `flutter test`, golden test verification, and `dart analyze` at minimum. Keep Android build as a separate job. Device integration tests can be nightly/manual if GitHub-hosted emulator time is too expensive, but release gating must require a recorded local/device run for reader-sensitive changes.
- verification: Open a PR with a deliberately failing unit test in a scratch branch and confirm CI blocks it. Confirm release workflow runs the non-device test suite before building APKs.

#### HBK-AUDIT-044 - Known open regressions are not wired into the new test process

- severity: HIGH
- status: open
- files:
  - `docs/REGRESSION_BUGS.md:12`
  - `docs/REGRESSION_BUGS.md:18`
  - `docs/REGRESSION_BUGS.md:32`
  - `hibiki/integration_test/user_path_test.dart:18`
- root cause: `docs/REGRESSION_BUGS.md` has an open reader/audiobook overlap regression with exact fixture paths and repro steps, but the new device test only switches top-level tabs. There is no test or checklist enforcement that open regression items must be re-run before claiming device verification.
- impact: The test expansion ignores the only documented open regression. That is backwards: regression tests must start with bugs that already escaped. Otherwise "20 golden tests + 1 integration test" inflates the count while leaving the known failure untouched.
- fix: Turn every `open` regression entry into either an automated test target or a required manual verification checklist with evidence paths. For HBK-REG-001, add a reader/audiobook layout check that imports the Kagami fixture, opens the reader with the play bar visible, records WebView/content/play-bar bounds, and fails if readable content extends under the controls.
- verification: Re-run HBK-REG-001 on the target APK. Update `docs/REGRESSION_BUGS.md` only with fresh screenshot/UI XML/bounds evidence, and keep status `open` until both visual and bounds checks pass.

### Key Judgment

- Golden tests: useful but narrow. They protect five small widgets, not Hibiki's risky behavior.
- Device tests: currently smoke-level. Calling them "full user path" is misleading.
- Screenshot infrastructure: not reliable as verification unless artifacts are mandatory and fallback capture exists.
- Process: CI does not enforce the tests, and open regressions are not part of the runbook.

### Next Scope

- Audit actual reader/Hoshi testability hooks and decide where to expose stable state for integration tests.
- Convert HBK-REG-001 into a repeatable device verification path with required `.codex-test/` artifacts.
- Review whether generated files and local dirty changes are being produced by the test/build flow and whether they need cleanup rules.
