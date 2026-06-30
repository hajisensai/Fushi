# Phase 3: iOS Port

> **Date:** 2026-05-19
> **Branch:** feature/multiplatform
> **Prerequisite:** Phase 2 complete (macOS port verified), Apple Developer account, iOS deployment certificate
> **Design Spec:** `docs/specs/2026-05-16-multiplatform-design.md`
> **Audit:** `docs/reviews/2026-05-19-multiplatform-readiness-audit.md`

## Goal

Get Hibiki running on iOS (iPhone + iPad) with full functionality: dictionary import/query, EPUB reading (WKWebView), Anki (.apkg export), audiobook playback. Use Cupertino widgets for native iOS feel; adaptive layout for iPad.

## Current State

- `hibiki/ios/` exists (Flutter default scaffold: Podfile, Runner.xcodeproj, AppDelegate.swift)
- hoshidicts FFI bindings already have iOS path: `DynamicLibrary.process()` (assumes static linking)
- `flutter_inappwebview` 6.1.5 supports iOS (WKWebView) — same engine as macOS
- Anki integration: iOS needs `.apkg` export (AnkiDroid MethodChannel and AnkiConnect HTTP are both unavailable on iOS)
- All MethodChannel calls guarded (Phase 1)
- Audio playback via `just_audio` supports iOS (AVFoundation)
- Phase 2 will resolve most WKWebView issues (shared engine with macOS)

## Hardware Prerequisite

Same Mac hardware as Phase 2 (Xcode), plus:
- iOS Simulator (included with Xcode) for initial development
- Physical iPhone/iPad for final testing (especially WebView rendering, audio session behavior)
- Apple Developer Program membership ($99/year) for TestFlight/App Store distribution

---

## Task 1: iOS Project Configuration

**Goal:** Configure the existing iOS Runner for Hibiki.

### Steps

1. Update `ios/Podfile`:
   ```ruby
   platform :ios, '12.0'
   ```
   Rationale: iOS 12.0 is minimum for Flutter 3.41; also ensures broad device coverage (iPhone 6S+).

2. Update `ios/Runner/Info.plist`:
   - `CFBundleDisplayName`: Hibiki
   - `CFBundleIdentifier`: `app.hibiki.reader`
   - Add document type associations:
     ```xml
     <key>CFBundleDocumentTypes</key>
     <array>
       <dict>
         <key>CFBundleTypeName</key><string>EPUB</string>
         <key>LSItemContentTypes</key>
         <array><string>org.idpf.epub-container</string></array>
         <key>LSHandlerRank</key><string>Alternate</string>
       </dict>
     </array>
     ```
   - Add URL scheme:
     ```xml
     <key>CFBundleURLTypes</key>
     <array>
       <dict>
         <key>CFBundleURLSchemes</key>
         <array><string>hibiki</string></array>
       </dict>
     </array>
     ```
   - Add `NSAppTransportSecurity` for local asset server (`hoshi.local` HTTP on localhost):
     ```xml
     <key>NSAppTransportSecurity</key>
     <dict>
       <key>NSAllowsLocalNetworking</key><true/>
     </dict>
     ```
     Note: iOS uses .apkg export, not AnkiConnect HTTP — this exception is for the EPUB reader's local asset server only.
   - Audio background mode (for audiobook):
     ```xml
     <key>UIBackgroundModes</key>
     <array><string>audio</string></array>
     ```

3. Create `ios/Runner/Runner.entitlements`:
   ```xml
   <key>com.apple.security.application-groups</key>
   <array><string>group.app.hibiki.reader</string></array>
   ```
   Required for Share Extension data sharing.

4. Update `ios/Runner/Assets.xcassets` with Hibiki app icon (1024x1024 master + all required sizes).

5. Set Xcode build settings:
   - `IPHONEOS_DEPLOYMENT_TARGET = 12.0`
   - `TARGETED_DEVICE_FAMILY = 1,2` (iPhone + iPad)
   - Code signing identity and provisioning profile

### Verification

```bash
flutter build ios --debug --no-codesign
# Build succeeds without signing (CI/initial development)
```

---

## Task 2: hoshidicts iOS Native Library (Static Linking)

**Goal:** Compile hoshidicts C++ as a static library and link it into the iOS app binary.

