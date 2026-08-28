import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/platform/floating_overlay_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 悬浮字幕点词。[wordRect] 是被点那个字的**屏幕逻辑 px** 矩形，查词卡据此锚定到
/// 词而不是鼠标位置；native 没回传（Android 系统 overlay 走自己的 PopupDictActivity，
/// 老 payload 也没有这些字段）时为 null，调用方回落光标锚定。
typedef FloatingLyricLookupHandler =
    void Function(String text, int index, Rect? wordRect);
typedef FloatingLyricControlHandler = void Function();
typedef FloatingLyricLockHandler = void Function(bool locked);

/// native 侧穿透状态变化（用户按了穿透键，或 native 否决了穿透请求）。
typedef FloatingLyricPassThroughHandler = void Function(bool passThrough);

/// 浮窗被拖动 / 改尺寸后的新窗口矩形（屏幕物理 px），用于持久化。
typedef FloatingLyricBoundsHandler =
    void Function(int left, int top, int width, int height);

/// 悬浮字幕窗口矩形（屏幕**物理** px，与 native SetInitialBounds / 回传的
/// windowRectChanged 同坐标系）。用于跨会话记住用户把浮窗拖到了哪、拉成多大。
class FloatingLyricWindowRect {
  const FloatingLyricWindowRect({
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

  static FloatingLyricWindowRect? fromMap(Map<Object?, Object?> map) {
    int? value(String key) => (map[key] as num?)?.toInt();
    final FloatingLyricWindowRect rect = FloatingLyricWindowRect(
      left: value('left') ?? 0,
      top: value('top') ?? 0,
      width: value('width') ?? 0,
      height: value('height') ?? 0,
    );
    return rect.isValid ? rect : null;
  }
}

/// Floating subtitle overlay channel.
///
/// Two native back-ends share the same MethodChannel contract:
/// - Android: a system overlay window ([FloatingLyricService]) drawn over
///   other apps, with its own [PopupDictActivity] for tap lookup.
/// - Windows: a standalone always-on-top layered window in the runner
///   (`windows/runner/floating_lyric_window.cpp`)，跑与 galgame hook 台词浮窗
///   **同一套富文本形态**：换行、滚动条、拖角改尺寸、鼠标穿透、一键透明、
///   Shift-悬停查词。点词经 [setEventHandlers] 的 `onLookupText` 带出被点字的屏幕
///   矩形，查词卡锚定到那个词并弹在 app 外（不起第二个 Flutter engine）。
///
/// macOS / Linux have no native back-end yet, so [isSupported] excludes them
/// and every outgoing call is short-circuited by [FloatingOverlayChannel].
class FloatingLyricChannel extends FloatingOverlayChannel {
  FloatingLyricChannel._() : super(FushiChannels.floatingLyric);

  static final FloatingLyricChannel _instance = FloatingLyricChannel._();

  @visibleForTesting
  static bool? platformOverride;

  @override
  bool get isSupported =>
      platformOverride ?? (Platform.isAndroid || Platform.isWindows);

  static FloatingLyricLookupHandler? _onLookupText;
  static FloatingLyricControlHandler? _onPreviousCue;
  static FloatingLyricControlHandler? _onPlayPause;
  static FloatingLyricControlHandler? _onNextCue;
  static FloatingLyricControlHandler? _onClose;
  static FloatingLyricControlHandler? _onTogglePassThrough;
  static FloatingLyricControlHandler? _onToggleTransparency;
  static FloatingLyricLockHandler? _onLockChanged;
  static FloatingLyricPassThroughHandler? _onPassThroughChanged;
  static FloatingLyricBoundsHandler? _onBoundsChanged;

  static void setEventHandlers({
    FloatingLyricLookupHandler? onLookupText,
    FloatingLyricControlHandler? onPreviousCue,
    FloatingLyricControlHandler? onPlayPause,
    FloatingLyricControlHandler? onNextCue,
    FloatingLyricControlHandler? onClose,
    FloatingLyricControlHandler? onTogglePassThrough,
    FloatingLyricControlHandler? onToggleTransparency,
    FloatingLyricLockHandler? onLockChanged,
    FloatingLyricPassThroughHandler? onPassThroughChanged,
    FloatingLyricBoundsHandler? onBoundsChanged,
  }) {
    _onLookupText = onLookupText;
    _onPreviousCue = onPreviousCue;
    _onPlayPause = onPlayPause;
    _onNextCue = onNextCue;
    _onClose = onClose;
    _onTogglePassThrough = onTogglePassThrough;
    _onToggleTransparency = onToggleTransparency;
    _onLockChanged = onLockChanged;
    _onPassThroughChanged = onPassThroughChanged;
    _onBoundsChanged = onBoundsChanged;
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onPreviousCue = null;
    _onPlayPause = null;
    _onNextCue = null;
    _onClose = null;
    _onTogglePassThrough = null;
    _onToggleTransparency = null;
    _onLockChanged = null;
    _onPassThroughChanged = null;
    _onBoundsChanged = null;
    _instance.channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'lookupText':
        final Object? args = call.arguments;
        String text = '';
        int index = 0;
        Rect? wordRect;
        if (args is Map) {
          text = args['text']?.toString() ?? '';
          final Object? indexValue = args['index'];
          if (indexValue is int) {
            index = indexValue;
          } else if (indexValue is num) {
            index = indexValue.toInt();
          }
          wordRect = _wordRect(args);
        }
        if (text.trim().isNotEmpty) {
          _onLookupText?.call(text, index, wordRect);
        }
        break;
      case 'togglePassThrough':
        _onTogglePassThrough?.call();
        break;
      case 'toggleTransparency':
        _onToggleTransparency?.call();
        break;
      case 'passThroughChanged':
        final Object? args = call.arguments;
        if (args is Map) {
          _onPassThroughChanged?.call(args['passThrough'] == true);
        }
        break;
      case 'windowRectChanged':
        final Object? args = call.arguments;
        if (args is Map) {
          final int? left = _asInt(args['left']);
          final int? top = _asInt(args['top']);
          final int? width = _asInt(args['width']);
          final int? height = _asInt(args['height']);
          if (left != null && top != null && width != null && height != null) {
            _onBoundsChanged?.call(left, top, width, height);
          }
        }
        break;
      case 'previousCue':
        _onPreviousCue?.call();
        break;
      case 'playPause':
        _onPlayPause?.call();
        break;
      case 'nextCue':
        _onNextCue?.call();
        break;
      case 'close':
        _onClose?.call();
        break;
      case 'lockChanged':
        final Object? args = call.arguments;
        if (args is Map) {
          final bool locked = args['locked'] == true;
          _onLockChanged?.call(locked);
        }
        break;
      default:
        break;
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  /// 被点字的屏幕逻辑 px 矩形。四个字段缺任何一个 = 没有词矩形（Android 系统
  /// overlay 与改造前的 payload 都不带），返回 null 让调用方回落光标锚定 —— 半个
  /// 矩形比没有矩形更糟，所以这里要么四个都有要么不给。
  static Rect? _wordRect(Map<Object?, Object?> args) {
    final Object? left = args['wordLeft'];
    final Object? top = args['wordTop'];
    final Object? width = args['wordWidth'];
    final Object? height = args['wordHeight'];
    if (left is! num || top is! num || width is! num || height is! num) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    return Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
  }

  // ---------------------------------------------------------------------------
  // Static delegation — call sites like FloatingLyricChannel.show() keep working
  // ---------------------------------------------------------------------------

  static Future<bool> canDrawOverlays() => _instance.canDrawOverlaysImpl();

  static Future<bool> show({
    double fontSize = 16,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xCC000000,
    int buttonTextColor = 0xFFFFFFFF,
    int buttonBgColor = 0x33000000,
    int highlightColor = 0x80FFD54F,
    int activeColor = 0xFFFFD54F,
    // TODO-708 P2: 圆角半径 / 窗宽（逻辑 dp）。0 = 平台原生默认（旧 payload 缺字段回退
    // 到此默认，保证向后兼容与零观感变化）。
    int cornerRadius = 0,
    int windowWidth = 0,
    bool? locked,
    bool clickLookupEnabled = true,
    // ── 以下为桌面富文本浮窗（Windows）参数。Android 系统 overlay 读不到这些 key，
    // 多传对它是无害的 no-op，所以两端仍共用一条 channel 契约。
    bool passThrough = false,
    bool topmost = true,
    bool hoverAutoLookup = false,
    List<String>? slotTooltips,
    FloatingLyricWindowRect? rect,
  }) {
    final Map<String, Object?> arguments = <String, Object?>{
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'buttonTextColor': buttonTextColor,
      'buttonBgColor': buttonBgColor,
      'highlightColor': highlightColor,
      'activeColor': activeColor,
      'cornerRadius': cornerRadius,
      'windowWidth': windowWidth,
      'clickLookupEnabled': clickLookupEnabled,
      // 穿透 / 置顶按会话复位（与 locked 同规矩）：上一次留下的穿透态若跟着复原，
      // 用户这一次会发现浮窗完全点不动，而且看不出为什么。
      'passThrough': passThrough,
      'topmost': topmost,
      'hoverAutoLookup': hoverAutoLookup,
    };
    // 工具条槽位悬停提示，下标与 native hook_toolbar::kAudiobookSlotActions 严格
    // 对齐。不传 = native 侧无提示，按钮照常可点。
    if (slotTooltips != null && slotTooltips.isNotEmpty) {
      arguments['slotTooltips'] = slotTooltips;
    }
    if (locked != null) {
      arguments['locked'] = locked;
    }
    if (rect != null) {
      arguments.addAll(rect.toMap());
    }
    return _instance.showImpl(arguments);
  }

  static Future<void> hide() => _instance.hideImpl();

  static Future<bool> isShowing() => _instance.isShowingImpl();

  /// 推送当前悬浮字幕文本。
  ///
  /// TODO-708 P4：可携带块内「当前行区间」——[currentLineStart] = 当前行在 [text]
  /// 中的 UTF-16 offset（-1 = 无当前行标记，退化为无行明暗区分），[currentLineLength]
  /// = 当前行 UTF-16 长度。默认 (-1, 0) = 无行标记：与今天（N=0 只推单行）payload
  /// 语义一致，且原生缺字段读默认也退化 0 上下文（向后兼容）。
  /// [rubySpans] 是可选注音区间（`{start, length, ruby}`，start/length 为 [text]
  /// 的 UTF-16 下标，与 native 回传的 index 同坐标系）。不传 / 空 = native 走老
  /// 渲染路径，逐像素与引入注音前一致。
  static Future<void> updateText(
    String text, {
    int currentLineStart = -1,
    int currentLineLength = 0,
    String lineId = '',
    List<Map<String, Object?>>? rubySpans,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateText', {
      'text': text,
      'currentLineStart': currentLineStart,
      'currentLineLength': currentLineLength,
      if (lineId.isNotEmpty) 'lineId': lineId,
      if (rubySpans != null && rubySpans.isNotEmpty) 'rubySpans': rubySpans,
    });
  }

  /// 鼠标穿透（正文点穿到下面的窗口，工具条移到独立的永不透明小窗）。native 可能
  /// 否决（工具条窗建不出来时），真值以 `passThroughChanged` 事件为准。
  static Future<void> setPassThrough(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setPassThrough', {
      'enabled': enabled,
    });
  }

