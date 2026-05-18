# Hibiki Windows Platform Review — 2026-05-17

## Round 1: Windows Platform Compatibility Audit

### Scope

Full codebase audit for Windows desktop platform readiness. Checked:
- All `Platform.*` conditional branches in `lib/`
- MethodChannel guards (TTS, floating lyric, floating dict, volume keys, splash, lifecycle, Anki)
- File path and URI handling (`file://` construction/parsing)
- Plugin compatibility (Android-only packages vs cross-platform)
- UI layout responsiveness (desktop breakpoint, NavigationRail)
- Test suite health (`flutter analyze` + `flutter test`)

Commits in scope: up to `b929b6c5` (current HEAD on `feature/multiplatform`).

### Findings

#### HBK-AUDIT-001 — Test compilation error: undefined parameters
- **Severity**: HIGH
- **Status**: FIXED
- **File**: `test/media/audiobook/audiobook_play_bar_theme_chip_test.dart:45-46`
- **Root cause**: Test passed `lyricsMode` and `onToggleLyricsMode` to `AudiobookPlayBar`, but those parameters belong to `AudiobookSettingsSheet`.
- **Impact**: `flutter analyze` reported 2 errors; `flutter test` showed 1 failure.
- **Fix**: Removed the undefined named parameters from the test.
- **Verification**: `flutter analyze` 0 errors; `flutter test` 723/723 passed.

#### HBK-AUDIT-002 — Invalid file:// URI for SRT book covers on Windows
- **Severity**: HIGH
- **Status**: FIXED
- **File**: `lib/src/pages/implementations/reader_hoshi_history_page.dart:440`
- **Root cause**: `'file://${book.coverPath}'` produces `file://C:\Users\...` on Windows, where `C:` is parsed as the URI host instead of path.
- **Impact**: SRT book cover images would not display on Windows desktop.
- **Fix**: Changed to `Uri.file(book.coverPath!).toString()`.
- **Verification**: `flutter analyze` clean; runtime verification requires Windows app launch.

#### HBK-AUDIT-003 — Invalid file:// URI for dictionary custom fonts on Windows
- **Severity**: MEDIUM
- **Status**: FIXED
- **File**: `lib/src/pages/implementations/dictionary_structured_content_page.dart:47`
- **Root cause**: CSS `@font-face` URL constructed as `file://${f.path.replaceAll('\', '/')}` misses the triple-slash needed for absolute paths.
- **Impact**: Custom dictionary fonts might not load in WebView on Windows.
- **Fix**: Changed to `Uri.file(f.path)`.
- **Verification**: `flutter analyze` clean; runtime verification needed.

#### HBK-AUDIT-004 — Platform guards audit (VERIFIED OK)
- **Severity**: INFO
- **Status**: NO ACTION NEEDED
- **Details**: All platform-sensitive code paths properly guarded:
  - TtsChannel, FloatingLyricChannel, FloatingDictChannel: `Platform.isAndroid` guards
  - VolumeKeyChannel: Catches `MissingPluginException`
  - HibikiToast: Has desktop overlay fallback
  - main.dart: All mobile-only calls guarded
  - AppModel: DeviceInfo, permissions, migration, splash — all guarded
  - UpdateChecker: Android-only
  - WebView warmup: Mobile-only
  - webViewAssetUrl(): Has Windows branch
  - custom_fonts_page.dart: Has `_getDesktopSystemFonts()`

#### HBK-AUDIT-005 — Windows build blocked by running process
- **Severity**: LOW
- **Status**: ENVIRONMENT ISSUE
- **Details**: `flutter build windows` failed because running Hibiki locked `WebView2Loader.dll`.

#### HBK-AUDIT-006 — UpdateChecker skips Windows
- **Severity**: LOW (enhancement opportunity)
- **Status**: NO ACTION NEEDED
- **File**: `lib/src/utils/misc/update_checker.dart:67`

#### HBK-AUDIT-007 — AnkiConnect required on Windows
- **Severity**: LOW (documentation gap)
- **Status**: NO ACTION NEEDED
- **File**: `lib/src/models/app_model.dart:1162`
- **Details**: Error dialog mentions "AnkiDroid" which is misleading on Windows.

