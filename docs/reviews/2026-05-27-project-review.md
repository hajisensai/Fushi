# 2026-05-27 Project Review

## Round 1 - Seal-style MD3 ordinary chrome repair

### Scope

- Reference target:
  - Seal phone screenshots 1-9 from `JunkFood02/Seal` fastlane metadata.
- Runtime/shared component files:
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
- Repaired page families:
  - `hibiki/lib/src/media/audiobook/book_import_dialog.dart`
  - `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`
  - `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`
  - `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`

### Findings

#### HBK-AUDIT-007 - Import dialogs still hand-built file rows and switches

- severity: MEDIUM
- status: resolved in working tree
- files/lines:
  - `hibiki/lib/src/media/audiobook/book_import_dialog.dart`
  - `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
- root cause:
  - File-picking UI was repeated as local `Row`/`Column` blocks with literal 11/13 point text and direct switch-list widgets. That made these dialogs look like old dense Flutter chrome while the rest of the app was moving to shared MD3 rows.
- impact:
  - Book and audiobook import are high-friction workflows. Inconsistent file slots and matching controls make the app feel half-migrated even though the business logic is fine.
- fix:
  - Added `HibikiFilePickerRow` as the shared row data structure for selectable files/directories.
  - Migrated book import and audiobook import file slots into `AdaptiveSettingsSection` plus `HibikiFilePickerRow`.
  - Migrated the auto-window switch to `AdaptiveSettingsSwitchRow`.
- verification:
  - Static guard now requires the import dialogs to use shared rows and blocks the old hand-sized row text.
  - Focused dialog layout tests are part of this round's final verification gate.

#### HBK-AUDIT-008 - Reader history book cards bypassed the shared MD3 card shell

- severity: MEDIUM
- status: resolved in working tree
- files/lines:
  - `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
- root cause:
  - `_bookCardShell` still built its own `Material`, hard-coded `surfaceContainerLow`, and fixed a 12px radius locally. It also needed long-press support, which the shared card did not expose yet.
- impact:
  - Reader history is a primary app surface. Local card shells weaken the Seal-style MD3 target because selected state, radius, and surface roles drift away from the shared token layer.
- fix:
  - Added optional `onLongPress` to `HibikiCard`.
  - Migrated `_bookCardShell` to `HibikiCard`, preserving tap, long-press, selection overlay, aspect ratio, and reorder/selection behavior.
- verification:
  - Static guard narrows the ban to `_bookCardShell` and blocks local `Material(`, `surfaceContainerLow`, and `BorderRadius.circular(12)` in that shell.

#### HBK-AUDIT-009 - Dictionary download selection used MD2 expansion and checkbox rows

- severity: MEDIUM
- status: resolved in working tree
- files/lines:
  - `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
- root cause:
  - The download catalog mixed data state and framework-default UI through `ExpansionTile` and `CheckboxListTile`. That bypassed `HibikiCard` and `HibikiListItem`, so the chooser looked like a stock MD2 list inside an otherwise tokenized dialog.
- impact:
  - Dictionary setup is a high-visibility onboarding/management path. The old expansion/list rows were visually inconsistent and hard to keep aligned with the Seal-style grouped row grammar.
- fix:
  - Replaced category expansion with explicit `expandedCategories` state and a `HibikiCard` category group.
  - Replaced each dictionary checkbox row with `HibikiListItem` plus a `Checkbox`, preserving checked indices, installed-state styling, language changes, and default expanded Japanese categories.
- verification:
  - The static guard was written failing-first, then passed after migration.
  - Final verification must include the static design-system test before commit.

#### HBK-AUDIT-010 - Tag picker used framework-default checkbox rows

- severity: MEDIUM
- status: resolved in working tree
- files/lines:
  - `hibiki/lib/src/pages/implementations/tag_picker_page.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
  - `hibiki/test/pages/tag_picker_page_static_test.dart`
- root cause:
  - Tag selection used `CheckboxListTile`, which hard-coded the page into framework-default list styling instead of the shared MD3 row/card grammar.
