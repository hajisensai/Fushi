# Phase 2: macOS Port

> **Date:** 2026-05-19
> **Branch:** feature/multiplatform
> **Prerequisite:** Phase 1 complete (Windows port verified), Mac development machine available
> **Design Spec:** `docs/specs/2026-05-16-multiplatform-design.md`
> **Audit:** `docs/reviews/2026-05-19-multiplatform-readiness-audit.md`

## Goal

Get Hibiki running on macOS with full functionality: dictionary import/query, EPUB reading (WKWebView), Anki (via AnkiConnect), audiobook playback. Phase 2 MVP uses Material Design; native macos_ui shell deferred to Phase 4 polish.

## Current State

- `hibiki/macos/` **does not exist** — must be created with `flutter create`
- hoshidicts C++ already compiles on POSIX (Android) and MSVC (Windows); Apple Clang should work with minimal changes
- `platform.hpp` has cross-platform logging (stderr fallback) and threading (`pthread` for POSIX)
- FFI bindings already have macOS path: `DynamicLibrary.open('libhoshidicts_ffi.dylib')`
- `flutter_inappwebview` 6.1.5 supports macOS (WKWebView)
- AnkiConnect HTTP client implemented in Phase 1 (reusable on macOS)
- All MethodChannel calls guarded or try-caught (verified in Phase 1 Round 4)
- Desktop platform detection (`isDesktopPlatform`) already includes macOS

## Hardware Prerequisite

macOS builds require Xcode, which only runs on Mac hardware. Options:
1. **Mac Mini / MacBook** — full local development (recommended)
2. **GitHub Actions macOS runner** — CI-only builds, no interactive debugging
3. **Cloud Mac service** (MacStadium / AWS EC2 Mac) — remote development

At minimum, one Mac is needed for initial setup, debugging, and WKWebView testing. After initial setup, CI runners can handle builds.

---

## Task 1: Create macOS Project Structure

**Goal:** Generate Flutter macOS runner and configure it for Hibiki.

### Steps

1. In `hibiki/` directory:
   ```bash
   flutter create --platforms=macos .
   ```
2. Configure `macos/Runner/Configs/AppInfo.xcconfig`:
   - `PRODUCT_BUNDLE_IDENTIFIER = app.hibiki.reader`
   - `PRODUCT_NAME = Hibiki`
   - `FLUTTER_BUILD_NAME` and `FLUTTER_BUILD_NUMBER` matching Android
3. Set minimum deployment target in `macos/Podfile`:
   ```ruby
   platform :macos, '10.15'
   ```
   Rationale: macOS 10.15 (Catalina) is minimum for SwiftUI, Combine, and matches Flutter 3.41 requirements.

4. Create entitlements files:
   - `macos/Runner/DebugProfile.entitlements`:
     ```xml
     <key>com.apple.security.app-sandbox</key>    <true/>
     <key>com.apple.security.network.client</key>  <true/>
     <key>com.apple.security.files.user-selected.read-write</key> <true/>
     ```
   - `macos/Runner/Release.entitlements`: same as above

5. Update `macos/Runner/Info.plist`:
   - Add file type associations for `.epub`
   - Add URL scheme `hibiki://`
   - Set `LSMinimumSystemVersion` to `10.15`

### Verification

```bash
flutter build macos --debug
# App launches, shows loading screen, reaches home page
```

---

## Task 2: hoshidicts macOS Native Library (.dylib)

**Goal:** Compile hoshidicts C++ as a dynamic library for macOS and integrate it into the Flutter app bundle.

### Approach: Flutter Plugin with CocoaPods

Create a minimal Flutter plugin that wraps the C++ compilation via CocoaPods, similar to how `hibiki/windows/CMakeLists.txt` integrates hoshidicts on Windows.

### Changes Required

#### 2a. Update CMakeLists.txt for Apple platforms

```cmake
# Add to native/hoshidicts/CMakeLists.txt after the WIN32 block:

if(APPLE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "10.15" CACHE STRING "Minimum macOS version")
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)
  # Symbol visibility: hide all except HOSHI_EXPORT
  set(CMAKE_CXX_VISIBILITY_PRESET hidden)
  set(CMAKE_C_VISIBILITY_PRESET hidden)
  set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
endif()
```

