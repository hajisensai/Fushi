import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';

/// Restores desktop_drop's OS-level drag-and-drop registration on Windows after
/// it has been usurped by a WebView2 controller (TODO-1275 / BUG-361).
///
/// Root cause: on Windows, opening a reader/video/lookup WebView2 makes the
/// WebView2 runtime register its own `IDropTarget` on the host window (default
/// `AllowExternalDrop=TRUE`), evicting the one `desktop_drop` registered once at
/// startup. When the controller is torn down — or when the fork sets
/// `put_AllowExternalDrop(FALSE)` after the fact — WebView2 revokes its target
/// WITHOUT restoring desktop_drop's, leaving the host window with no valid
/// `IDropTarget`. Drag-import then shows the "forbidden" cursor app-wide until
/// the app restarts. `put_AllowExternalDrop(FALSE)` alone cannot fix this
/// because it runs after the controller already hijacked the registration, and
/// desktop_drop's OS registration is a one-time C++ call that Dart cannot
/// otherwise re-trigger.
///
/// The vendored ci-patch to `desktop_drop` (see
/// `ci/patches/hosted/desktop_drop-0.5.0/windows/desktop_drop_plugin.cpp`) adds
/// a `reinitialize` method that re-runs `RevokeDragDrop` + `RegisterDragDrop`.
/// [reinitialize] invokes it after media closes, restoring drag-import
/// regardless of which controller usurped the window.
class DesktopDropReinitializer {
  const DesktopDropReinitializer._();

  /// The channel name is fixed by the `desktop_drop` plugin.
  static const MethodChannel _channel = MethodChannel('desktop_drop');

  /// Re-asserts the host window's drop registration. Windows-only; a no-op on
  /// every other platform (the WebView2 hijack is Windows-specific).
  static Future<void> reinitialize() async {
    if (kIsWeb || !Platform.isWindows) {
      return;
    }
    await invokeReinitialize();
  }

  /// Performs the raw channel invocation. Swallows [MissingPluginException] so
  /// an unpatched desktop_drop (older version / drifted patch) is a silent
  /// no-op rather than a crash. Exposed for tests, which cannot vary the host
  /// [Platform].
  @visibleForTesting
  static Future<void> invokeReinitialize() async {
    try {
      await _channel.invokeMethod<void>('reinitialize');
    } on MissingPluginException {
      // desktop_drop without the TODO-1275 patch: nothing to restore.
    } catch (e) {
      debugPrint('[hibiki-drop] reinitialize failed: $e');
    }
  }
}
