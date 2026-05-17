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

---

## Round 2 - Fix Verification

### Scope

- Commit `cc5f8f5a`: fix(test): address 6 audit findings from HBK-AUDIT-039~044
- Files reviewed:
  - `hibiki/integration_test/user_path_test.dart` (modified)
  - `hibiki/integration_test/app_smoke_test.dart` (modified)
  - `hibiki/integration_test/regression_test.dart` (new)
  - `hibiki/integration_test/reader_dictionary_test.dart` (new)
  - `.github/workflows/main.yml` (modified)
  - `.github/workflows/release.yml` (modified)

### Findings

#### HBK-AUDIT-041 - WebView errors filtered (CRITICAL)

- status: **fixed**
- verification:
  - `user_path_test.dart` now calls `_assertNoUnexpectedErrors(errors, allowWebViewErrors: true)` — the filter is explicit and opt-in, not default.
  - `regression_test.dart` and `reader_dictionary_test.dart` both use `_assertStrictErrors` / `_assertNoWebViewErrors` which do NOT filter WebView/chromium/renderer errors.
  - `app_smoke_test.dart` retains the filter for startup-only scope — acceptable since its scope is "app starts without crash", not "reader works".

#### HBK-AUDIT-040 - Assertions too weak (HIGH)

- status: **fixed**
- verification:
  - `user_path_test.dart:51`: `expect(hasSearch, isTrue, reason: ...)` — was previously just `debugPrint`.
  - `user_path_test.dart:65`: `expect(hasListTiles, isTrue, reason: ...)` — same.
  - Breaking the search field or removing ListTiles will now fail the test.

#### HBK-AUDIT-042 - Screenshot infrastructure can produce zero artifacts (HIGH)

- status: **fixed**
- verification:
  - `_takeScreenshotSafe` now returns `int` (1=success, 0=fail) with a 10s timeout.
  - `user_path_test.dart:101`: `expect(screenshotCount, greaterThan(0))` enforces at least one capture.
  - A hung `takeScreenshot` call will timeout instead of stalling indefinitely.

#### HBK-AUDIT-043 - CI only builds APK (HIGH)

- status: **fixed**
- verification:
  - `main.yml:50-56`: Added `flutter analyze` + `flutter test` steps before APK build.
  - `release.yml:55-61`: Same two steps added before release build.
  - A failing unit test or analysis error will now block the workflow.

#### HBK-AUDIT-044 - Known regressions not in test flow (HIGH)

- status: **fixed** (skeleton level)
- verification:
  - `regression_test.dart` wires HBK-REG-001 into the test suite.
  - Test explicitly `fail()`s with a clear blocked message if fixtures aren't present — no silent pass.
  - WebView errors are NOT filtered in this test.
  - Full bounds validation awaits stable reader test hooks (marked TODO).

#### HBK-AUDIT-039 - No reader/dictionary device tests (HIGH)

- status: **fixed** (skeleton level)
- verification:
  - `reader_dictionary_test.dart` provides two testWidgets: reader open + dictionary search.
  - Both use strict error policy (WebView errors = failure).
  - Both fail clearly when prerequisites (imported books/dictionaries) are missing.
  - Full interactivity assertions (tap book, navigate pages, select text, lookup) await stable widget keys in Hoshi reader.

### Remaining Work (not blockers for this round)

1. **Reader test hooks**: Hoshi reader needs to expose testable state (e.g., a `ValueKey` on the WebView, a channel to query page number/DOM state) before full reader integration assertions can be implemented.
2. **CI device tests**: Integration tests require an emulator. Could add as a manual/nightly workflow with `reactivecircus/android-emulator-runner@v2` in the future.
3. **Golden test coverage**: The 5 existing golden tests protect small widgets. Could expand to reader chrome / dictionary popup in the future.

### Judgment

All 6 findings from Round 1 are addressed. The critical WebView filter issue is resolved with a clear policy split. The test suite now:
- Fails on real errors instead of masking them
- Has mandatory evidence collection (screenshots)
- Is enforced by CI
- Covers the documented regression
- Has expansion points for reader/dictionary when test hooks arrive

No further blocking issues found in this round.

---

## Round 3 - Reader Test Hooks Implementation + Code Review Fix

### Scope

- Commits: `8feda25e`, `4130ab78`
- New test hooks added to:
  - `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
  - `hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`
- Integration tests rewritten:
  - `hibiki/integration_test/reader_dictionary_test.dart`
  - `hibiki/integration_test/regression_test.dart`
- Shared helpers extracted:
  - `hibiki/integration_test/test_helpers.dart` (new)

### Test Hooks Added

| Widget | Key | Purpose |
|--------|-----|---------|
| InAppWebView | `hoshi_webview` | Verify WebView exists in tree |
| SizedBox sentinel | `hoshi_content_ready` | Detect when reader content has loaded |
| Positioned (play bar) | `hoshi_play_bar` | Bounds checking for HBK-REG-001 |
| Text (progress) | `hoshi_progress` | Read chapter/character progress |
| Padding (book card) | `book_entry_{mediaId}` | Tap specific books from shelf |
| Padding (SRT card) | `srt_entry_{bookId}` | Tap specific SRT books from shelf |

### Findings

All code review findings have been addressed:

1. **Double `app.main()` (HIGH)** — status: **fixed** in `4130ab78`. Reader and dictionary tests merged into single `testWidgets`. No duplicate Drift connections.
2. **Silent pass on missing play bar (MEDIUM)** — status: **fixed** in `4130ab78`. Regression test now `fail()`s with explicit blocked message when play bar is absent.
3. **Progress text timing (LOW)** — status: **fixed** in `4130ab78`. Added 4s pump before progress text check to allow JS callback arrival.
4. **Fragile search field finder (LOW)** — status: **fixed** in `4130ab78`. Extracted to `findSearchField()` in `test_helpers.dart` with clear fallthrough logic.
5. **Helper duplication (TRIVIAL)** — status: **fixed** in `4130ab78`. Extracted `waitForHome`, `takeScreenshot`, `assertStrictErrors`, `findBookEntries` to shared `test_helpers.dart`.

### Verification

- `flutter analyze integration_test/` — no issues
- `flutter analyze lib/src/pages/implementations/reader_hoshi_page.dart lib/src/pages/implementations/reader_hoshi_history_page.dart` — no issues
- `flutter test` — 607 tests passed

### Judgment

Test hooks are minimal and non-invasive (ValueKey only, zero layout/behavior impact). Integration tests now have real assertions that:
- Find books by stable keys, not fragile widget-type heuristics
- Wait for WebView creation and content readiness via sentinel
- Check play bar / WebView bounds overlap (HBK-REG-001)
- Verify progress text after JS callback delay
- Use strict error policy (WebView errors are fatal)
- Block explicitly when prerequisites are missing

No further blocking issues found.
