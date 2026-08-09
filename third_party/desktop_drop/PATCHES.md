# desktop_drop 0.5.0 — vendored fork

Upstream: https://pub.dev/packages/desktop_drop (0.5.0, MixinNetwork).
Vendored (was a pub-cache ci-patch) so the cross-platform URL-drag delta lives as
tracked, diffable source. Pointed at by `fushi/pubspec.yaml` dependency_overrides.

## Deltas vs upstream 0.5.0

1. TODO-1275 / BUG-361 (Windows `windows/desktop_drop_plugin.cpp`)
   Re-assert the host-window OLE `IDropTarget` after a WebView2 controller usurps
   it (adds a `reinitialize` method handler + shared `RegisterDropTarget`). Without
   it, drag-import shows the forbidden cursor app-wide after opening/closing a
   reader/video/lookup WebView2. Guarded by
   `fushi/test/media/drag_drop/desktop_drop_reinit_test.dart`.

2. TODO-1306 — drag a URL (browser address bar / hyperlink) to import it as a
   stream video. Upstream only extracts file paths on all three desktop platforms,
   so a URL drag is silently dropped:
   - Windows `windows/desktop_drop_plugin.cpp`: when the data object has no
     CF_HDROP, extract `CFSTR_INETURLW` (or http(s)-guarded `CF_UNICODETEXT`) and
     push the URL string into the same `performOperation` list as file paths.
   - macOS `macos/Classes/DesktopDropPlugin.swift`: register the `.URL` dragged
     type and read a non-file `NSURL` from the pasteboard, appending its
     `absoluteString` as a "path".
   - Linux `lib/src/channel.dart` (`performOperation_linux`): the native side
     already forwards the full text/uri-list; the Dart layer dropped http(s) URIs
     because `Uri.toFilePath()` throws on non-file schemes. Preserve http(s) URIs
     verbatim.
   The URL rides the same channel as file paths; the app classifier
   (`classifyDroppedFiles`) disambiguates URLs from file paths by scheme and routes
   them to the stream-URL import (`_importStreamUrl`). Guarded by
   `fushi/test/media/drag_drop/url_drop_native_guard_test.dart`.