And for the shared library target:
```cmake
if(APPLE)
  set_target_properties(hoshidicts_ffi PROPERTIES
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_RPATH ON
    MACOSX_RPATH ON
  )
endif()
```

#### 2b. Create macOS podspec

File: `native/hoshidicts/hoshidicts_native.podspec`

> **Note:** macOS and iOS share the same podspec file name (`hoshidicts_native.podspec`) because CocoaPods resolves by `s.name`, not filename. Use a single podspec with `if defined?(osx)` platform detection, or separate directories. See Phase 3 plan for the iOS variant.

```ruby
Pod::Spec.new do |s|
  s.name             = 'hoshidicts_native'
  s.version          = '1.0.0'
  s.summary          = 'Hoshidicts C++ dictionary engine'
  s.homepage         = 'https://github.com/hajisensai/hibiki'
  s.license          = { :type => 'MIT' }
  s.author           = 'Hibiki'
  s.source           = { :path => '.' }

  # Multi-platform: shared with iOS (Phase 3)
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.15'
  s.static_framework = true  # Required for iOS; harmless for macOS

  s.source_files     = 'hoshidicts_src/**/*.{cpp,hpp,h,c}',
                        'hoshidicts_ffi.cpp',
                        'hoshidicts_include/**/*.{hpp,h}',
                        'hoshidicts_external/utfcpp/source/**/*.h',
                        'hoshidicts_external/xxHash/*.{h,c}'
  s.header_mappings_dir = 'hoshidicts_include'

  # Platform-specific Flutter dependency
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++23',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) NOMINMAX',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/hoshidicts_include"',
      '"$(PODS_TARGET_SRCROOT)/hoshidicts_external/utfcpp/source"',
      '"$(PODS_TARGET_SRCROOT)/hoshidicts_external/xxHash"',
      '"$(PODS_TARGET_SRCROOT)/hoshidicts_external/glaze/include"',
      '"$(PODS_TARGET_SRCROOT)/hoshidicts_external/unordered_dense/include"',
      '"$(PODS_TARGET_SRCROOT)/hoshidicts_external/libdeflate"',
      '"$(PODS_TARGET_SRCROOT)/hoshidicts_external/zstd/lib"',
    ].join(' '),
  }

  s.subspec 'zstd' do |zstd|
    zstd.source_files = 'hoshidicts_external/zstd/lib/**/*.{c,h}'
    zstd.header_mappings_dir = 'hoshidicts_external/zstd/lib'
    zstd.pod_target_xcconfig = {
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) ZSTD_DISABLE_ASM',
    }
  end

  s.subspec 'libdeflate' do |ld|
    ld.source_files = 'hoshidicts_external/libdeflate/lib/**/*.{c,h}'
    ld.header_mappings_dir = 'hoshidicts_external/libdeflate'
  end
end
```

**Alternative approach (simpler):** Use CMake directly from `macos/CMakeLists.txt` like Windows, bypassing CocoaPods for the native compilation. This requires a custom build phase in Xcode that runs CMake.

#### 2c. Reference from Podfile

Add to `hibiki/macos/Podfile`:
```ruby
pod 'hoshidicts_native', :path => '../../native/hoshidicts'
```

Or create a Flutter plugin wrapper that references the podspec.

### Risk: C++23 on Apple Clang

Apple Clang ships with Xcode and lags behind upstream LLVM. Key concerns:
- `std::expected` (C++23): Available since Xcode 15 / Apple Clang 15
- `constexpr` in `<ranges>`: Partial in Apple Clang 15
- glaze headers: May require Xcode 15.2+ for full C++23 support

**Mitigation:** Require Xcode 15.2+ (ships with macOS 14 Sonoma). If needed, pin `CLANG_CXX_LANGUAGE_STANDARD=c++2b` as a fallback.

### Verification

```bash
cd hibiki/macos && pod install
flutter build macos --debug
# App launches; dictionary import and search work
```

---

## Task 3: WKWebView Verification (EPUB Reader)

**Goal:** Verify EPUB reader works correctly with WKWebView on macOS.

### Known Differences from WebView2 (Windows)

