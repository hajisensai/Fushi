# Hibiki Project Review - 2026-05-17

## Round 1

### Scope
- User checklist from current task: reader layout live refresh, lookup pause behavior, lyrics mode placement/state, local audio ordering, Dolby audio container handling, import cover editing, subtitle-book long-press actions, recommended dictionary download, dictionary collapse controls, lookup popup density, per-book CSS editing, reading statistics chart axes, and collections sentence playback.
- Code paths reviewed: `ReaderHoshiPage`, `ReaderHoshiSource`, `AudiobookPlayBar`/settings sheet, dictionary dialog/popup WebView assets, book/audiobook import dialogs, SRT history dialog, collections page, reading statistics page, and `packages/hibiki_audio` audiobook models/matching.

### Findings

#### HBK-AUDIT-001
- severity: high
- status: fixed
- files: `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart`, `hibiki/lib/src/media/sources/reader_hoshi_source.dart`, `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`, `hibiki/test/reader/reader_content_styles_test.dart`
- root cause: reader setting writes updated storage, but the Hoshi reader only reloaded style/layout after the settings sheet closed. Some setters had no live callback, and layout-changing keys were not awaited as part of the setting action.
- impact: changing typography/layout looked broken until closing the settings panel, which is a real UX regression.
- fix: style setters now fire `ReaderHoshiSource.onSettingsChangedLive`; the settings sheet awaits style injection for style keys and performs live chapter reload for layout keys and book CSS edits.
- verification: `flutter test test/reader/reader_content_styles_test.dart test/media/audiobook/audiobook_play_bar_theme_chip_test.dart test/media/audiobook/collection_audio_matcher_test.dart` passed.

#### HBK-AUDIT-002
- severity: high
- status: fixed
- files: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`, `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart`, `hibiki/test/media/audiobook/audiobook_play_bar_theme_chip_test.dart`
- root cause: lyrics mode was controlled from the bottom play bar, its persisted state could survive reopening, and lookup popup dismissal resumed audio even while lyrics mode was active.
- impact: the lyrics entry was in the wrong place; lookup in lyrics mode could pause then auto-play again; stale lyrics state could produce blank reopen/cover-return behavior.
- fix: removed lyrics toggle from the bottom bar and moved it to the settings action row before bookmark/exit; opening a book clears stale lyrics mode; empty lyrics cue lists exit instead of leaving a blank page; lyrics lookup no longer auto-resumes after popup dismissal.
- verification: targeted widget test confirms the bottom bar no longer renders lyrics icons; static review confirmed settings action row contains the toggle.

#### HBK-AUDIT-003
- severity: medium
- status: fixed
- files: `packages/hibiki_audio/lib/src/audiobook/audio_file_sort.dart`, `packages/hibiki_audio/lib/hibiki_audio.dart`, `hibiki/lib/src/media/audiobook/book_import_dialog.dart`, `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`, `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`, `hibiki/lib/src/pages/implementations/collections_page.dart`, `packages/hibiki_audio/test/audiobook/audio_file_sort_test.dart`, `packages/hibiki_audio/test/audiobook/audiobook_model_test.dart`
- root cause: directory scans and manually picked audio files used lexicographic or picker order, which can put `track10` before `track2`. A naive playback-time sort would break existing cue `audioFileIndex` mappings.
- impact: multi-file local audio could play the wrong file for a cue or appear unsorted.
- fix: introduced shared natural path sorting; apply it at import/picker time and directory-scan time, while preserving persisted `audioPaths` in cue order for old data compatibility.
- verification: `flutter test test/audiobook/audio_file_sort_test.dart test/audiobook/audiobook_model_test.dart` passed in `packages/hibiki_audio`.

#### HBK-AUDIT-004
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`, `hibiki/assets/popup/popup.js`, `hibiki/assets/popup/popup.css`, `hibiki/test/utils/misc/popup_asset_behavior_test.js`
- root cause: dictionary management grouped dictionaries under repeated type headings; popup assets already hid frequency and pitch dictionary labels, but there was no regression guard for the compact popup behavior.
- impact: lookup/dictionary UI wasted vertical space.
- fix: dictionary management now renders one combined dictionary list without type section headings; popup regression test asserts frequency/pitch sections do not add crowded category titles.
- verification: `node test/utils/misc/popup_asset_behavior_test.js` passed.

#### HBK-AUDIT-005
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/reading_statistics_page.dart`
- root cause: the chart painted Y labels but no visible Y axis or horizontal grid, so the vertical coordinate was visually ambiguous.
- impact: reading statistics were harder to read.
- fix: both hourly and daily charts now draw Y axis, X baseline, and light horizontal grid lines.
- verification: covered by formatting/static review; no existing painter golden test was present.

#### HBK-AUDIT-006
- severity: medium
- status: fixed
- files: `hibiki/lib/src/pages/implementations/collections_page.dart`, `hibiki/test/media/audiobook/collection_audio_matcher_test.dart`
- root cause: collections already had sentence playback plumbing, but missing audio/cue/range cases returned silently. Directory audio file order also used plain string compare.
- impact: users could tap play and see nothing, which is indistinguishable from a broken feature.
- fix: failure paths now show an unresolved-audio toast; directory audio files use natural sorting; existing matcher tests still pass.
- verification: `flutter test test/media/audiobook/collection_audio_matcher_test.dart` passed.

#### HBK-AUDIT-007
- severity: low
- status: already implemented
- files: `hibiki/lib/src/media/audiobook/book_import_dialog.dart`, `hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`
- root cause: not a missing feature in current code.
- impact: none found in static review.
- evidence: book import has `_coverRow`, `_pickCover`, EPUB cover application, and SRT cover persistence; SRT history long-press opens `MediaItemDialogPage` with cover, audiobook import, tag, profile, CSS, and delete actions.
- verification: static code-path review only; manual DocumentsUI import was not run in this round.

#### HBK-AUDIT-008
- severity: low
- status: already implemented
- files: `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart`, `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`
- root cause: not a missing feature in current code.
- impact: none found in static review.
- evidence: recommended dictionary download exists through `DictionaryDownloader.recommended`; per-dictionary collapse exists through `toggleDictionaryCollapsed`, `collapsedLanguages`, and popup `window.collapsedDictionaryNames`.
- verification: static code-path review only.

#### HBK-AUDIT-009
- severity: low
- status: platform-limited, partially supported
- files: `hibiki/lib/src/media/audiobook/book_import_dialog.dart`, `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`, `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`, `hibiki/lib/src/pages/implementations/collections_page.dart`
- root cause: Dolby decoding is a platform/device codec capability, not an app-level toggle.
- impact: AC3/EAC3 files should be accepted and ordered, but playback still depends on Android/media stack support.
- fix: AC3/EAC3 are kept in supported extension filters and covered by audio ordering tests; no fake Dolby processing switch was added.
- verification: package tests include AC3/EAC3 path handling.

### Next Scope
- Manual emulator validation for the target reader flows remains the next high-value check: layout slider live refresh, lyrics enter/exit/reopen, lookup pause while audio plays, collections sentence playback with a real imported audiobook, and reading-stat chart screenshot.
- No open code-path blocker remains from this static/test round.
