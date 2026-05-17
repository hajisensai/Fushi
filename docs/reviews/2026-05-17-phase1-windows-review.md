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

---

## Round 2: MSVC Compilation & Windows Build Verification

### Scope
- `native/hoshidicts/CMakeLists.txt` (MSVC compile flags + vendored lib install rules)
- `flutter build windows --release` end-to-end
- Flutter SDK `visual_studio.dart` workaround (local, not committed)

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| HBK-P1-004 | critical | **fixed** | MSVC min/max macros (`<windows.h>`) clash with `std::numeric_limits<T>::max()` in deinflector.cpp, importer.cpp, and glaze headers. Fixed: `add_compile_definitions(NOMINMAX WIN32_LEAN_AND_MEAN)`. |
| HBK-P1-005 | critical | **fixed** | MSVC defaults to system code page (CP936) for source files containing Japanese/Chinese chars (deinflector.cpp, text_processor.cpp). Caused `C2015: too many characters in constant` on `U'う'` etc. Fixed: `add_compile_options(/utf-8)`. |
| HBK-P1-006 | critical | **fixed** | MSVC `__cplusplus` macro reports 199711L by default even with `/std:c++23`, breaking utfcpp header selection and `<ranges>` C++23 features. Fixed: `add_compile_options(/Zc:__cplusplus)`. |
| HBK-P1-007 | critical | **fixed** | Vendored libraries (glaze, zstd, libdeflate, unordered_dense) have install rules that conflict with Flutter's CMake install step. Glaze tried to install headers to `$<TARGET_FILE_DIR:hibiki>/include` — a generator expression that can't be resolved at install time. Fixed: `EXCLUDE_FROM_ALL` on all `add_subdirectory` calls. |
| HBK-P1-008 | warn | noted | MSVC emits C4267 warnings (`size_t` → `uint32_t` narrowing) in importer.cpp and stardict_reader.cpp. Non-fatal on x64 Windows builds but indicates potential truncation on files >4GB. Low priority. |
| HBK-P1-009 | info | workaround | Flutter SDK's VS detection requires `VCTools` workload marker, which VS Community lacks despite having all actual components (MSVC + CMake). Local patch to `visual_studio.dart` adds component-only fallback query. Not committed — should be resolved by installing the workload via VS Installer after pending reboot. |

### Verification

| Check | Result |
|-------|--------|
| flutter analyze (app) | 0 errors, 1 warning (test file only), 12 info |
| flutter test | 587/587 passed |
| Android APK release build | Success (90.9MB with font tree-shaking) |
| **Windows release build** | **Success: hibiki.exe (90KB) + hoshidicts_ffi.dll (953KB)** |
| hoshidicts C++ compiles with MSVC 19.44 | Confirmed (0 errors, warnings only) |
| glaze/zstd/libdeflate/unordered_dense compile with MSVC | Confirmed |

### Blockers (updated)

| Blocker | Impact | Status |
|---------|--------|--------|
| ~~VS Build Tools missing C++ workload~~ | ~~Cannot compile~~ | **Resolved** — VS Community has tools; local SDK patch enables detection. Permanent fix: install VCTools workload after pending reboot. |
| flutter_inappwebview fork is Android-only | EPUB reader won't work on Windows | **Still blocking** — Phase 1 Task 3 |
| App not yet tested running on Windows | Unknown runtime crashes | Next step: launch hibiki.exe and verify startup |

### Next Scope

1. Launch `hibiki.exe` on Windows and verify app starts
2. flutter_inappwebview 6.x migration PoC (critical path for EPUB reader)
3. Remaining platform guards in navigation-reachable pages
4. Install VS VCTools workload after system reboot (cleans up local SDK patch)