| Behavior | WebView2 (Windows) | WKWebView (macOS) |
|----------|--------------------|--------------------|
| Custom scheme handling | `onReceivedError` with intercepted domain | Likely transparent (WKURLSchemeHandler) |
| `requestAnimationFrame` on init | Unreliable during WebView2 startup | Should work (WebKit is RAF-native) |
| JS bridge | `window.flutter_inappwebview.callHandler` | Same API (flutter_inappwebview abstraction) |
| Local file access | `file:///` with WebView2 AllowFileAccessFromFiles | WKWebView sandbox may block local file:// |

### Steps

1. Launch EPUB reader on macOS → verify text renders
2. Test page navigation (swipe, keyboard arrows)
3. Test word selection → dictionary popup
4. Test CSS Highlights API (sentence highlight)
5. Test resource loading (custom fonts, images from EPUB)
6. If `file://` access blocked: switch to custom scheme (`hoshi.local://`) or local HTTP server

### Known Issue: reader_hoshi_page.dart:1407-1422

Windows-specific `onReceivedError` handler treats intercepted-domain navigation as success (line 1415: `if (Platform.isWindows && request.url.host == ReaderHoshiSource.kHost)`). Need to test if WKWebView triggers the same error pattern. If not, the existing code is safe (falls through to default handler).

### Verification

```
EPUB opens → text renders → word tap shows dict popup → page turn works → highlight works
```

---

## Task 4: macOS-Specific Features

**Goal:** Implement macOS-native features that enhance the desktop experience.

### 4a. Keyboard Shortcuts

Extend existing keyboard navigation (from Phase 1 Windows):

| Shortcut | Action | Status |
|----------|--------|--------|
| Cmd+D | Dictionary lookup (selected text) | New |
| Cmd+E | Export to Anki | New |
| Cmd+O | Open file (EPUB/dictionary) | New |
| Cmd+, | Settings | New |
| Cmd+F | Search | New |
| Left/Right Arrow | Page turn | Existing (Phase 1) |
| PageUp/PageDown | Page turn | Existing (Phase 1) |
| F11 / Cmd+Ctrl+F | Fullscreen | New |

Implementation: Extend existing `Focus` + `onKeyEvent` handler (already implemented in `reader_hoshi_page.dart:2410-2429` as `_handleKeyEvent`, wired at line 796). Add Cmd modifier variants for macOS shortcuts.

### 4b. Menu Bar Integration

macOS apps need a proper menu bar. Use `PlatformMenuBar` widget (Flutter built-in since 3.x):

```dart
PlatformMenuBar(
  menus: [
    PlatformMenu(label: 'File', menus: [
      PlatformMenuItem(label: 'Open EPUB...', shortcut: Cmd+O),
      PlatformMenuItem(label: 'Import Dictionary...'),
    ]),
    PlatformMenu(label: 'Edit', menus: [
      PlatformMenuItem(label: 'Look Up in Dictionary', shortcut: Cmd+D),
      PlatformMenuItem(label: 'Export to Anki', shortcut: Cmd+E),
    ]),
    PlatformMenu(label: 'View', menus: [
      PlatformMenuItem(label: 'Enter Fullscreen', shortcut: Cmd+Ctrl+F),
    ]),
  ],
)
```

### 4c. Window Management

- Window title bar: Show current book title
- Window size/position persistence: `window_manager` package (needs to be added to pubspec.yaml)
- Minimum window size: 800x600

### 4d. Drag and Drop

- Accept `.epub` and `.zip` (dictionary) files dropped onto the window
- Use `desktop_drop` package (needs to be added to pubspec.yaml)
- Route to import dialog based on file extension

### 4e. macOS UI Shell Decision

**Option A: Material Design (Phase 2 MVP)**
- Reuse existing Android UI as-is
- Minimal work, fastest to ship
- Looks foreign on macOS but fully functional

**Option B: macos_ui (Phase 4 polish)**
- Native macOS sidebar navigation
- MacosScaffold with toolbar
- Looks native but significant UI rewrite

**Recommendation:** Ship Phase 2 with Material Design (Option A). Add macos_ui as a Phase 4 polish task if user demand justifies the effort.

---

## Task 5: AnkiConnect Verification

**Goal:** Verify AnkiConnect HTTP backend works on macOS.

### Steps