### Summary

| Category | Count |
|----------|-------|
| Findings total | 7 |
| Fixed | 3 (HBK-AUDIT-001, 002, 003) |
| Verified OK | 1 (HBK-AUDIT-004) |
| Environment issue | 1 (HBK-AUDIT-005) |
| Enhancement opportunities | 2 (HBK-AUDIT-006, 007) |

### Verification Results

- `flutter analyze`: 0 errors, 1 warning, 10 infos
- `flutter test`: 723/723 passed
- `flutter build windows`: Dart compilation successful; blocked only by file lock

---

## Round 2: Windows Runtime Verification

### Scope

Actual runtime testing of the Windows desktop build:
- App startup and initialization (debug mode, captured console output)
- Widget tree inspection via Dart VM Service
- Process stability monitoring
- Hot reassemble stress test

Commits in scope: `00e42f80` → `5385e9a5`.

### Findings

#### HBK-AUDIT-008 — ref.watch() crash in initState on Windows
- **Severity**: CRITICAL
- **Status**: FIXED (5385e9a5)
- **File**: `lib/src/pages/implementations/reader_hoshi_history_page.dart:47`
- **Root cause**: `_refreshSrtBooks()` accessed `appModel.database` which calls `ref.watch(appProvider)`. When called from `initState()`, `ref.watch()` throws because the widget isn't fully mounted yet. This was masked on Android by faster initialization timing, but consistently crashed on Windows desktop.
- **Impact**: `ReaderHoshiHistoryPage` (the bookshelf/history page) throws an unhandled exception on every Windows startup, potentially preventing navigation.
- **Fix**: Changed `appModel.database` to `appModelNoUpdate.database` (which uses cached `ref.read()`, safe in initState).
- **Verification**: After fix, app starts cleanly with full init sequence completing:
  ```
  [Hibiki] init: PackageInfo + DeviceInfo
  [Hibiki] init: Drift database
  [Hibiki] init: DONE
  ```
  No exceptions in debug console. `ReaderHoshiHistoryPage` present in widget tree.

### Runtime Test Results

| Test | Method | Result |
|------|--------|--------|
| App startup without crash | Debug console log capture | ✅ PASS — Full init sequence, zero exceptions |
| initState fix (HBK-AUDIT-008) | Widget tree inspection via VM Service | ✅ PASS — `ReaderHoshiHistoryPage` renders |
| Desktop NavigationRail layout | Widget tree inspection | ✅ PASS — `NavigationRail` present at 1920x1080 |
| Drift SQLite database | VM Service isolate check | ✅ PASS — DB worker isolate alive and runnable |
| Material framework | Widget tree inspection | ✅ PASS — `Scaffold`, `AppBar`, `MaterialApp` |
| Book grid rendering | Widget tree inspection | ✅ PASS — `SliverGrid`, `FadeInImage` present |
| Process stability | 7+ minutes uptime check | ✅ PASS — PID 196496, 372MB, no crash |
| Hot reassemble (UI rebuild) | VM Service `ext.flutter.reassemble` | ✅ PASS — No errors triggered |
| Main isolate health | VM Service `getIsolate` | ✅ PASS — Resume, Runnable |
| DB isolate health | VM Service `getIsolate` | ✅ PASS — Resume, Runnable |

### Verification Methodology

- **Debug console capture**: `flutter run -d windows --debug` piped through grep for `[Hibiki]|Exception|Error|EXCEPTION`
- **Widget tree inspection**: Dart VM Service WebSocket protocol → `ext.flutter.inspector.getRootWidgetSummaryTree`
- **Process monitoring**: `Get-Process -Id <PID>` + `WorkingSet64` memory check
- **UIAutomation**: Confirmed window exists at 1920x1080 (`FLUTTERVIEW` pane)
- **Note**: Flutter GPU rendering prevents GDI-based screenshot capture (PrintWindow returns black). Visual verification done via widget tree structural analysis.

### Summary

