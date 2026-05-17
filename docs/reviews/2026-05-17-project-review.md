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

### Next Scope

- Runtime verification on Windows
- WebView2-specific behavior
- AnkiConnectRepository on Windows
