import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/platform/floating_overlay_channel.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

@immutable
class GalHookTextWindowRect {
  const GalHookTextWindowRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;

  bool get isValid => width > 0 && height > 0;

  Map<String, Object?> toMap() => <String, Object?>{
        'left': left,
        'top': top,
        'width': width,
        'height': height,
      };

  static GalHookTextWindowRect? fromMap(Map<Object?, Object?> map) {
    int? value(String key) => (map[key] as num?)?.toInt();
    final GalHookTextWindowRect rect = GalHookTextWindowRect(
      left: value('left') ?? 0,
      top: value('top') ?? 0,
      width: value('width') ?? 0,
      height: value('height') ?? 0,
    );
    return rect.isValid ? rect : null;
  }
}

typedef GalHookTextLookupHandler = FutureOr<void> Function(
  String lineId,
  String text,
  int index,
);
typedef GalHookTextEventHandler = FutureOr<void> Function();
typedef GalHookTextLockHandler = FutureOr<void> Function(bool locked);
typedef GalHookTextBoundsHandler = FutureOr<void> Function(
  GalHookTextWindowRect rect,
);

/// Windows Hook 台词浮窗的专用 MethodChannel 契约。
class GalHookTextOverlayChannel extends FloatingOverlayChannel {
  GalHookTextOverlayChannel._() : super(HibikiChannels.galHookText);

  static final GalHookTextOverlayChannel _instance =
      GalHookTextOverlayChannel._();

  @visibleForTesting
  static bool? platformOverride;

  @override
  bool get isSupported => platformOverride ?? Platform.isWindows;

  static bool get supportsCurrentPlatform => _instance.isSupported;

  static GalHookTextLookupHandler? _onLookupText;
  static GalHookTextEventHandler? _onToggleFollow;
  static GalHookTextEventHandler? _onTogglePassThrough;
  static GalHookTextEventHandler? _onToggleTransparency;
  static GalHookTextEventHandler? _onOpenWorkbench;
  static GalHookTextEventHandler? _onClose;
  static GalHookTextEventHandler? _onReplayVoice;
  static GalHookTextEventHandler? _onRecaptureVoice;
  static GalHookTextLockHandler? _onLockChanged;
  static GalHookTextBoundsHandler? _onBoundsChanged;

  static void setEventHandlers({
    GalHookTextLookupHandler? onLookupText,
    GalHookTextEventHandler? onToggleFollow,
    GalHookTextEventHandler? onTogglePassThrough,
    GalHookTextEventHandler? onToggleTransparency,
    GalHookTextEventHandler? onOpenWorkbench,
    GalHookTextEventHandler? onClose,
    GalHookTextEventHandler? onReplayVoice,
    GalHookTextEventHandler? onRecaptureVoice,
    GalHookTextLockHandler? onLockChanged,
    GalHookTextBoundsHandler? onBoundsChanged,
  }) {
    _onLookupText = onLookupText;
    _onToggleFollow = onToggleFollow;
    _onTogglePassThrough = onTogglePassThrough;
    _onToggleTransparency = onToggleTransparency;
    _onOpenWorkbench = onOpenWorkbench;
    _onClose = onClose;
    _onReplayVoice = onReplayVoice;
    _onRecaptureVoice = onRecaptureVoice;
    _onLockChanged = onLockChanged;
    _onBoundsChanged = onBoundsChanged;
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onToggleFollow = null;
    _onTogglePassThrough = null;
    _onToggleTransparency = null;
    _onOpenWorkbench = null;
    _onClose = null;
    _onReplayVoice = null;
    _onRecaptureVoice = null;
    _onLockChanged = null;
    _onBoundsChanged = null;
    _instance.channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final Object? arguments = call.arguments;
    final Map<Object?, Object?> args =
        arguments is Map ? arguments.cast<Object?, Object?>() : const {};
    switch (call.method) {
      case 'lookupText':
        final String lineId = args['lineId']?.toString() ?? '';
        final String text = args['text']?.toString() ?? '';
        final int index = (args['index'] as num?)?.toInt() ?? 0;
        if (lineId.isNotEmpty && text.trim().isNotEmpty) {
          await _onLookupText?.call(lineId, text, index);
        }
        break;
      case 'toggleFollow':
        await _onToggleFollow?.call();
        break;
      case 'togglePassThrough':
        await _onTogglePassThrough?.call();
        break;
      case 'toggleTransparency':
        await _onToggleTransparency?.call();
        break;
      case 'openWorkbench':
        await _onOpenWorkbench?.call();
        break;
      case 'replayVoice':
        await _onReplayVoice?.call();
        break;
      case 'recaptureVoice':
        await _onRecaptureVoice?.call();
        break;
      case 'close':
        await _onClose?.call();
        break;
      case 'lockChanged':
        await _onLockChanged?.call(args['locked'] == true);
        break;
      case 'windowRectChanged':
        final GalHookTextWindowRect? rect = GalHookTextWindowRect.fromMap(args);
        if (rect != null) await _onBoundsChanged?.call(rect);
        break;
      default:
        break;
    }
  }

  static Future<bool> show({
    GalHookTextWindowRect? rect,
    double fontSize = 24,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xE0000000,
    bool following = true,
    bool passThrough = false,
    bool locked = false,
  }) {
    return _instance.showImpl(<String, Object?>{
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'buttonTextColor': 0xFFFFFFFF,
      'buttonBgColor': 0x552D2340,
      'activeColor': 0xFFCE93D8,
      'windowWidth': 900.0,
      'windowHeight': 140.0,
      'clickLookupEnabled': true,
      'following': following,
      'passThrough': passThrough,
      'locked': locked,
      ...?rect?.toMap(),
    });
  }

  static Future<void> hide() => _instance.hideImpl();

  static Future<bool> isShowing() => _instance.isShowingImpl();

  static Future<void> updateText({
    required String lineId,
    required String text,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateText', <String, Object?>{
      'lineId': lineId,
      'text': text,
    });
  }

  static Future<void> updateStyle({
    required int bgColor,
    int textColor = 0xFFFFFFFF,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateStyle', <String, Object?>{
      'fontSize': 24.0,
      'bgColor': bgColor,
      'textColor': textColor,
      'buttonTextColor': 0xFFFFFFFF,
      'buttonBgColor': 0x552D2340,
      'activeColor': 0xFFCE93D8,
    });
  }

  static Future<void> setFollowing(bool following) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setFollowing',
      <String, Object?>{'following': following},
    );
  }

  static Future<void> setPassThrough(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setPassThrough',
      <String, Object?>{'enabled': enabled},
    );
  }

  /// 语音控件的可见状态（浮窗是独立窗口，用户只能在这里看到「正在试听 / 正在补录」）。
  static Future<void> setVoiceState({
    required bool replaying,
    required bool recapturing,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setVoiceState',
      <String, Object?>{
        'replaying': replaying,
        'recapturing': recapturing,
      },
    );
  }

  static Future<void> setLocked(bool locked) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setLocked',
      <String, Object?>{'locked': locked},
    );
  }
}
