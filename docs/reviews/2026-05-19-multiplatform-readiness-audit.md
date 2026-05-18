# Multiplatform Readiness Audit — 2026-05-19

## Round 1: Full macOS/iOS/Windows Readiness Review

### Scope

Complete audit of multiplatform readiness across all layers:
- Native C++ build system (CMakeLists.txt, platform.hpp)
- iOS/macOS native integration (Podfile, podspec, entitlements, Xcode project)
- Dart FFI bindings (library loading paths)
- Platform guards (MethodChannel, Android-only APIs)
- Package structure (melos workspace, platform constraints)
- Design spec completeness (Phase 2/3 plans)

### Findings

#### HBK-MP-001: CMakeLists.txt lacks macOS/iOS build targets

- **severity**: critical
- **status**: open
- **file**: `native/hoshidicts/CMakeLists.txt`
- **root cause**: CMake only has conditional blocks for `MSVC`/`WIN32`/`ANDROID`. No `APPLE` target, no `CMAKE_OSX_DEPLOYMENT_TARGET`, no `CMAKE_OSX_ARCHITECTURES`, no framework output format.
- **impact**: Cannot compile hoshidicts for macOS (.dylib) or iOS (.xcframework) without manual CMake invocation outside the Flutter build system.
- **fix**: Add Apple platform blocks:
  - macOS: `CMAKE_OSX_DEPLOYMENT_TARGET=10.15`, build shared library, set `INSTALL_NAME_DIR @rpath`
  - iOS: `CMAKE_OSX_DEPLOYMENT_TARGET=12.0`, build STATIC library (iOS requires static linking for FFI), `CMAKE_OSX_ARCHITECTURES=arm64`
  - Both: `-fvisibility=hidden` + explicit `HOSHI_EXPORT` on public symbols
- **validation**: `cmake --build . --target hoshidicts_ffi` succeeds on macOS; `xcodebuild` succeeds for iOS arm64

#### HBK-MP-002: No podspec for hoshidicts iOS/macOS integration

- **severity**: critical
- **status**: open
- **file**: Missing — need `hibiki/ios/hoshidicts.podspec` or Flutter plugin podspec
- **root cause**: Android uses `externalNativeBuild { cmake }` in build.gradle. Windows uses `CMakeLists.txt` in `hibiki/windows/`. iOS/macOS have no equivalent native build integration.
- **impact**: `pod install` won't compile or link hoshidicts. FFI calls will fail with "symbol not found".
- **fix**: Two viable approaches:
  1. **Flutter FFI plugin approach** (recommended): Create a minimal Flutter plugin package `hoshidicts_native` with `ios/hoshidicts_native.podspec` and `macos/hoshidicts_native.podspec` that compile the C++ source via CocoaPods `source_files` + `compiler_flags`.
  2. **Pre-built binary approach**: Build `.xcframework` separately, vendor it, reference via podspec `vendored_frameworks`.
- **validation**: `cd hibiki/ios && pod install` succeeds; app links against hoshidicts symbols

#### HBK-MP-003: No macOS project directory

- **severity**: critical
- **status**: expected (Phase 2 not started)
- **file**: Missing — `hibiki/macos/` does not exist
- **root cause**: `flutter create --platforms=macos .` has not been run yet.
- **impact**: Cannot build or test macOS target.
- **fix**: Phase 2 first step: `flutter create --platforms=macos .` in `hibiki/` directory, then customize Runner, add entitlements, integrate hoshidicts native.
- **validation**: `flutter build macos` succeeds

#### HBK-MP-004: macOS FFI dylib loading depends on correct podspec RPATH

- **severity**: medium
- **status**: resolved-by-design (depends on HBK-MP-002)
- **file**: `packages/hibiki_dictionary/lib/src/ffi/hoshidicts_ffi_bindings.dart:9`
- **analysis**: `DynamicLibrary.open('libhoshidicts_ffi.dylib')` uses bare filename — this is the standard Flutter FFI pattern. macOS's `dlopen` resolves bare names via RPATH, which Flutter's plugin system configures to include `@executable_path/../Frameworks/`. The dylib's install name must use `@rpath/libhoshidicts_ffi.dylib`.
- **impact**: Works correctly IF the podspec (HBK-MP-002) sets `INSTALL_NAME_DIR @rpath` on the built dylib. No Dart code change needed.
- **fix**: Ensure podspec in HBK-MP-002 includes: `spec.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-ObjC' }` and CMake sets `INSTALL_NAME_DIR @rpath` + `BUILD_WITH_INSTALL_RPATH ON`.
- **validation**: hoshidicts FFI loads and `hoshidicts_lookup` returns results on macOS

#### HBK-MP-005: No iOS/macOS entitlements files