### Key Difference from macOS

iOS does not allow loading dynamic libraries at runtime (`DynamicLibrary.open()` is forbidden in sandboxed iOS apps). The FFI code already handles this correctly:

```dart
if (Platform.isIOS) return DynamicLibrary.process();
```

`DynamicLibrary.process()` finds symbols in the main executable — this requires **static linking**.

### Approach: CocoaPods Source Compilation

Create an iOS podspec that compiles hoshidicts C++ source directly into the app binary as a static library.

#### 2a. Create iOS podspec

File: `native/hoshidicts/hoshidicts_native.podspec` (shared with macOS — same file)

> **Recommended approach:** Use a single multi-platform podspec instead of separate files per platform. CocoaPods resolves `:path` references by `s.name`, so having two files with the same pod name in the same directory causes conflicts.

```ruby
Pod::Spec.new do |s|
  s.name             = 'hoshidicts_native'
  s.version          = '1.0.0'
  s.summary          = 'Hoshidicts C++ dictionary engine'
  s.homepage         = 'https://github.com/hajisensai/hibiki'
  s.license          = { :type => 'MIT' }
  s.author           = 'Hibiki'
  s.source           = { :path => '.' }

  # Multi-platform: macOS dynamic, iOS static
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
    zstd.pod_target_xcconfig = {
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) ZSTD_DISABLE_ASM',
    }
  end

  s.subspec 'libdeflate' do |ld|
    ld.source_files = 'hoshidicts_external/libdeflate/lib/**/*.{c,h}'
  end
end
```

#### 2b. Reference from Podfile

Add to `hibiki/ios/Podfile`:
```ruby
pod 'hoshidicts_native', :path => '../../native/hoshidicts'
```

#### 2c. CMake Apple target additions

Add to `native/hoshidicts/CMakeLists.txt` for standalone builds (CI/testing):

```cmake
if(APPLE AND NOT ANDROID)
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)
  set(CMAKE_CXX_VISIBILITY_PRESET hidden)
  set(CMAKE_C_VISIBILITY_PRESET hidden)
  set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

  if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "")
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")
    # iOS: build as static library (no dynamic loading in sandbox)
    set_target_properties(hoshidicts_ffi PROPERTIES
      FRAMEWORK FALSE
    )
  else()
    # macOS: dynamic library with proper rpath
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.15" CACHE STRING "")
    set_target_properties(hoshidicts_ffi PROPERTIES
      INSTALL_NAME_DIR "@rpath"
      BUILD_WITH_INSTALL_RPATH ON
      MACOSX_RPATH ON
    )
  endif()
endif()
```

### Risk: 32MB Stack Thread on iOS

`platform.hpp` uses `pthread_create` with 32MB stack for dictionary import (`hoshidicts_ffi.cpp:219`). iOS enforces lower thread stack limits than desktop:
- Default thread stack: 512KB on iOS
- Maximum practical: ~8MB (system enforced, may vary)

**Investigation result (2026-05-19):** `importer.cpp` already uses `std::vector<char>` for ALL decompression and data buffers (heap-allocated). There are no large stack-allocated arrays. The 32MB stack was an excessive safety margin, not a functional requirement.

**Mitigation:** Reduce thread stack to 8MB in `hoshidicts_ffi.cpp:219` (`32 * 1024 * 1024` → `8 * 1024 * 1024`). This is safe because all buffers are heap-allocated via `std::vector`. No `importer.cpp` refactoring needed.

### Verification

```bash
cd hibiki/ios && pod install
flutter build ios --debug --no-codesign
# App launches in Simulator; dictionary import succeeds
```

---

## Task 3: WKWebView EPUB Reader (iOS)

**Goal:** Verify EPUB reader works on iOS WKWebView (shared engine with macOS from Phase 2).

### iOS-Specific Concerns

| Concern | Detail | Mitigation |
|---------|--------|------------|
| Safe area insets | Notch/Dynamic Island clips content | Respect `MediaQuery.of(context).padding` in reader layout |
| Text selection | Long-press triggers iOS system menu + dictionary | Suppress system callout via CSS `-webkit-touch-callout: none`; use custom JS selection handler |
| Scroll/swipe conflicts | iOS gesture recognizer conflicts with WebView scroll | Use `gestureRecognizers` parameter on `InAppWebView` to configure priority |
| Viewport meta | Mobile viewport scaling | Ensure `<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">` |
| WKWebView content process | Separate process, may be killed by OS under memory pressure | Handle `onWebViewClosed` / reload on `viewDidAppear` |

