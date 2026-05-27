# Review: MD3 Global Redesign

## Round 1 Summary

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | None found |
| Warning | 3 | 1 fixed, 2 accepted/deferred |
| Info | 8 | Confirmed |

### Round 1 Findings

#### W1: AdaptiveSettingsSection radius mismatch - Fixed
- Material branch hardcoded `8` while tokens moved to larger MD3 radii.
- Also had a border that was inconsistent with tonal `HibikiCard`.
- Fix: use `tokens.radii.group` and remove the extra Material border.

#### W2: HibikiPopupSurface border - Accepted
- Popup surfaces intentionally keep a border for z-depth separation.
- Overlay contexts such as floating dictionary and popup dictionary need a visible boundary.

#### W3: AdaptiveSettingsTextField naming - Deferred
- Pre-existing naming inconsistency, not introduced by this task.
- Callers are Material-focused settings/input contexts.

## Round 2 Summary

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | None found |
| Warning | 2 | Mitigated |
| Info | 4 | Confirmed |

### Round 2 Findings

#### W1: External dual-model review blocked by local tool environment
- Codex backend reached `codeagent-wrapper.exe`, but the API request failed with `401 Unauthorized`.
- Claude backend failed because `claude` is not available in PATH.
- Status: mitigated by local diff review, focused static review, full Flutter test verification, and recording the blocker in `fix-log.jsonl`.

#### W2: Worktree contains non-MD3 dirty changes
- `CLAUDE.md`, `hibiki/lib/src/pages/base_source_page.dart`, `hibiki/lib/src/media/audiobook/audiobook_bridge.dart`, `hibiki/lib/src/reader/reader_pagination_scripts.dart`, and `hibiki/pubspec.yaml` include changes outside this MD3 UI task.
- Status: mitigate by staging only MD3/UI-related files for the implementation commit.
- Whole-worktree `git diff --check` is blocked by an unrelated blank line in `CLAUDE.md`; use `git diff --cached --check` before commit.

## Local Review Notes

- Page-level `TextField` / `TextFormField` plus local `OutlineInputBorder` usage has been moved to `HibikiTextField` or `AdaptiveSettingsTextField`.
- Remaining `OutlineInputBorder` uses are limited to `theme_notifier.dart` and the shared `HibikiTextField` implementation.
- `Card`, `ListTile`, `SwitchListTile`, `CheckboxListTile`, `ExpansionTile`, and `PopupMenuButton` scans no longer show page-level old Material primitives under `hibiki/lib`.
- `reader_quick_settings_sheet.dart` contains pre-existing TOC hierarchy/header changes in addition to this round's input-field migration, so staging must be intentional.

## Verification

- `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`: failed on stale `hibiki/build/flutter_inappwebview_android/.transforms/...` directory.
- Targeted `dart format` on all touched Dart source/test files: passed.
- `node docs\design\md3-cupertino\verify-interface-coverage.mjs`: passed, `interfaceCoverage=ok`.
- `flutter test test\settings\md3_design_system_static_test.dart --reporter expanded`: passed.
- `flutter test test\pages --reporter expanded`: passed.
- `flutter test test\widgets --reporter expanded`: passed.
- `flutter test test\media --reporter expanded`: passed.
- `flutter test test\settings --reporter expanded`: passed.
- `flutter test test\sync --reporter expanded`: passed.
- `flutter test`: passed, 1143 tests.