| Category | Count |
|----------|-------|
| New findings | 1 (HBK-AUDIT-008 — CRITICAL, FIXED) |
| Runtime tests passed | 10/10 |
| Process uptime | 7+ minutes, stable |

### Commits This Session

| Hash | Description |
|------|-------------|
| `00e42f80` | fix(windows): correct file:// URI construction and test sync |
| `5385e9a5` | fix(windows): use appModelNoUpdate in initState to avoid ref.watch crash |

### Next Scope

- Dictionary import and search functionality on Windows (WebView2 rendering)
- EPUB reader WebView rendering on Windows
- Custom font loading from `C:\Windows\Fonts`
- AnkiConnect integration testing on Windows

---

## Round 3: Code Quality Audit & Consistency Fix

### Scope

Post-commit review of Windows adaptation changes (reader WebView2 handling, pagination JS, audio cue priming). Full codebase scan for remaining platform issues.

### Findings

#### HBK-AUDIT-009 — Duplicated onLoadStop/onReceivedError logic
- **Severity**: MEDIUM
- **Status**: FIXED (`cef74251`)
- **File**: `lib/src/pages/implementations/reader_hoshi_page.dart`
- **Root cause**: Windows `onReceivedError` handler duplicated ~35 lines from `onLoadStop` (lyrics mode check, sasayaki prep, JS injection, highlight bridge, chapter highlights).
- **Impact**: Maintenance burden; any future change to the load-complete sequence must be updated in two places.
- **Fix**: Extracted shared logic into `_onChapterLoadComplete(InAppWebViewController)`. Both `onLoadStop` and the Windows `onReceivedError` branch call it.

#### HBK-AUDIT-010 — Inconsistent requestAnimationFrame→setTimeout fix
- **Severity**: MEDIUM
- **Status**: FIXED (`0a4fce60`)
- **File**: `lib/src/reader/reader_pagination_scripts.dart`
- **Root cause**: Paged mode `restoreProgress` and `jumpToFragment` were changed to `setTimeout(fn, 16)` for WebView2 compatibility, but continuous mode retained `requestAnimationFrame`. Both code paths execute during initial page load when WebView2 may not have composited yet.
- **Impact**: Continuous mode position restore could hang on Windows (callback never fires).
- **Fix**: Applied same `setTimeout` pattern to continuous mode `restoreProgress` and `jumpToFragment`. Scroll/resize event handlers left as `requestAnimationFrame` (correct — they run after page is visible).

#### HBK-AUDIT-011 — Platform guards comprehensive scan
- **Severity**: INFO
- **Status**: VERIFIED OK
- **Details**: Full scan of all `MethodChannel.invokeMethod`, `DeviceInfoPlugin`, `permission_handler`, and `AndroidIntent` usages. All critical paths properly guarded. `popup_main.dart` and `floating_dict_main.dart` are Android-only entry points (never reached on Windows). `Fluttertoast` is fire-and-forget (non-crashing, deferred to Phase 4).

#### HBK-AUDIT-012 — File path construction audit
- **Severity**: INFO
- **Status**: VERIFIED OK
- **Details**: `'${dir.path}/filename'` pattern used in ~11 locations. Dart's `File`/`Directory` constructors accept mixed separators on Windows — not a bug. All `file://` URI construction uses `Uri.file()`. EPUB internal path normalization (`replaceAll('\\', '/')`) is correct (EPUB uses `/` in manifest).

#### HBK-AUDIT-013 — Audio cue priming method
- **Severity**: INFO
- **Status**: VERIFIED OK
- **File**: `lib/src/pages/implementations/reader_hoshi_page.dart:420-456`
- **Details**: `_primeAudioCuesForCurrentBook()` handles initial cue loading during setup. Does NOT duplicate `_injectAudiobookBridge()` (which handles per-chapter cue injection on page load). Correct separation of concerns.

### Verification

| Check | Result |
|-------|--------|
| flutter analyze (lib/) | 0 issues |
| flutter test | 724/724 passed |
| Code duplication eliminated | Confirmed (onLoadStop → _onChapterLoadComplete) |
| Pagination JS consistency | Confirmed (both modes use setTimeout for restore) |