- **severity**: medium
- **status**: open
- **file**: Missing — `hibiki/ios/Runner/Runner.entitlements`, `hibiki/macos/Runner/*.entitlements`
- **root cause**: Default Flutter iOS project has minimal entitlements. Hibiki needs:
  - iOS: `com.apple.security.application-groups` (if sharing data with extensions), network access
  - macOS: `com.apple.security.app-sandbox` (required for App Store), `com.apple.security.network.client`, `com.apple.security.files.user-selected.read-write`
- **impact**: macOS App Store submission blocked; iOS Share Extension won't work without app groups.
- **fix**: Create entitlements files during Phase 2/3 setup.
- **validation**: App passes code signing and runs under sandbox

#### HBK-MP-006: iOS Podfile missing platform version

- **severity**: medium
- **status**: open
- **file**: `hibiki/ios/Podfile:2`
- **root cause**: Line 2 (`platform :ios, '...'`) is likely commented out or using an old default. Should specify minimum deployment target matching SDK constraints.
- **impact**: CocoaPods may pick wrong deployment target, causing build warnings or failures with modern APIs.
- **fix**: Set `platform :ios, '12.0'` (or higher based on Flutter 3.41 requirements).
- **validation**: `pod install` completes without deployment target warnings

#### HBK-MP-007: Fluttertoast has no desktop plugin (pre-existing)

- **severity**: low
- **status**: fixed (HibikiToast)
- **file**: Multiple (80+ call sites migrated to HibikiToast)
- **summary**: Already addressed in Phase 1 with `HibikiToast` overlay fallback. No action needed.

#### HBK-MP-008: Android-only packages imported unconditionally

- **severity**: low
- **status**: acceptable
- **files**: `main.dart:10` (receive_intent), `audio_recorder_page.dart:8` (record_mp3_plus)
- **root cause**: Dart-level imports of platform plugins are platform-agnostic; only native side is absent on unsupported platforms. Runtime calls are properly guarded by `Platform.isAndroid`.
- **impact**: Zero — Flutter's plugin registrant simply doesn't register the native side on unsupported platforms. No crash, no compilation failure.
- **fix**: Optional cleanup — could use conditional import or move to an Android-specific wrapper, but not required.
- **validation**: N/A — verified these are non-issues for iOS/macOS builds

#### HBK-MP-009: WebView2-specific error handling needs macOS equivalent

- **severity**: low
- **status**: open
- **file**: `reader_hoshi_page.dart:1319-1330`
- **root cause**: `onReceivedError` handler has Windows-specific logic for WebView2's behavior of reporting intercepted-domain navigation as errors. macOS uses WKWebView which may behave differently.
- **impact**: EPUB reader may show spurious error handling or miss real errors on macOS.
- **fix**: Test WKWebView behavior on macOS; add platform-specific branch if needed.
- **validation**: EPUB rendering works correctly on macOS

#### HBK-MP-010: Phase 2/3 plan documents missing

- **severity**: info
- **status**: open
- **file**: Missing — `docs/plans/2026-05-19-phase2-macos-port.md`, `docs/plans/2026-05-19-phase3-ios-port.md`
- **root cause**: Phase 2/3 work hasn't started; only high-level outlines exist in the design spec.
- **fix**: Create detailed plans with subtasks, risk analysis, and validation criteria.
- **validation**: Plans reviewed and approved

### Build Verification

| Check | Result |
|-------|--------|
| flutter analyze (hibiki) | Pending this round |
| flutter test | 724/724 (last verified Round 6 of Phase 1 review) |
| Windows release build | Success (last verified) |
| Android APK build | Success (last verified) |
| macOS build | N/A (macos/ directory missing) |
| iOS build | N/A (requires Mac hardware) |

### Risk Matrix

| ID | Severity | Blocking | Phase |
|----|----------|----------|-------|
| HBK-MP-001 | critical | Phase 2/3 | CMake Apple targets |
| HBK-MP-002 | critical | Phase 2/3 | hoshidicts podspec |
| HBK-MP-003 | critical | Phase 2 | macOS project dir |
| HBK-MP-004 | medium | Resolved by HBK-MP-002 | macOS dylib RPATH |
| HBK-MP-005 | medium | Phase 2/3 dist | Entitlements |
| HBK-MP-006 | medium | Phase 3 | iOS Podfile |
| HBK-MP-007 | low | None | Already fixed |
| HBK-MP-008 | low | None | Acceptable |
| HBK-MP-009 | low | Phase 2 | WKWebView testing |
| HBK-MP-010 | info | Planning | Plan documents |

### Next Scope

1. Create detailed Phase 2 (macOS) and Phase 3 (iOS) plans addressing all critical/high findings
2. Update design spec with lessons from Phase 1 and newly identified gaps
3. Fix HBK-MP-004 (FFI path) since it's a Dart-only change
4. Run flutter analyze to verify current code health
