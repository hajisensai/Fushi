import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 「Ctrl / ⌘ 此刻是否按着」——给 Ctrl + 滚轮这类**非按键事件**里读修饰键的地方用。
///
/// [HardwareKeyboard] 的按键状态只由 Flutter 收到的 KeyEvent 维护。Windows 上 Ctrl
/// 抬起那一下若落在 WebView2（查词弹窗、阅读器）或别的窗口里，Flutter 收不到 key up，
/// 缓存会一直停在「按下」，直到下一次 Flutter 自己收到按键：期间每一格滚轮都被当成
/// Ctrl + 滚轮（反馈 TpKspDUst7：视频字幕列表不滚、改成缩放字号，字号还被持久化）。
///
/// 所以缓存说「按着」时，在 Windows 上再向系统要一次真实状态
/// （`GetAsyncKeyState`）为准；缓存说「没按」就直接信缓存（失效方向只有卡在按下）。
/// 其它平台的嵌入层会在焦点回来时同步修饰键，沿用缓存。
bool isZoomModifierPressed() {
  final HardwareKeyboard keyboard = HardwareKeyboard.instance;
  final bool cached = keyboard.isControlPressed || keyboard.isMetaPressed;
  if (!cached) return false;
  final bool? Function()? query =
      debugPlatformZoomModifierQuery ??
      (Platform.isWindows ? _windowsZoomModifierDown : null);
  return query?.call() ?? cached;
}

/// 测试替身：非 null 时代替平台查询（返回 null = 平台给不出答案，沿用缓存）。
@visibleForTesting
bool? Function()? debugPlatformZoomModifierQuery;

const int _vkControl = 0x11;
const int _vkLeftWin = 0x5B;
const int _vkRightWin = 0x5C;

typedef _GetAsyncKeyStateNative = Int16 Function(Int32 vKey);
typedef _GetAsyncKeyStateDart = int Function(int vKey);

_GetAsyncKeyStateDart? _getAsyncKeyState;

bool? _windowsZoomModifierDown() {
  try {
    final _GetAsyncKeyStateDart fn = _getAsyncKeyState ??=
        DynamicLibrary.open(
          'user32.dll',
        ).lookupFunction<_GetAsyncKeyStateNative, _GetAsyncKeyStateDart>(
          'GetAsyncKeyState',
        );
    // 最高位 = 此刻按着。
    bool down(int vk) => (fn(vk) & 0x8000) != 0;
    return down(_vkControl) || down(_vkLeftWin) || down(_vkRightWin);
  } on ArgumentError {
    return null;
  }
}
