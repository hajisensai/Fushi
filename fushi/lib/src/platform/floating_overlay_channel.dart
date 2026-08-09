import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Base class for Android floating overlay MethodChannel bindings.
///
/// Provides the four common operations shared by [FloatingDictChannel] and
/// [FloatingLyricChannel]. Subclasses pass their concrete [MethodChannel] to
/// the constructor and may override [isSupported] to inject a test value.
abstract class FloatingOverlayChannel {
  const FloatingOverlayChannel(this.channel);

  final MethodChannel channel;

  /// Returns true when the overlay APIs are available.
  /// Override in tests via a subclass getter.
  bool get isSupported => Platform.isAndroid;

  /// Uniform platform-boundary guard (HBK-AUDIT-133). Callers (reader page,
  /// app_model) consume these results without their own try/catch, so a
  /// natively-thrown [PlatformException] — or a [MissingPluginException] when
  /// the channel is absent — must not propagate as a crash. Both are folded
  /// into the same safe default the [isSupported] gate already returns.
  Future<T?> _safeInvoke<T>(String method, [Object? arguments]) async {
    if (!isSupported) return null;
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('FloatingOverlayChannel.$method failed: $e');
      }
      return null;
    }
  }

  Future<bool> canDrawOverlaysImpl() async {
    final bool? result = await _safeInvoke<bool>('canDrawOverlays');
    return result ?? false;
  }

  Future<bool> showImpl([Object? arguments]) async {
    final bool? result = await _safeInvoke<bool>('show', arguments);
    return result ?? false;
  }

  Future<void> hideImpl() async {
    await _safeInvoke<void>('hide');
  }

  Future<bool> isShowingImpl() async {
    final bool? result = await _safeInvoke<bool>('isShowing');
    return result ?? false;
  }
}
