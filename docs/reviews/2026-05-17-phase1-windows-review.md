# Phase 1 Windows Port — Review Report

**Date**: 2026-05-17
**Branch**: feature/multiplatform
**Scope**: Cross-platform C++ adaptation + Dart platform guards (commits 11f5e6b5, 3c5a765e)

---

## Round 1: Cross-Platform C++ & Platform Guards

### Scope
- `native/hoshidicts/` C++ source: platform.hpp, CMakeLists.txt, hoshidicts_ffi.cpp, deinflector.cpp, importer.cpp, query.cpp
- `packages/hibiki_dictionary/lib/src/ffi/hoshidicts_ffi_bindings.dart`
- `hibiki/lib/main.dart` (platform guards for startup)
- `hibiki/lib/src/models/app_model.dart` (platform guards for Android-only APIs)
- `hibiki/windows/CMakeLists.txt` + runner files (rename yuuna→Hibiki, hoshidicts integration)

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| HBK-P1-001 | info | reviewed | `query.cpp` uses `%llu` with `static_cast<unsigned long long>` for MSVC safety. Correct but `%zu` would be cleaner for `size_t`. |
| HBK-P1-002 | info | reviewed | Android-only packages (`receive_intent`, `external_path`, `flutter_exit_app`, `record_mp3_plus`) imported unconditionally in Dart. Runtime calls guarded; native plugin registrant correctly excludes them on Windows. No action needed. |
| HBK-P1-003 | info | reviewed | `permission_handler` imported in app_model.dart and audio_recorder_page.dart. Permission requests are Android-specific but calls are navigation-gated (not startup path). Low risk. |

### Verification

| Check | Result |
|-------|--------|
| flutter analyze (app) | 0 errors, 1 warning (test file only), 12 info |
| flutter test | 587/587 passed |
| Android APK release build | Success (36.2MB) |
| No remaining bare `__android_log_print` | Confirmed (grep clean) |
| No remaining `pthread.h` include in FFI | Confirmed (replaced by platform.hpp) |
| CMakeLists.txt conditional `log` linking | Confirmed (only on `ANDROID`) |

### Blockers

| Blocker | Impact | Resolution |
|---------|--------|------------|
| VS Build Tools missing "Desktop development with C++" workload | Cannot compile hoshidicts DLL or run `flutter build windows` | User must install via VS Installer |
| flutter_inappwebview fork is Android-only | EPUB reader won't work on Windows | Phase 1 Task 3: migrate to 6.x or use webview_windows |

### Next Scope

1. Install VS C++ workload (user action)
2. Test actual Windows build (`flutter build windows`)
3. flutter_inappwebview 6.x migration PoC
4. Remaining platform guards in navigation-reachable pages
