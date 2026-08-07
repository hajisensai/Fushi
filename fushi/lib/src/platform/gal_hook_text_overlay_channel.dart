import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/platform/floating_overlay_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

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
  Rect? wordRect,
);
typedef GalHookTextEventHandler = FutureOr<void> Function();
typedef GalHookTextLockHandler = FutureOr<void> Function(bool locked);

/// native 侧穿透态被否决 / 变更时的回传（BUG-951）。native 建不出逃生工具条窗
/// 时会拒绝进入穿透并把自己摁回 false；Dart 必须跟着退回，否则它的标志卡在
/// true，用户下一次按 `↗` 会变成一次看不出反应的空点击。
typedef GalHookTextPassThroughHandler = FutureOr<void> Function(
  bool passThrough,
);
typedef GalHookTextBoundsHandler = FutureOr<void> Function(
  GalHookTextWindowRect rect,
);

/// Hook 台词浮窗的默认字号（逻辑 px）。
///
/// BUG-1095：以前 native 会在 hook 模式下按窗口高度对它做 0.9~2.5 倍缩放，于是
/// 「拖高浮窗」＝「放大台词」，可见行数几乎不涨，用户「放不下想拖高」永远无解。
/// 现在 native 直接用这个值（不再乘窗高比例），真值来自 `gal_hook_text_font_size`
/// 偏好；本常量只是它的默认值，等于旧公式在默认窗高（140dip）下的实际字号，
/// 所以没拖过窗的用户观感逐像素不变。
const double kGalHookTextFontSize = 30.0;

/// Windows Hook 台词浮窗的专用 MethodChannel 契约。
class GalHookTextOverlayChannel extends FloatingOverlayChannel {
  GalHookTextOverlayChannel._() : super(FushiChannels.galHookText);

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
  static GalHookTextPassThroughHandler? _onPassThroughChanged;
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
    GalHookTextPassThroughHandler? onPassThroughChanged,
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
    _onPassThroughChanged = onPassThroughChanged;
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
    _onPassThroughChanged = null;
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
          await _onLookupText?.call(lineId, text, index, _wordRect(args));
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
      case 'passThroughChanged':
        await _onPassThroughChanged?.call(args['passThrough'] == true);
        break;
      case 'windowRectChanged':
        final GalHookTextWindowRect? rect = GalHookTextWindowRect.fromMap(args);
        if (rect != null) await _onBoundsChanged?.call(rect);
        break;
      default:
        break;
    }
  }

  /// native 回传的被点字矩形（屏幕逻辑 px）。老 native 不带这几项时返回 null，
  /// 调用方回落到原来的光标定位（Never break）。
  static Rect? _wordRect(Map<Object?, Object?> args) {
    final double? left = (args['wordLeft'] as num?)?.toDouble();
    final double? top = (args['wordTop'] as num?)?.toDouble();
    final double? width = (args['wordWidth'] as num?)?.toDouble();
    final double? height = (args['wordHeight'] as num?)?.toDouble();
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    return Rect.fromLTWH(left, top, width, height);
  }

  static Future<bool> show({
    GalHookTextWindowRect? rect,
    double fontSize = kGalHookTextFontSize,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xE0000000,
    bool following = true,
    bool passThrough = false,
    bool locked = false,
    bool hoverAutoLookup = false,
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
      // 置顶（📌 按钮）按会话复位为「开」，与 locked / passThrough / following 同
      // 规矩：上一局用户关掉置顶，不该让这一局的浮窗藏在全屏游戏后面。
      'topmost': true,
      // 「悬停即查词」：true 时浮窗上纯悬停即查词，false 时必须按住 Shift（Shift-悬停
      // 查词本身始终可用，不受此开关控制）。
      'hoverAutoLookup': hoverAutoLookup,
      'following': following,
      'passThrough': passThrough,
      'locked': locked,
      ...?rect?.toMap(),
    });
  }

  static Future<void> hide() => _instance.hideImpl();

  static Future<bool> isShowing() => _instance.isShowingImpl();

  /// [rubySpans] 是可选的注音区间（`{start, length, ruby}`，start/length 为 [text]
  /// 的 UTF-16 下标，与 native `HitTestPoint` 回传的 index 同坐标系）。不传或传空
  /// 时 native 完全走老渲染路径，逐像素与今天一致（never break userspace）。
  static Future<void> updateText({
    required String lineId,
    required String text,
    List<Map<String, Object?>>? rubySpans,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateText', <String, Object?>{
      'lineId': lineId,
      'text': text,
      if (rubySpans != null && rubySpans.isNotEmpty) 'rubySpans': rubySpans,
    });
  }

  static Future<void> updateStyle({
    required int bgColor,
    int textColor = 0xFFFFFFFF,
    double fontSize = kGalHookTextFontSize,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateStyle', <String, Object?>{
      'fontSize': fontSize,
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

  /// 「悬停即查词」live 下发（设置项 `hover_auto_lookup`）：开着浮窗时改设置立刻生效，
  /// 不必等下一局游戏。关掉时浮窗退回「按住 Shift 悬停才查词」。
  static Future<void> setHoverAutoLookup(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setHoverAutoLookup',
      <String, Object?>{'enabled': enabled},
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
