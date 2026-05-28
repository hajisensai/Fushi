import 'dart:io' show Platform;

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

  Future<bool> canDrawOverlaysImpl() async {
    if (!isSupported) return false;
    final bool? result = await channel.invokeMethod<bool>('canDrawOverlays');
    return result ?? false;
  }

  Future<bool> showImpl() async {
    if (!isSupported) return false;
    final bool? result = await channel.invokeMethod<bool>('show');
    return result ?? false;
  }

  Future<void> hideImpl() async {
    if (!isSupported) return;
    await channel.invokeMethod<void>('hide');
  }

  Future<bool> isShowingImpl() async {
    if (!isSupported) return false;
    final bool? result = await channel.invokeMethod<bool>('isShowing');
    return result ?? false;
  }
}
