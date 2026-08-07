import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/platform/floating_overlay_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

typedef ClipboardTextLookupHandler = void Function(String text, int index);
typedef ClipboardTextTransparencyHandler = void Function();

/// 真透明剪切板文字窗的 MethodChannel 绑定（Windows-only）。
///
/// native 后端是 [FloatingLyricWindow] 的第二实例，`SetTextOnly(true)`：逐像素
/// 透明背景（`UpdateLayeredWindow + ULW_ALPHA`）+ 文字实心，无播放/锁/关按钮、无
/// 缩放抓手，只留可拖文字 + 点字。点字经 [setEventHandlers] 的 [onLookupText]
/// 回到 app 内查词覆盖窗（复用 [GlobalLookupController.lookupText]）。
///
/// 契约是 [FloatingLyricChannel] 的精简子集（去掉播放态/歌词行/锁/高亮/标签），
/// 走独立通道 [HibikiChannels.clipboardText] 的独立 native 窗口，二者互不影响。
class ClipboardTextOverlayChannel extends FloatingOverlayChannel {
  ClipboardTextOverlayChannel._() : super(HibikiChannels.clipboardText);

  static final ClipboardTextOverlayChannel _instance =
      ClipboardTextOverlayChannel._();

  /// 测试注入平台判定。
  @visibleForTesting
  static bool? platformOverride;

  @override
  bool get isSupported => platformOverride ?? Platform.isWindows;

  static ClipboardTextLookupHandler? _onLookupText;
  static ClipboardTextTransparencyHandler? _onToggleTransparency;

  static void setEventHandlers({
    ClipboardTextLookupHandler? onLookupText,
    ClipboardTextTransparencyHandler? onToggleTransparency,
  }) {
    _onLookupText = onLookupText;
    _onToggleTransparency = onToggleTransparency;
    _instance.channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onLookupText = null;
    _onToggleTransparency = null;
    _instance.channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'lookupText':
        final Object? args = call.arguments;
        String text = '';
        int index = 0;
        if (args is Map) {
          text = args['text']?.toString() ?? '';
          final Object? indexValue = args['index'];
          if (indexValue is int) {
            index = indexValue;
          } else if (indexValue is num) {
            index = indexValue.toInt();
          }
        }
        if (text.trim().isNotEmpty) {
          _onLookupText?.call(text, index);
        }
        break;
      case 'toggleTransparency':
        _onToggleTransparency?.call();
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Static delegation — 与 FloatingLyricChannel 同款调用面。
  // ---------------------------------------------------------------------------

  static Future<bool> canDrawOverlays() => _instance.canDrawOverlaysImpl();

  /// 显示透明文字窗。[bgColor] = ARGB 背景色，alpha=0（默认）即完全透明背景、
  /// 只露实心文字；用户拉高背景不透明度滑杆时 alpha 上抬垫一层暗底提升可读性。
  static Future<bool> show({
    double fontSize = 20,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0x00000000,
    int windowWidth = 0,
    bool clickLookupEnabled = true,
    String windowTitle = '',
  }) {
    return _instance.showImpl(<String, Object?>{
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'windowWidth': windowWidth,
      'clickLookupEnabled': clickLookupEnabled,
      'windowTitle': windowTitle,
    });
  }

  static Future<void> hide() => _instance.hideImpl();

  static Future<bool> isShowing() => _instance.isShowingImpl();

  /// [rubySpans] 是可选的注音区间（`{start, length, ruby}`，start/length 为 [text]
  /// 的 UTF-16 下标）。不传或传空时 native 走老渲染路径，逐像素与今天一致。
  static Future<void> updateText(
    String text, {
    List<Map<String, Object?>>? rubySpans,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateText', {
      'text': text,
      if (rubySpans != null && rubySpans.isNotEmpty) 'rubySpans': rubySpans,
    });
  }

  static Future<void> updateStyle({
    double fontSize = 20,
    int textColor = 0xFFFFFFFF,
    int bgColor = 0x00000000,
    int windowWidth = 0,
  }) async {
    if (!_instance.isSupported) return;
    await _instance.channel.invokeMethod<void>('updateStyle', {
      'fontSize': fontSize,
      'textColor': textColor,
      'bgColor': bgColor,
      'windowWidth': windowWidth,
    });
  }

  static Future<void> setClickLookupEnabled(bool enabled) async {
    if (!_instance.isSupported) return;
    await _instance.channel
        .invokeMethod<void>('setClickLookupEnabled', {'enabled': enabled});
  }
}
