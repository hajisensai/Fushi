import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows runner → Dart bridge for an IME-owned physical Space press.
///
/// Windows reports an IME-consumed key-down as `VK_PROCESSKEY`. Flutter's
/// Windows embedder deliberately clears that event's physical/logical identity
/// before it reaches [KeyEvent], so the video page cannot recover Space from
/// the framework event. The runner still has the original scan code and emits
/// [onImeSpaceDown] only for the unmodified Space make-code.
abstract final class WindowsImeSpaceChannel {
  static const MethodChannel _channel =
      MethodChannel('app.fushi/windows_ime_space');

  static Object? _owner;
  static VoidCallback? _handler;

  /// Installs the one active consumer.
  ///
  /// [owner] prevents an older video route from clearing a newer replacement
  /// route's handler during overlapping route disposal.
  static void setHandler(Object owner, VoidCallback handler) {
    _owner = owner;
    _handler = handler;
    _channel.setMethodCallHandler(_dispatch);
  }

  /// Removes the handler only when [owner] still owns it.
  static void clearHandler(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _handler = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<Object?> _dispatch(MethodCall call) async {
    if (call.method == 'onImeSpaceDown') {
      _handler?.call();
    }
    return null;
  }

  @visibleForTesting
  static Future<Object?> debugDispatch(MethodCall call) => _dispatch(call);
}