  /// 「悬停即查词」live 下发：设置一改，正开着的浮窗立刻跟上。
  static Future<void> setHoverAutoLookup(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setHoverAutoLookup', {
      'enabled': enabled,
    });
  }

  static Future<void> highlight({
    required int start,
    required int length,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('highlight', {
      'start': start,
      'length': length,
    });
  }

  static Future<void> updateLabels({
    required String previous,
    required String playPause,
    required String next,
    required String lock,
    required String unlock,
    required String close,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateLabels', {
      'previous': previous,
      'playPause': playPause,
      'next': next,
      'lock': lock,
      'unlock': unlock,
      'close': close,
    });
  }

  static Future<void> setPlaybackState({required bool playing}) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setPlaybackState', {
      'playing': playing,
    });
  }

  static Future<void> updateStyle({
    double fontSize = 16,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0xCC000000,
    int buttonTextColor = 0xFFFFFFFF,
    int buttonBgColor = 0x33000000,
    int highlightColor = 0x80FFD54F,
    int activeColor = 0xFFFFD54F,
    // TODO-708 P2: 圆角半径 / 窗宽（逻辑 dp）。0 = 平台原生默认。
    int cornerRadius = 0,
    int windowWidth = 0,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateStyle', {
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'buttonTextColor': buttonTextColor,
      'buttonBgColor': buttonBgColor,
      'highlightColor': highlightColor,
      'activeColor': activeColor,
      'cornerRadius': cornerRadius,
      'windowWidth': windowWidth,
    });
  }

  static Future<void> setLocked(bool locked) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('setLocked', {'locked': locked});
  }

  static Future<void> setClickLookupEnabled(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>(
      'setClickLookupEnabled',
      {'enabled': enabled},
    );
  }
}