### Commits This Round

| Hash | Description |
|------|-------------|
| `cef74251` | fix(reader): Windows WebView2 load handling + audio cue priming |
| `be8e6bde` | fix(test): dart format + lint fixes in tests |
| `0a4fce60` | fix(reader): consistent setTimeout in continuous mode restore |

### Next Scope

- Windows runtime testing: EPUB reader rendering via WebView2
- Windows runtime testing: dictionary import and FFI search
- Continue adaptation plan execution

---

## Round 4: Windows Runtime Verification (Post-Fix)

### Scope

Rebuild and relaunch Windows debug app after Round 3 fixes. Verify startup, widget tree, process stability, and remaining platform compatibility.

### Findings

#### HBK-AUDIT-014 — Windows build + startup clean
- **Severity**: INFO
- **Status**: VERIFIED OK
- **Details**: `flutter build windows --debug` succeeds (8.9s). App launches, all init phases complete in order: PackageInfo+DeviceInfo → directories → Drift database → maps → targetLanguage+licenses → enhancements+actions+sources → search preload → DONE. Zero exceptions in console.

#### HBK-AUDIT-015 — Widget tree structural verification
- **Severity**: INFO
- **Status**: VERIFIED OK
- **Details**: Via Dart VM Service WebSocket inspection:
  - Desktop layout active: `NavigationRail` (not BottomNavigationBar)
  - Bookshelf page renders: `ReaderHoshiHistoryPage` → `Column` → `_TagBarContent` → `ListView`
  - Material framework intact: `MaterialApp` → `Scaffold` → `Row`
  - Book drag/drop: `LongPressDraggable<BookTagRow>` + `DragTarget<BookTagRow>` present

#### HBK-AUDIT-016 — Process stability
- **Severity**: INFO
- **Status**: VERIFIED OK
- **Details**: PID stable, 385MB working set, 109 threads, no crash after sustained runtime. Both main isolate and Drift DB worker isolate healthy.

#### HBK-AUDIT-017 — audio_service safety check
- **Severity**: INFO
- **Status**: VERIFIED OK
- **File**: `lib/src/models/app_model.dart:3385-3430`
- **Details**: `initialiseAudioHandler()` wraps `AudioService.init()` in try-catch. If platform init fails (possible on Windows), fallback creates `JidoujishoAudioHandler` directly without system media notifications. Non-crashing.

#### HBK-AUDIT-018 — Comprehensive platform guard final scan
- **Severity**: INFO
- **Status**: VERIFIED OK
- **Details**: Final targeted scan of 6 key Android-only APIs:
  - `HibikiToast`: Desktop overlay fallback implemented
  - `ExternalPath`: Both usages guarded with `Platform.isAndroid`
  - `FlutterExitApp`: Guarded, Windows uses `exit(0)`
  - `receive_intent`: Guarded with `Platform.isAndroid`
  - `webViewAssetUrl`: Has explicit Windows/Linux path using `Uri.file()`
  - `audio_service`: try-catch with fallback handler

### Verification

| Check | Result |
|-------|--------|
| Windows debug build | ✅ Success (8.9s) |
| App startup (zero exceptions) | ✅ Pass |
| Widget tree (NavigationRail desktop layout) | ✅ Pass |
| Process stability (385MB, 109 threads) | ✅ Pass |
| Platform guards (6 key APIs) | ✅ All safe |
| flutter analyze | ✅ 0 issues |
| flutter test | ✅ 724/724 passed |

### Phase 1 Completion Status

| Category | Status |
|----------|--------|
| C++ cross-platform adaptation | ✅ Complete |
| MSVC compilation | ✅ Complete |
| Platform guards (all channels) | ✅ Complete |
| flutter_inappwebview v6 migration | ✅ Complete |
| AnkiConnect desktop backend | ✅ Complete |
| WebView2 onReceivedError handling | ✅ Complete |
| Pagination JS WebView2 compatibility | ✅ Complete |
| Audio cue priming | ✅ Complete |
| Test suite | ✅ 724/724 pass |
| Windows build (debug + release) | ✅ Both succeed |
| App startup on Windows | ✅ Clean, all init phases |
| Widget tree verification | ✅ Desktop layout correct |
| Process stability | ✅ Verified |
| EPUB reader rendering | 🔲 Requires GUI interaction |
| Dictionary import + search | 🔲 Requires GUI interaction |
| Fluttertoast → HibikiToast | ✅ Already migrated |

