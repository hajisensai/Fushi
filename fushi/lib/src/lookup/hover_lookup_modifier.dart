import 'package:flutter/services.dart';

/// 悬停查词按住的那个键（设置「悬停查词按键」，偏好 [kHoverLookupModifierPrefKey]）。
/// 阅读器 / 歌词 / 漫画 / 视频字幕 / 字幕列表 / 网页档站点页面共用；「不按键直接悬停」是
/// 另一个开关 `hover_auto_lookup`（两者并存：开了它，按不按键都查）。
///
/// 同一个键在两侧的样子：Flutter 侧 [isPressed]（[HardwareKeyboard]），WebView 页面里是
/// `MouseEvent` 上的 [jsEventFlag]（`e[window.__fushiHoverKey]`）。
enum HoverLookupModifier {
  shift('shift', 'shiftKey', 'Shift', 'Shift'),
  ctrl('ctrl', 'ctrlKey', 'Control', 'Ctrl'),
  alt('alt', 'altKey', 'Alt', 'Alt');

  const HoverLookupModifier(
    this.storageKey,
    this.jsEventFlag,
    this.jsKeyName,
    this.label,
  );

  /// 偏好里存的值。
  final String storageKey;

  /// `MouseEvent` / `KeyboardEvent` 上对应的布尔字段名。
  final String jsEventFlag;

  /// `KeyboardEvent.key`（光标不动、按下这个键的那一刻也查）。
  final String jsKeyName;

  /// 设置里显示的键名（键帽字样，不翻译）。
  final String label;

  bool isPressed([HardwareKeyboard? keyboard]) {
    final HardwareKeyboard kb = keyboard ?? HardwareKeyboard.instance;
    return switch (this) {
      HoverLookupModifier.shift => kb.isShiftPressed,
      HoverLookupModifier.ctrl => kb.isControlPressed,
      HoverLookupModifier.alt => kb.isAltPressed,
    };
  }

  static HoverLookupModifier fromStorage(Object? raw) {
    for (final HoverLookupModifier m in values) {
      if (m.storageKey == raw) return m;
    }
    return HoverLookupModifier.shift;
  }
}

const String kHoverLookupModifierPrefKey = 'hover_lookup_modifier';

/// 下发给 WebView 页面的一行 JS：设好 `window.__fushiHoverKey`（页面脚本按它门控）。
String hoverLookupModifierJs(HoverLookupModifier modifier) =>
    "window.__fushiHoverKey='${modifier.jsEventFlag}';"
    "window.__fushiHoverKeyName='${modifier.jsKeyName}';";
