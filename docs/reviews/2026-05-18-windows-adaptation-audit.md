# Windows Adaptation Audit — 2026-05-18

## Round 1: Full Windows Platform Adaptation Review

### Scope

Complete audit of all Windows-specific code paths in `hibiki/lib/`:
- WebView2 (InAppWebView) integration
- Platform guards (MethodChannel, SystemChrome, WakelockPlus)
- File path handling (URI construction, EPUB extraction, asset resolution)
- Native library integration (hoshidicts FFI)
- UI responsiveness (keyboard navigation, window resizing)
- Build verification (flutter analyze + flutter build windows)

### Findings

#### HBK-AUDIT-W01: All critical Windows adaptations verified correct

- **severity**: info
- **status**: verified
- **summary**: No new Windows adaptation issues found. All existing adaptations are correct and complete.

**Verified adaptation categories:**

| Category | Files | Status |
|----------|-------|--------|
| WebView2 onReceivedError for hoshi.local | reader_hoshi_page.dart:1319-1330 | Correctly treats intercepted domain errors as success |
| RAF→setTimeout (paginated init) | reader_pagination_scripts.dart:690-723 | Committed in cef74251 |
| RAF→setTimeout (continuous init) | reader_pagination_scripts.dart:894-923 | Committed in 0a4fce60 |
| file:// URI construction | webview_asset_url.dart, dictionary_popup_webview.dart | Uses Uri.file() correctly on Windows |
| TTS channel guard | tts_channel.dart:14 | `_isSupported = Platform.isAndroid` — all methods return no-op |
| WakelockPlus guard (startup) | main.dart:51-53 | `if (Platform.isAndroid \|\| Platform.isIOS)` |
| WakelockPlus (reader/audiobook) | reader_hoshi_page.dart, hoshi_settings_page.dart, audiobook_play_bar.dart | All wrapped in try-catch — safe |
| WebView warmup skip (desktop) | main.dart:154 | Correctly skips HeadlessInAppWebView on desktop |
| VolumeKeyChannel | volume_key_channel.dart:39 | Catches MissingPluginException |
| AudioService.init | app_model.dart:3390-3431 | try-catch with direct JidoujishoAudioHandler fallback |
| Keyboard navigation | reader_hoshi_page.dart:2261-2279 | PageUp/Down, Arrow keys implemented |
| Window resize handling | reader_hoshi_page.dart:678-686 | WidgetsBindingObserver.didChangeMetrics → _syncPageSize |
| EPUB path handling | epub_parser.dart, epub_storage.dart | p.join() + p.canonicalize() — platform agnostic |
| Dictionary custom schemes | dictionary_webview_media.dart | image:// and dictmedia:// correctly handled |
| hoshidicts native DLL | windows/CMakeLists.txt:92-93 | Installed alongside executable |

#### HBK-AUDIT-W02: Runtime requestAnimationFrame uses are safe

- **severity**: info
- **status**: verified
- **files**: reader_pagination_scripts.dart:557,595,809,976; highlight_bridge.dart:159; lyrics_mode_html.dart:113,115

These RAF calls run during active rendering (scroll events, snap scrolling, resize handling, animation) — not during WebView2 initialization. The initialization-time RAF calls (restoreProgress, jumpToFragment) were already replaced with setTimeout in commits cef74251 and 0a4fce60.

#### HBK-AUDIT-W03: False positives eliminated

- **severity**: info
- **status**: not-a-bug

The following were investigated and determined NOT to be issues:
1. **SystemChrome calls without platform guards**: No-op on desktop, won't crash
2. **Dart readAsStringSync() encoding**: Defaults to UTF-8 on all platforms (not Windows UTF-16 LE)
3. **window.flutter_inappwebview.callHandler in JS**: Supported on WebView2 by the plugin
4. **popup_main.dart unguarded SystemChrome**: Android-only entry point, never called on Windows
5. **miscellaneous_settings_page.dart icon channel**: UI section gated by `if (Platform.isAndroid)`
6. **FloatingDictChannel setup**: Just registers callbacks; service never starts on Windows

### Build Verification

- `flutter analyze`: **No issues found** (22.5s)
- `flutter build windows --debug`: **Success** — built `build\windows\x64\runner\Debug\hibiki.exe` (11.9s)

### Next Scope

No further Windows adaptation issues to investigate. The platform adaptation is complete and verified.