### Steps

1. Open EPUB in reader → verify rendering (font, layout, images)
2. Test paginated mode (swipe left/right to turn pages)
3. Test continuous scroll mode
4. Test word selection → dictionary popup
5. Test on iPhone SE (small screen) and iPad Pro (large screen)
6. Test with Dynamic Island device (safe area handling)
7. Test memory pressure: open large EPUB, switch apps, return

### Verification

```
EPUB renders → page turn works → word tap shows dict → safe area correct → survives backgrounding
```

---

## Task 4: Anki Integration (.apkg Export)

**Goal:** Implement .apkg file export as the iOS Anki integration method.

### Why .apkg?

- AnkiDroid (Android MethodChannel) — unavailable on iOS
- AnkiConnect (HTTP localhost) — AnkiMobile doesn't support AnkiConnect add-on
- **.apkg export** — universal Anki format; user imports into AnkiMobile or syncs via AnkiWeb

### Required Code Change: ankiRepositoryProvider

Current `ankiRepositoryProvider` (in `anki_view_model.dart:114-117`) returns `AnkiConnectRepository()` for all non-Android platforms, including iOS. iOS cannot use AnkiConnect — must be changed:

```dart
final ankiRepositoryProvider = Provider<BaseAnkiRepository>((_) {
  if (Platform.isAndroid) return AnkiRepository();
  if (Platform.isIOS) return ApkgExportRepository(); // New: .apkg export
  return AnkiConnectRepository(); // Windows, macOS: AnkiConnect HTTP
});
```

`ApkgExportRepository` implements `BaseAnkiRepository` with `.apkg` file generation instead of HTTP calls. Must be created as part of this task.

### .apkg Format Specification

A `.apkg` file is a ZIP containing:
```
collection.anki21    # SQLite database with notes, cards, decks, models
media                # JSON mapping: {"0": "filename.mp3", "1": "image.jpg"}
0                    # Media file referenced as "0" in the mapping
1                    # Media file referenced as "1"
```

### Implementation

#### 4a. SQLite Schema for collection.anki21

```sql
CREATE TABLE col (
  id integer PRIMARY KEY,
  crt integer NOT NULL,       -- creation timestamp
  mod integer NOT NULL,       -- modification timestamp
  scm integer NOT NULL,       -- schema mod time
  ver integer NOT NULL,       -- version (11)
  dty integer NOT NULL,       -- dirty (0)
  usn integer NOT NULL,       -- update sequence number (-1)
  ls integer NOT NULL,        -- last sync
  conf text NOT NULL,         -- JSON config
  models text NOT NULL,       -- JSON model definitions
  decks text NOT NULL,        -- JSON deck definitions
  dconf text NOT NULL,        -- JSON deck config
  tags text NOT NULL          -- JSON tags
);

CREATE TABLE notes (
  id integer PRIMARY KEY,
  guid text NOT NULL,
  mid integer NOT NULL,       -- model id
  mod integer NOT NULL,
  usn integer NOT NULL,
  tags text NOT NULL,
  flds text NOT NULL,         -- fields separated by \x1f
  sfld text NOT NULL,         -- sort field
  csum integer NOT NULL,      -- checksum of first field
  flags integer NOT NULL,
  data text NOT NULL
);

CREATE TABLE cards (
  id integer PRIMARY KEY,
  nid integer NOT NULL,       -- note id
  did integer NOT NULL,       -- deck id
  ord integer NOT NULL,       -- card template ordinal
  mod integer NOT NULL,
  usn integer NOT NULL,
  type integer NOT NULL,      -- 0=new
  queue integer NOT NULL,     -- 0=new
  due integer NOT NULL,
  ivl integer NOT NULL,
  factor integer NOT NULL,
  reps integer NOT NULL,
  lapses integer NOT NULL,
  left integer NOT NULL,
  odue integer NOT NULL,
  odid integer NOT NULL,
  flags integer NOT NULL,
  data text NOT NULL
);

CREATE TABLE revlog (
  id integer PRIMARY KEY,
  cid integer NOT NULL,
  usn integer NOT NULL,
  ease integer NOT NULL,
  ivl integer NOT NULL,
  lastIvl integer NOT NULL,
  factor integer NOT NULL,
  time integer NOT NULL,
  type integer NOT NULL
);
```

