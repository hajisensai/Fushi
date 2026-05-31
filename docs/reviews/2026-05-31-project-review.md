## Round 1 - Material 3 architecture completion audit

### Scope

- Static search over `hibiki/lib/src` for framework visual primitives, hardcoded typography, local density, radius, and surface tokens.
- Focused review of ordinary chrome in dictionary popup, dictionary audio sources, profile management, reader quick settings, and sync controls.
- Tests: `md3_design_system_static_test.dart`, focused page-family tests, and full Flutter test suite.
- Android smoke on `emulator-5554` (`x86_64`) using `hibiki/build/app/outputs/flutter-apk/app-debug.apk`, installed without clearing app data.

### Findings

#### HBK-AUDIT-190 - Final ordinary chrome leaks after MD3 migration

- severity: LOW
- status: resolved
- files/lines:
  - `hibiki/lib/src/pages/implementations/dictionary_popup_native.dart`
  - `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart`
  - `hibiki/lib/src/pages/implementations/profile_management_page.dart`
  - `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`
  - `hibiki/lib/src/sync/sync_settings_schema.dart`
  - `hibiki/lib/src/sync/sync_compare_dialog.dart`
  - `hibiki/test/settings/md3_design_system_static_test.dart`
  - `hibiki/test/pages/dictionary_settings_dialog_md3_static_test.dart`
  - `hibiki/test/pages/profile_management_dialog_md3_static_test.dart`
  - `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
- root cause: A few late-migrated ordinary chrome controls still made local Material component decisions (`IconButton`, `FilledButton.tonal`, `VisualDensity.compact`) outside the shared MD3 component layer.
- impact: The app could drift back toward page-local MD2/MD3 hybrids even though most settings and dialog chrome had migrated.
- fix: Replaced icon-only controls with `HibikiIconButton`, removed page-local compact density from sync buttons/segmented controls, and added static guards for the affected surfaces.
- verification:
  - `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat analyze lib/src/pages/implementations/dictionary_popup_native.dart lib/src/pages/implementations/dictionary_settings_dialog_page.dart lib/src/pages/implementations/profile_management_page.dart lib/src/media/audiobook/reader_quick_settings_sheet.dart test/settings/md3_design_system_static_test.dart test/pages/dictionary_settings_dialog_md3_static_test.dart test/pages/profile_management_dialog_md3_static_test.dart test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
  - `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat analyze lib/src/sync/sync_settings_schema.dart lib/src/sync/sync_compare_dialog.dart`
  - `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/settings/md3_design_system_static_test.dart test/pages/dictionary_settings_dialog_md3_static_test.dart test/pages/profile_management_dialog_md3_static_test.dart test/media/audiobook/reader_quick_settings_sheet_static_test.dart --reporter expanded`
  - `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/settings/md3_design_system_static_test.dart --reporter expanded`
  - `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/settings/settings_renderer_test.dart test/pages/hibiki_settings_dialog_page_test.dart test/media/audiobook/book_import_dialog_test.dart test/pages/dictionary_dialog_layout_static_test.dart test/pages/popup_dictionary_page_test.dart test/pages/book_profile_dialog_page_test.dart test/pages/reader_history_delete_dialog_test.dart --reporter expanded`
  - `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test`

#### HBK-AUDIT-191 - Android smoke coverage is partial because test data is absent

- severity: LOW
- status: blocked
- files/lines:
  - `.codex-test/md3-home.png`
  - `.codex-test/md3-home.xml`
  - `.codex-test/md3-settings.png`
  - `.codex-test/md3-settings.xml`
  - `.codex-test/md3-settings-appearance.png`
  - `.codex-test/md3-settings-appearance.xml`
  - `.codex-test/md3-dictionaries.png`
  - `.codex-test/md3-dictionaries.xml`
  - `.codex-test/md3-dictionary-search.png`
  - `.codex-test/md3-dictionary-search.xml`
  - `.codex-test/md3-logcat.txt`
  - `.codex-test/md3-launch-logcat.txt`
- root cause: The emulator app data had no imported dictionaries and no books.
- impact: Home, settings, settings detail, dictionary search entry, and dictionary empty-result state were smoke tested; popup lookup results, reader shelf long press, reader quick settings, audiobook bar, and reader/audiobook bounds could not be truthfully marked as manually verified.
- fix: No code fix. The missing coverage requires seeded/imported book and dictionary data in the emulator.
- verification: `app-debug.apk` installed successfully on `emulator-5554` without clearing data. Captured screenshots, UI XML, and logcat. `md3-logcat.txt` showed no app crash in the covered smoke; visible matches were emulator/system warnings and dictionary preprocess logs.

### Next Scope

- No remaining ordinary app chrome defects from the final static audit.
- Remaining manual-only coverage needs imported dictionary and reader/audiobook fixtures before popup lookup, reader quick settings, audiobook bar, and bounds can be verified.