---

## Round 5: Debug Script Testing + Codebase Quality Sweep

### Scope

Comprehensive testing of `.codex-test/tools/hibiki-debug.ps1` across both Android (ADB) and Flutter VM Service (Windows) backends. Full review and fix of uncommitted Dart changes across the working tree.

### Debug Script Test Results

#### Android Backend (emulator-5554)

| Command | Status | Notes |
|---------|--------|-------|
| `search 猫` | ✅ PASS | WEB_SEARCH intent launched successfully |
| `process-text 食べる` | ✅ PASS | PROCESS_TEXT intent → PopupDictActivity |
| `logcat` (unfiltered) | ✅ PASS | PID-filtered, 50 recent entries |
| `logcat flutter` (filtered) | ✅ PASS | Grep filter works correctly |
| `logcat xyznonexistent` | ✅ PASS | Returns "(no matching log entries)" cleanly |
| `crash-log` | ✅ PASS | Returns "(no crashes found)" with exit code 0 |
| `prefs` (release build) | ✅ PASS | Detects non-debuggable package, shows warning |
| `launch` | ✅ PASS | App starts via `am start` |
| `pid` | ✅ PASS | Returns PID 7154 |
| `activity` | ✅ PASS | Shows current activity state |
| `memory` | ✅ PASS | Shows meminfo summary |
| `help` | ✅ PASS | Full command listing |

#### VM Backend (Windows, ws://127.0.0.1:6998)

| Command | Status | Notes |
|---------|--------|-------|
| `eval "1+1"` | ✅ PASS | Returns 2 |
| `eval "Platform.operatingSystem"` | ✅ PASS | Returns "windows" |
| `widget-tree` | ✅ PASS | 10+ widgets, correct tree structure |
| `reload` | ❌ EXPECTED | Known limitation — needs Flutter daemon |
| `prefs` (VM) | ❌ EXPECTED | `ref.read` not in scope of root library |

### Findings

#### HBK-AUDIT-019 — Debug script VM Service issues (3 bugs)
- **Severity**: MEDIUM
- **Status**: FIXED (`78b43aba`)
- **File**: `.codex-test/tools/hibiki-debug.ps1`
- **Root cause**: (1) `evaluate` API requires `targetId` (root library ID), not just `isolateId`. (2) `getRootWidgetSummaryTree` and `reloadSources` require `isolateId` parameter. (3) `ConvertTo-Json -Depth 5` truncates nested widget trees in PS 5.1.
- **Fix**: Added `Vm-GetMainIsolateId` and `Vm-GetRootLibId` helpers. Fixed `Vm-Evaluate` to pass `targetId`. Fixed widget-tree/reload to pass `isolateId`. Increased JSON depth to 20.

#### HBK-AUDIT-020 — Debug script prefs command error handling
- **Severity**: LOW
- **Status**: FIXED (`78b43aba`)
- **File**: `.codex-test/tools/hibiki-debug.ps1`
- **Root cause**: `prefs` command ran `run-as` without checking if package is debuggable, producing cryptic error. Also, prefs list defaulted to listing SharedPreferences files instead of Drift SQLite keys.
- **Fix**: Added upfront debuggable check with clear warning. Changed listing to query `preferences` table from Drift SQLite.

#### HBK-AUDIT-021 — grep exit code causing false errors
- **Severity**: LOW
- **Status**: FIXED (`78b43aba`)
- **File**: `.codex-test/tools/hibiki-debug.ps1`
- **Root cause**: `logcat | grep ...` returns exit code 1 when no matches found, causing PowerShell to treat it as an error.
- **Fix**: Added `|| true` to grep pipes in `logcat`, `crash-log`.

