import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Raises the Linux main window with a Wayland activation token.
///
/// On Wayland a client may not focus its own window; the compositor only
/// honours `xdg_activation_v1` with a token minted for a user action. The
/// GlobalShortcuts portal sends one with `Activated` (KDE sends none, then the
/// plain present below is all there is and the compositor may only mark the
/// window as demanding attention). The runner hands the token to GDK
/// (`gdk_wayland_display_set_startup_notification_id`) and presents the window,
/// which is how GtkApplication itself raises a window for a D-Bus activation.
/// On an X11 display (the Flatpak draws through XWayland) the token has no
/// meaning and the runner simply presents.
abstract final class LinuxWindowActivationChannel {
  /// Method name; runner `window_activation_method_cb` matches it verbatim.
  static const String presentMethod = 'presentWithActivationToken';

  /// Returns true when the runner presented the window (false: no window yet,
  /// first frame not shown, exiting, or an older runner without the method —
  /// the caller then falls back to its regular focus path).
  static Future<bool> present(String activationToken) async {
    try {
      final bool? presented = await FushiChannels.windowActivation
          .invokeMethod<bool>(presentMethod, activationToken);
      return presented ?? false;
    } on MissingPluginException catch (e) {
      debugPrint('[Fushi] window_activation unsupported by runner: $e');
      return false;
    } on PlatformException catch (e) {
      debugPrint('[Fushi] window_activation failed: $e');
      return false;
    }
  }
}