#### 4b. ApkgExportService

```dart
// packages/hibiki_anki/lib/src/apkg_export_service.dart
abstract class ApkgExportService {
  Future<File> exportNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    required List<MediaFile> mediaFiles,
  });

  Future<File> exportBatch({
    required String deckName,
    required String modelName,
    required List<Map<String, String>> notes,
  });
}
```

#### 4c. Share Sheet Integration

After generating `.apkg`:
```dart
await Share.shareXFiles(
  [XFile(apkgPath)],
  subject: 'Hibiki Anki Export',
);
```

User can then:
1. Open in AnkiMobile directly
2. Save to Files app
3. Share to other apps

### Limitations

- **No duplicate detection** — can't query AnkiMobile's database
- **No deck/model listing** — user must type deck name manually (or use presets)
- **One-way export** — cards can't be updated, only added

### UI Changes

The Anki export dialog on iOS needs different UI:
- Remove "deck selector" dropdown (type manually or use preset)
- Remove "model selector" (use embedded default model)
- Add "Export" button that generates .apkg and opens Share Sheet
- Show clear explanation: "Cards will be exported as .apkg file. Import into AnkiMobile."

### Verification

```
Look up word → tap Anki → fill fields → Export → .apkg opens in AnkiMobile → card visible
```

---

## Task 5: iOS-Specific Features

### 5a. iPad Adaptive Layout

Detect screen width and switch layout:

```dart
final isWideScreen = MediaQuery.of(context).size.width >= 768;
```

| Layout | Phone | iPad Portrait | iPad Landscape |
|--------|-------|---------------|----------------|
| Navigation | CupertinoTabBar | CupertinoTabBar | Sidebar + content |
| Reader + Dict | Full-screen + bottom sheet | Full-screen + side panel | Side-by-side |
| Dictionary popup | Bottom sheet | Floating panel | Side panel |

iPad-specific features:
- **Split View / Slide Over**: Add `UISupportsMultipleScenes` to Info.plist
- **External keyboard**: Reuse desktop keyboard shortcuts (Phase 2)
- **Apple Pencil**: Selection via pencil pressure (future enhancement)

### 5b. Share Extension

Create `ios/ShareExtension/` target to receive text from other apps:

```swift
// ShareViewController.swift
import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let itemProvider = extensionItem.attachments?.first else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            itemProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                guard let text = item as? String else { return }
                let userDefaults = UserDefaults(suiteName: "group.app.hibiki.reader")
                userDefaults?.set(text, forKey: "sharedText")
                // Open main app with URL scheme
                if let url = URL(string: "hibiki://lookup?text=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                    self?.openURL(url)
                }
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    @objc private func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication { app.open(url); return }
            responder = r.next
        }
    }
}
```

> **Note:** `SLComposeServiceViewController` (Social framework) is deprecated. Use `UIViewController` with `NSExtensionItem` / `NSItemProvider` for modern Share Extensions.

This replaces Android's `receive_intent` + `ACTION_PROCESS_TEXT`.

### 5c. Audio Session Management

iOS has strict audio session rules:

```dart
final session = await AudioSession.instance;
await session.configure(AudioSessionConfiguration(
  avAudioSessionCategory: AVAudioSessionCategory.playback,
  avAudioSessionMode: AVAudioSessionMode.spokenAudio,
  avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
  avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
));
```

Already partially configured in the codebase (verified in audio session guards from Phase 1).

### 5d. App Transport Security

If the app makes HTTP (non-HTTPS) requests:
- Local asset server (`hoshi.local`): Runs on localhost, allowed via `NSAllowsLocalNetworking` (already in Task 1)
- External URLs: Must be HTTPS (no action needed — all external requests already use HTTPS)
- Note: iOS uses .apkg file export for Anki, not AnkiConnect HTTP — no localhost Anki connection needed

### Verification