- impact:
  - Tag selection is launched from reader history and book management flows. Leaving it as a stock checkbox list made the page visually inconsistent with the repaired reader history cards.
- fix:
  - Replaced the checkbox list with `ListView.separated`, `HibikiCard`, `HibikiListItem`, and a trailing `Checkbox`.
  - Moved the empty state into a shared `HibikiCard` plus `HibikiPlaceholderMessage`.
  - Added a compile guard that imports and instantiates `TagPickerPage`.
- verification:
  - Static guard was written failing-first and failed on `CheckboxListTile`.
  - Passed after migration with the focused tag picker verification command listed below.

#### HBK-AUDIT-011 - Reader hover and illustration grid still hard-coded surfaces

- severity: LOW
- status: resolved in working tree
- files/lines:
  - `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`
  - `hibiki/lib/src/pages/implementations/illustrations_viewer_page.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
  - `hibiki/test/pages/illustrations_viewer_page_static_test.dart`
- root cause:
  - Reader tag-drop hover overlay used a local `BorderRadius.circular(12)`.
  - Illustration thumbnails used local `surfaceContainerLow` and `BorderRadius.circular(8)` instead of the shared card surface.
- impact:
  - These were small but visible remnants of page-local visual decisions. They weakened the Seal-style rule that cards and state overlays should use one token layer.
- fix:
  - Reader tag-drop overlay now reads `HibikiDesignTokens.of(context)` and uses `tokens.radii.cardRadius`.
  - Illustration grid items now use `HibikiCard` with zero padding and preserve tap-to-fullscreen image behavior.
  - Added a compile guard for `IllustrationsViewerPage`.
- verification:
  - Static guard was written failing-first and failed on `surfaceContainerLow`, missing `HibikiCard`, and missing design tokens in the reader hover overlay.
  - Passed after migration with the focused verification command listed below.

### Verification

- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\utils\components\hibiki_material_components.dart lib\src\media\audiobook\book_import_dialog.dart lib\src\media\audiobook\audiobook_import_dialog.dart lib\src\pages\implementations\reader_hibiki_history_page.dart lib\src\pages\implementations\dictionary_dialog_page.dart test\settings\md3_design_system_static_test.dart`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format test\pages\dictionary_dialog_layout_static_test.dart`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart test\media\audiobook\book_import_dialog_test.dart test\pages\dictionary_dialog_layout_static_test.dart test\pages\book_profile_dialog_page_test.dart test\pages\reader_history_delete_dialog_test.dart --reporter expanded`
- Blocked: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze ...` timed out twice, once at 180 seconds and once at 300 seconds. A compile guard was added to `dictionary_dialog_layout_static_test.dart` to import and instantiate `DictionaryDialogPage` directly.
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\pages\implementations\tag_picker_page.dart test\settings\md3_design_system_static_test.dart test\pages\tag_picker_page_static_test.dart`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart test\pages\tag_picker_page_static_test.dart --reporter expanded`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib\src\pages\implementations\illustrations_viewer_page.dart lib\src\pages\implementations\reader_hibiki_history_page.dart test\settings\md3_design_system_static_test.dart test\pages\illustrations_viewer_page_static_test.dart`
- Passed: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\settings\md3_design_system_static_test.dart test\pages\illustrations_viewer_page_static_test.dart test\pages\book_profile_dialog_page_test.dart test\pages\reader_history_delete_dialog_test.dart --reporter expanded`
- Passed: `git diff --cached --check`

### Next Scope

1. Continue with the remaining ordinary chrome debt: `tag_picker_page.dart`, editor shells, diagnostic/log shells, and any non-content `CheckboxListTile`/`ExpansionTile` use.
2. Keep direct typography exceptions limited to rendered content, theme previews, logs, code/CSS editors, and reader content; ordinary rows must use shared component typography.
3. After each page-family migration, add or extend a failing static/widget guard first, then migrate to `HibikiCard`, `HibikiListItem`, `HibikiSearchField`, `HibikiOverflowMenu`, `HibikiFilePickerRow`, or a new shared primitive only if the data shape genuinely differs.