#### HBK-AUDIT-022 — Missing mounted check after async navigation
- **Severity**: MEDIUM
- **Status**: FIXED (`4afa85ab`)
- **File**: `lib/src/pages/implementations/reader_hoshi_page.dart:2768`
- **Root cause**: `onSearchJump` callback called `_navigateToChapterAndWait()` (async) then accessed `_controller!` without checking `mounted` afterward. If widget is disposed during navigation, crash.
- **Fix**: Added `!mounted` to the existing guard: `if (!ok || !mounted || _controller == null) return;`

#### HBK-AUDIT-023 — Color API migration incomplete
- **Severity**: MEDIUM
- **Status**: FIXED (`4afa85ab`)
- **File**: `lib/src/pages/implementations/reader_hoshi_page.dart`
- **Root cause**: `_customThemeTextCss` and `_customHighlightCss` used deprecated `.red`/`.green`/`.blue` (integer 0-255) instead of Flutter 3.41's `.r`/`.g`/`.b` (normalized float 0-1).
- **Fix**: Migrated to `.r * 255.0` pattern. Deduplicated `_customThemeTextCss` to use shared `_colorToCssRgba` helper.

#### HBK-AUDIT-024 — Double-tap file picker race condition
- **Severity**: MEDIUM
- **Status**: FIXED (`4afa85ab`)
- **File**: `lib/src/media/audiobook/book_import_dialog.dart`
- **Root cause**: All four picker methods (`_pickEpub`, `_pickSubtitle`, `_pickAudio`, `_pickCover`) could be triggered simultaneously by rapid tapping, potentially opening multiple native file pickers.
- **Fix**: Added `_pickerActive` flag with try/finally guard to all picker methods.

#### HBK-AUDIT-025 — setState after dispose in dictionary dialog
- **Severity**: LOW
- **Status**: FIXED (`4afa85ab`)
- **File**: `lib/src/pages/implementations/dictionary_dialog_page.dart`
- **Root cause**: `_selectedOrder = -1; setState(() {})` was called after `Navigator.pop(context)`, outside the `if (mounted)` check. After pop, widget may already be disposed.
- **Fix**: Moved both lines inside the existing `if (mounted)` block.

#### HBK-AUDIT-026 — Reading statistics off-by-one
- **Severity**: LOW
- **Status**: FIXED (`4afa85ab`)
- **File**: `lib/src/pages/implementations/reading_statistics_page.dart`
- **Root cause**: `now.subtract(Duration(days: 30))` with loop `for (int i = 0; i <= 30; ...)` produced 31 data points. The chart showed 31 bars but labeled "最近30天".
- **Fix**: Changed to `subtract(Duration(days: 29))` with `for (int i = 0; i < 30; ...)` — exactly 30 bars including today.

#### HBK-AUDIT-027 — BarChartPainter shouldRepaint uses reference equality
- **Severity**: LOW
- **Status**: FIXED (`4afa85ab`)
- **File**: `lib/src/pages/implementations/reading_statistics_page.dart`
- **Root cause**: `shouldRepaint` compared `data` list by reference (`!=`) and ignored color changes. Any rebuild that created a new list instance would skip repainting.
- **Fix**: Changed to `!listEquals(data, oldDelegate.data)` and added `barColor`/`labelColor` comparison.

### Verification

| Check | Result |
|-------|--------|
| flutter analyze (full app) | 0 issues |
| flutter test | 724/724 passed |
| Debug script Android commands | 12/12 passed |
| Debug script VM commands | 3/3 passed (2 expected limitations) |

### Commits This Round

| Hash | Description |
|------|-------------|
| `78b43aba` | fix(tools): debug script VM Service + prefs error handling |
| `4afa85ab` | fix: mounted safety, picker guard, Color API, stats off-by-one |

### Next Scope

- EPUB reader rendering verification on Windows (WebView2)
- Dictionary import and FFI search on Windows
- Custom font loading from `C:\Windows\Fonts`
- AnkiConnect integration testing on Windows
