# Hibiki Comprehensive Test Automation Plan

> status: reviewed-round-1
> date: 2026-06-01
> scope: Android / Windows / macOS automated test flow for import, settings, sync, reader pagination, and reader lookup.

## Goal

Build one complete, reviewable automation flow that can run the same Hibiki test matrix on Android, Windows, and macOS. The flow must cover dictionary import/search, custom font import/application, sync settings and local sync paths, book import/open, reader pagination, reader lookup after page turns, and settings controls with real post-change assertions.

## Core Judgment

Worth doing. The current test flow has useful pieces, but the data model is wrong: targets are scattered across shell scripts and integration tests, so coverage drifts. The fix is not another pile of platform-specific scripts. The fix is one shared test matrix with platform adapters and explicit assertions.

## Existing Evidence

- `ci/integration-test.sh` already runs Android emulator integration targets and provisions AnkiDroid plus dictionary fixtures.
- `hibiki/integration_test/settings_validation_test.dart` toggles Switch widgets and checks persistence for one switch per page, but it only counts segmented buttons and does not exercise all segmented buttons, sliders, steppers, or picker rows.
- `hibiki/integration_test/reader_pagination_test.dart` already verifies Hoshi pagination invariants through a JS harness.
- `hibiki/integration_test/reader_dictionary_test.dart` already seeds a dictionary and book, opens Hoshi, and verifies dictionary search.
- `.codex-test/fixtures/` already contains minimal dictionary fixtures and the large Kagami EPUB/M4B/SRT regression sample.
- There is no closer `AGENTS.md` below the repo root, so root rules apply.

## Architecture

Use a small Dart test-flow model as the single source of truth. Shell/PowerShell entrypoints call the Dart runner instead of duplicating the matrix.

Files:

- Create `hibiki/tool/test_flow/comprehensive_test_matrix.dart`
  - Owns platform names, scenario names, command groups, required fixtures, expected assertions, and evidence requirements.
  - Has no Flutter runtime dependency so unit tests can validate the matrix quickly.

- Create `hibiki/tool/comprehensive_test_runner.dart`
  - CLI entrypoint.
  - Supports `--platform android|windows|macos|all`, `--only scenario1,scenario2`, `--dry-run`, and `--report-dir`.
  - Writes Markdown and JSON reports under `.codex-test/comprehensive/<timestamp>/`.
  - Marks macOS as `blocked` when not running on macOS and tells the user to run the same command on macOS.

- Create `hibiki/tool/generate_test_fixtures.dart`
  - Creates or refreshes deterministic fixture files under `.codex-test/fixtures/`.
  - Generates a tiny Yomitan dictionary ZIP with known lookup terms.
  - Copies a real platform font into a stable `test-font` fixture when a system font is available; otherwise reports the font fixture as blocked rather than faking it.

- Create `hibiki/test/integration/comprehensive_test_matrix_test.dart`
  - Failing tests first, then implementation.
  - Verifies every platform has dictionary, font, sync, book import/open, pagination, page-turn lookup, and settings-effect scenarios.
  - Verifies every scenario has assertions and evidence requirements.
  - Verifies macOS is not silently treated as passed on non-macOS hosts.

- Modify `ci/integration-test.sh`
  - Keep the existing Android emulator runner.
  - Add `comprehensive_settings`, `comprehensive_imports`, and `comprehensive_reader_lookup` targets after the Dart/integration tests exist.
  - Keep emulator-only guard and current DocumentsUI/import rules.

- Create `ci/comprehensive-test.ps1`
  - Windows-friendly wrapper for the Dart runner.
  - Default: run `android,windows,macos`; macOS becomes blocked with clear instruction when the host is not macOS.

- Create `ci/comprehensive-test.sh`
  - Bash wrapper for Linux/macOS/CI hosts.

- Create or modify integration targets:
  - `hibiki/integration_test/comprehensive_settings_test.dart`
  - `hibiki/integration_test/comprehensive_imports_test.dart`
  - `hibiki/integration_test/comprehensive_reader_lookup_test.dart`

## Test Matrix

Required scenarios:

1. `dictionary_import_search`
   - Platforms: Android, Windows, macOS.
   - Fixture: generated Yomitan ZIP or existing dictionary ZIP.
   - Assertion: dictionary import completes, known word search returns result evidence.
   - Evidence: report JSON, integration log, screenshot when supported.

2. `font_import_apply`
   - Platforms: Android, Windows, macOS.
   - Fixture: copied real platform font.
   - Assertion: `ReaderSettings.customFonts` contains enabled imported font and generated reader CSS contains `@font-face` and the expected family.
   - Evidence: report JSON and integration log.

3. `sync_settings_effect`
   - Platforms: Android, Windows, macOS.
   - Fixture: none.
   - Assertion: every selectable backend and content toggle writes to `SyncRepository` / preferences and reloads correctly.
   - Evidence: report JSON and integration log.

4. `sync_p2p_roundtrip`
   - Platforms: Windows and macOS host; Android client when emulator is available.
   - Fixture: local Hibiki sync server.
   - Assertion: upload and re-read progress/stat JSON through the Hibiki client backend.
   - Evidence: report JSON and server/client logs.

5. `book_import_open`
   - Platforms: Android, Windows, macOS.
   - Fixture: generated marker EPUB.
   - Assertion: import creates shelf entry, Hoshi WebView appears, content-ready marker appears.
   - Evidence: report JSON, screenshot when supported.