```
iPad layout adapts to orientation → Share Extension receives text → Audio session works in background
```

---

## Task 6: App Store Preparation

**Goal:** Prepare for TestFlight and App Store submission.

### Requirements

| Item | Status | Action |
|------|--------|--------|
| App icon (1024x1024) | Needed | Create/adapt from Android icon |
| Launch screen | Needed | Create `LaunchScreen.storyboard` |
| Privacy policy URL | Needed | Host on GitHub Pages or website |
| App Store description | Needed | Write Japanese learning app description |
| Screenshots | Needed | Capture on iPhone 15 Pro Max + iPad Pro |
| Privacy nutrition labels | Needed | Declare: no data collection, no tracking |
| Export compliance | Needed | "Uses encryption: No" (SQLite is not classified) |
| Review notes | Needed | Explain AnkiMobile integration, dictionary import flow |

### TestFlight Distribution

1. Archive with `flutter build ipa`
2. Upload to App Store Connect via `xcrun altool` or Transporter
3. Add internal testers
4. Iterate based on feedback

### App Store Review Risks

| Risk | Mitigation |
|------|------------|
| "Duplicate app" (if similar to jidoujisho) | Clearly differentiate in description; different bundle ID |
| "Requires third-party app" (AnkiMobile) | .apkg export works standalone; Anki is optional |
| "User-generated content" (dictionary import) | Dictionaries are user's own files; no UGC platform |
| "Hidden features" (Share Extension) | Document in review notes |

---

## Execution Order

1. **Task 1** — iOS project configuration (Info.plist, Podfile, entitlements)
2. **Task 2** — hoshidicts static library (podspec, compilation)
3. **Build gate:** `flutter build ios --debug --no-codesign` succeeds
4. **Task 3** — WKWebView EPUB reader (leverage Phase 2 macOS findings)
5. **Task 4** — .apkg export implementation
6. **Task 5a** — iPad adaptive layout
7. **Task 5b** — Share Extension
8. **Task 5c-d** — Audio session + ATS verification
9. **Task 6** — App Store preparation

## Risk Register

| # | Risk | Impact | Probability | Mitigation |
|---|------|--------|-------------|------------|
| 1 | 32MB pthread stack on iOS | Dictionary import crashes | Low | Buffers already heap-allocated (`std::vector`); reduce stack to 8MB in `hoshidicts_ffi.cpp:219` |
| 2 | C++23 requires Xcode 15+ | Limits iOS deployment to recent Xcode | Low | Xcode 15 supports iOS 12+; no user-facing limitation |
| 3 | WKWebView content process killed under memory pressure | Reader loses state | Medium | Save reading position frequently; restore on reload |
| 4 | .apkg format compatibility with AnkiMobile | Import fails or cards malformed | Low | Test against AnkiMobile 23.x; use Anki 2.1 schema |
| 5 | App Store review rejects | Distribution delayed | Medium | Prepare thorough review notes; TestFlight first |
| 6 | iPad multitasking (Split View) breaks layout | UI unusable on iPad | Low | Test with all Split View sizes; use MediaQuery |
| 7 | Share Extension crashes or fails silently | Feature unusable | Low | Extensive error handling; App Groups for data sharing |

## Exit Criteria

- [ ] `flutter build ipa` succeeds
- [ ] App launches on iPhone Simulator, shows home screen
- [ ] App launches on iPad Simulator with adaptive layout
- [ ] Dictionary import + search works (hoshidicts static FFI)
- [ ] EPUB reader renders (WKWebView)
- [ ] Word selection → dictionary popup works
- [ ] .apkg export generates valid file → imports into AnkiMobile
- [ ] Audiobook playback + subtitle sync works
- [ ] Share Extension receives text from other apps
- [ ] Background audio continues when app is backgrounded
- [ ] Android APK and Windows build still work (no regression)
- [ ] TestFlight build uploaded and installable

## Estimated Duration

**3-4 weeks** (starting after Phase 2 macOS completion)
- Week 1: Tasks 1-2 (project config + native library)
- Week 2: Tasks 3-4 (WebView + .apkg export)
- Week 3: Task 5 (iPad layout, Share Extension, audio)
- Week 4: Task 6 (App Store prep, TestFlight, bug fixes)
