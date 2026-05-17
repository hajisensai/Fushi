# Phase 1: Windows Port

> **Date:** 2026-05-17
> **Branch:** feature/multiplatform
> **Prerequisite:** Phase 0 complete (monorepo extraction verified)
> **Design Spec:** `docs/specs/2026-05-16-multiplatform-design.md`

## Goal

Get Hibiki running on Windows with full functionality: dictionary import/query, EPUB reading, Anki (via AnkiConnect), audiobook playback.

## Current State

- Flutter Windows runner exists at `hibiki/windows/`
- VS 2022 Build Tools 17.14.3 installed (needs "Desktop development with C++" workload + CMake tools)
- hoshidicts C++ already has Windows mmap in `memory.cpp`
- `flutter_inappwebview` fork is Android-only (blocker for WebView)
- AnkiConnect stub already exists in `packages/hibiki_anki/`

## Blocker: VS Build Tools

Flutter doctor reports missing "C++ CMake tools for Windows" component. User must run VS Installer and add:
- "Desktop development with C++" workload
- C++ CMake tools for Windows
- Windows 10 SDK (10.0.22000.0 already present)

## Task 1: hoshidicts Cross-Platform C++ Adaptation

**Goal:** Make hoshidicts compile on both Android (NDK) and Windows (MSVC/Clang-cl) from the same source.

### Changes Required

| Issue | Current | Fix |
|-------|---------|-----|
| Logging | `<android/log.h>` + `__android_log_print` | Cross-platform macro: Android→logcat, others→stderr |
| Symbol export | `__attribute__((visibility("default")))` | Macro: Windows→`__declspec(dllexport)`, others→visibility |
| Threading | `pthread_create` with 32MB stack | Windows→`_beginthreadex`/`CreateThread`, POSIX→pthread |
| CMake linking | `target_link_libraries(... log)` | Conditional: only link `log` on Android |

### Files

- Create: `native/hoshidicts/hoshidicts_include/hoshidicts/platform.hpp`
- Modify: `native/hoshidicts/hoshidicts_ffi.cpp`
- Modify: `native/hoshidicts/hoshidicts_src/importer.cpp`
- Modify: `native/hoshidicts/hoshidicts_src/deinflector.cpp`
- Modify: `native/hoshidicts/hoshidicts_src/query.cpp`
- Modify: `native/hoshidicts/CMakeLists.txt`

### Verification

```powershell
# Android (must still work):
cd hibiki/android
.\gradlew.bat :app:assembleRelease

# Windows (after VS tools installed):
cmake -B build -S native/hoshidicts -G "Visual Studio 17 2022"
cmake --build build --config Release
```

---

## Task 2: Flutter Windows Plugin for hoshidicts

**Goal:** Create a Flutter FFI plugin that bundles hoshidicts_ffi.dll with the Windows app.

### Approach

Use Flutter's native assets or manual CMake integration in `hibiki/windows/CMakeLists.txt` to compile hoshidicts and place the DLL next to the executable.

### Files

- Create: `hibiki/windows/hoshidicts/CMakeLists.txt` (wrapper that includes native/hoshidicts)
- Modify: `hibiki/windows/CMakeLists.txt` (add hoshidicts subdirectory + install DLL)

---

## Task 3: flutter_inappwebview 6.x Migration

**Goal:** Replace Android-only fork with official 6.x (supports Windows WebView2).

### Approach

1. Audit current fork customizations (10 files, 8 usage patterns)
2. Switch to `flutter_inappwebview: ^6.1.5`
3. Fix API breaking changes
4. Verify on Android first, then Windows

### Risk Mitigation

If 6.x migration is too disruptive, use `webview_windows` as Windows-specific fallback behind a `WebViewFactory` abstraction.

---

## Task 4: Windows App Shell (Initial - Material UI)

**Goal:** Get the existing app launching on Windows with Material UI. Fluent UI conversion deferred.

### Approach

1. Fix platform-specific code that blocks Windows compilation
2. Guard Android-only features (Intent, AccessibilityService, MediaSession) with `Platform.isAndroid`
3. Get `flutter build windows` succeeding
4. Test basic flow: launch → import dict → search → import EPUB → read

---

## Task 5: Platform Guards & Conditional Features

**Goal:** Make all Android-only code safe on Windows.

### Features requiring guards

| Feature | Android | Windows |
|---------|---------|---------|
| Floating Dictionary Service | SYSTEM_ALERT_WINDOW | Separate window (deferred) |
| Intent receiving | receive_intent | URI scheme (deferred) |
| Volume key page turn | MethodChannel | Keyboard arrows |
| TTS | Android TTS | Windows SAPI (flutter_tts supports both) |
| Media notification | Foreground Service | SMTC (via audio_service) |
| File picker | file_picker (works) | file_picker (works) |
| Audio playback | just_audio (works) | just_audio (works) |

---

## Execution Order

1. **Task 1** — C++ cross-platform (no VS tools needed for code changes; Android verify)
2. **Task 2** — Windows CMake plugin (needs VS tools to verify)
3. **Task 4** — Platform guards (get `flutter build windows` compiling)
4. **Task 3** — inappwebview 6.x (biggest risk; gated on Task 4)
5. **Task 5** — Feature parity polish

## Exit Criteria

- [ ] hoshidicts compiles as DLL on Windows (MSVC or Clang-cl)
- [ ] `flutter build windows` succeeds
- [ ] App launches on Windows, shows home screen
- [ ] Dictionary import + search works on Windows
- [ ] EPUB reader renders (via WebView2)
- [ ] Anki export via AnkiConnect works
- [ ] Audio playback works
- [ ] Android APK still builds and passes tests (no regression)