6. `reader_pagination`
   - Platforms: Android, Windows, macOS.
   - Fixture: generated marker EPUB.
   - Assertion: existing pagination invariants I1-I7/I9/I10 pass.
   - Evidence: existing pagination log plus report JSON.

7. `reader_page_turn_lookup`
   - Platforms: Android, Windows, macOS.
   - Fixture: generated marker EPUB and generated Yomitan dictionary.
   - Assertion: page forward changes visible marker/progress; lookup after page turn returns dictionary result evidence.
   - Evidence: report JSON, integration log, screenshot when supported.

8. `settings_controls_effect`
   - Platforms: Android, Windows, macOS.
   - Fixture: none.
   - Assertion: Switch, SegmentedButton, Slider, Stepper, and picker rows are exercised where enabled; each changed value is verified against persisted prefs or directly observable rendered reader state, then restored.
   - Evidence: report JSON and integration log.

9. `regression_open_bugs`
   - Platforms: Android first, Windows/macOS where applicable.
   - Fixture: Kagami sample when available.
   - Assertion: every `open` item in `docs/REGRESSION_BUGS.md` is either retested with evidence or reported as blocked with the missing device/fixture reason.
   - Evidence: `.codex-test/` screenshot, UI hierarchy, logcat/bounds where required.

## Execution Order

1. Write failing matrix tests.
   - Test: `hibiki/test/integration/comprehensive_test_matrix_test.dart`.
   - Required red checks:
     - `comprehensiveMatrix` exposes exactly three platforms: `android`, `windows`, `macos`.
     - Every platform includes every required scenario or an explicit `blockedWhenHostMissing` rule.
     - Every scenario has non-empty assertions, evidence requirements, and command groups.
     - Non-macOS hosts produce a blocked macOS report in dry-run mode.
2. Implement `comprehensive_test_matrix.dart`.
   - Public API:
     - `enum TestPlatformId { android, windows, macos }`
     - `enum ScenarioId { dictionaryImportSearch, fontImportApply, syncSettingsEffect, syncP2pRoundtrip, bookImportOpen, readerPagination, readerPageTurnLookup, settingsControlsEffect, regressionOpenBugs }`
     - `class TestScenario`
     - `class PlatformPlan`
     - `List<PlatformPlan> buildComprehensiveMatrix()`
3. Implement fixture generator.
   - Output:
     - `.codex-test/fixtures/test-yomitan.zip`
     - `.codex-test/fixtures/test-font.ttf` or a blocked fixture error when no real system font is available.
4. Implement Dart runner dry-run and report generation.
   - Report:
     - `.codex-test/comprehensive/<timestamp>/report.json`
     - `.codex-test/comprehensive/<timestamp>/report.md`
   - JSON must contain `platform`, `scenario`, `status`, `commands`, `assertions`, `evidence`, and `blockedReason`.
5. Add wrappers.
   - `ci/comprehensive-test.ps1` calls `dart run tool/comprehensive_test_runner.dart`.
   - `ci/comprehensive-test.sh` calls the same runner.
6. Add integration targets for settings/imports/page-turn lookup.
   - `comprehensive_settings_test.dart` fixes the current settings gap by exercising Switch, SegmentedButton, Slider, Stepper, and picker-like controls, then verifying persistence or rendered effect.
   - `comprehensive_imports_test.dart` covers dictionary import/search, custom font persistence/CSS, and marker EPUB import/open.
   - `comprehensive_reader_lookup_test.dart` covers page forward plus lookup result after movement.
7. Wire Android runner target names.
8. Run plan review.
9. Fix plan issues.
10. Run implementation review.
11. Fix implementation issues.
12. Run minimal verification:
    - `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`
    - `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/integration/comprehensive_test_matrix_test.dart`
    - `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/sync/hibiki_p2p_roundtrip_test.dart test/reader/reader_content_styles_test.dart`
    - `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test integration_test/comprehensive_settings_test.dart -d windows` when desktop integration test support is available on the current host.

## Plan Review Round 1

Result: fixed.

Findings:

- HBK-PLAN-001: The first draft named files and scenarios but did not specify the failing matrix tests. Fixed by adding explicit red checks.
- HBK-PLAN-002: The first draft did not define the public matrix API. Fixed by adding the Dart API names.
- HBK-PLAN-003: The first draft did not define report schema. Fixed by requiring `platform`, `scenario`, `status`, `commands`, `assertions`, `evidence`, and `blockedReason`.
- HBK-PLAN-004: The first draft did not state how the three new integration targets divide responsibility. Fixed in execution step 6.

## Non-Goals

- Do not replace existing focused tests.
- Do not fake macOS pass status on Windows.
- Do not clear Android app data unless a scenario explicitly requires first-run import behavior.
- Do not use `D:\ttu-fork` for current reader validation.
- Do not hand-edit generated i18n files.

## Review Checklist

- Every scenario has at least one assertion and one evidence requirement.
- Every explicit user area is covered: Android, Windows, macOS, dictionary import, font import, sync, book page turning, page-turn lookup, and settings-effect verification.
- Platform differences are isolated to adapters/wrappers.
- macOS missing host produces `blocked`, not `pass`.
- Android import-related flows do not use unapproved `file:///sdcard` shortcuts.
- Existing dirty worktree changes outside this scope are not staged.
