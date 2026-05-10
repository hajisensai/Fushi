import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

/// Native bridge for hardware volume-key page turning.
///
/// Android's AudioManager consumes VOLUME_UP/DOWN before Flutter's key
/// pipeline sees them, so Focus.onKey can't reliably intercept them.
/// MainActivity overrides `dispatchKeyEvent` and forwards presses here
/// while [setInterceptEnabled] is on; toggle it off to restore normal
/// system volume behavior outside the reader.
class VolumeKeyChannel {
  VolumeKeyChannel._() {
    _channel.setMethodCallHandler(_onCall);
  }

  /// Singleton — the native channel is process-wide, so one instance is
  /// enough for the whole app.
  static final VolumeKeyChannel instance = VolumeKeyChannel._();

  static const MethodChannel _channel = HibikiChannels.volumeKeys;

  VoidCallback? _onVolumeUp;
  VoidCallback? _onVolumeDown;

  /// Register handlers for volume key-down events. Pass null to clear.
  void setHandlers({
    VoidCallback? onVolumeUp,
    VoidCallback? onVolumeDown,
  }) {
    _onVolumeUp = onVolumeUp;
    _onVolumeDown = onVolumeDown;
  }

  /// Turn native interception on/off. When off, volume keys pass through
  /// to the system so the hardware buttons adjust media volume as usual.
  Future<void> setInterceptEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setInterceptEnabled', enabled);
    } on MissingPluginException {
      // Non-Android platform; channel not wired. Silently ignore.
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'onVolumeUp':
        _onVolumeUp?.call();
        break;
      case 'onVolumeDown':
        _onVolumeDown?.call();
        break;
    }
    return null;
  }
}