1. Install Anki Desktop for macOS + AnkiConnect add-on
2. Launch Hibiki → Settings → Anki → verify connection
3. Test: look up word → export to Anki → verify card appears in Anki
4. Test: duplicate detection
5. Test: model/deck selection

### Expected Result

AnkiConnect implementation from Phase 1 (`AnkiConnectRepository`) is pure HTTP — should work identically on macOS. The `ankiRepositoryProvider` (`anki_view_model.dart:114-117`) returns `AnkiConnectRepository()` as the default for all non-Android platforms, so macOS gets HTTP backend without additional code changes.

### Verification

```
App connects to AnkiConnect → deck list loads → card export succeeds → duplicate detected
```

---

## Task 6: Audio System Verification

**Goal:** Verify audiobook playback and recording work on macOS.

### Components

| Component | Package | macOS Status |
|-----------|---------|-------------|
| Playback | just_audio | Supported (uses AVFoundation) |
| Media controls | audio_service | Not needed (desktop process stays alive) |
| Recording | record_mp3_plus | Android-only; **not needed for MVP** |
| TTS | flutter_tts | Supported (uses AVSpeechSynthesizer) |

### Steps

1. Import audiobook (m4b) + subtitle (srt)
2. Play → verify audio output
3. Verify subtitle sync (cue highlighting)
4. Test TTS on selected text

### Known Gap

`audio_service` for media notification integration on macOS uses `MPNowPlayingInfoCenter`. This is handled by `just_audio`'s macOS implementation. No additional work needed.

### Verification

```
Audiobook plays → subtitles sync → TTS speaks selected text
```

---

## Execution Order

1. **Task 1** — Create macOS project structure (entitlements, Podfile, Info.plist)
2. **Task 2** — hoshidicts native library (CMake Apple targets + podspec)
3. **Build gate:** `flutter build macos --debug` succeeds
4. **Task 3** — WKWebView EPUB reader verification
5. **Task 5** — AnkiConnect verification (quick — pure HTTP reuse)
6. **Task 6** — Audio system verification
7. **Task 4** — macOS-specific features (keyboard, menu bar, drag-drop)

## Risk Register

| # | Risk | Impact | Probability | Mitigation |
|---|------|--------|-------------|------------|
| 1 | Apple Clang doesn't support C++23 features used by glaze | hoshidicts won't compile | Low (Xcode 15+ has C++23) | Pin Xcode 15.2+; fallback to `c++2b` flag |
| 2 | WKWebView blocks local file:// access in sandboxed app | EPUB images/fonts won't load | Medium | Use custom URL scheme handler or local HTTP server |
| 3 | CocoaPods zstd/libdeflate compilation issues on Apple Silicon | Build failure | Low | Use `-arch arm64 x86_64` universal build; or vendor pre-built static libs |
| 4 | macOS sandbox blocks AnkiConnect localhost HTTP | Anki integration fails | Low | Entitlement `com.apple.security.network.client` allows loopback |
| 5 | No Mac hardware available | Phase 2 blocked entirely | Medium | GitHub Actions macOS runner for CI; cloud Mac for debugging |
| 6 | flutter_inappwebview macOS WebView flicker/crash | Reader unusable | Low | Fallback to `macos_webview_kit` or embedded WKWebView |

## Exit Criteria

- [ ] `flutter build macos --debug` and `--release` succeed
- [ ] App launches on macOS, shows home screen, no crashes
- [ ] Dictionary import + search works (hoshidicts FFI functional)
- [ ] EPUB reader renders text (WKWebView)
- [ ] Word selection → dictionary popup works
- [ ] Anki export via AnkiConnect works
- [ ] Audiobook playback + subtitle sync works
- [ ] Keyboard shortcuts work (page turn, Cmd+D, Cmd+E)
- [ ] macOS menu bar present and functional
- [ ] Android APK still builds and passes tests (no regression)
- [ ] Windows build still works (Phase 1 regression check)

## Estimated Duration

**3-4 weeks** (assuming Mac hardware available from day 1)
- Week 1: Tasks 1-2 (project setup + native library)
- Week 2: Tasks 3-5 (WebView + Anki + Audio verification)
- Week 3: Task 4 (macOS-specific features)
- Week 4: Bug fixes, edge cases, polish
