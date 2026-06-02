import 'dart:io';

import 'package:flutter/services.dart';

/// 把标题栏配色推给 Windows 原生 runner（DWM caption / text color）。
///
/// 仅 Windows 生效，其它平台直接 no-op。显式设置 caption color 后，
/// Windows 在窗口失焦时也不会再把标题栏灰化，所以失焦态同样跟随主题色。
class WindowCaptionChannel {
  WindowCaptionChannel._();

  static const MethodChannel _channel = MethodChannel('app.hibiki/window');

  static int? _lastCaption;
  static int? _lastText;

  /// 设置标题栏背景色与文字色。同值不重复下发，避免每次 rebuild 都刷 channel。
  static Future<void> setCaptionColors({
    required Color caption,
    required Color text,
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    final int captionArgb = caption.toARGB32();
    final int textArgb = text.toARGB32();
    if (captionArgb == _lastCaption && textArgb == _lastText) {
      return;
    }
    _lastCaption = captionArgb;
    _lastText = textArgb;
    try {
      await _channel.invokeMethod<void>('setCaptionColors', <String, int>{
        'caption': captionArgb,
        'text': textArgb,
      });
    } on PlatformException {
      // 旧 Windows（< Win11 build 22000）不支持 DWMWA_CAPTION_COLOR，
      // 原生侧静默失败即可，标题栏维持系统默认绘制。
    }
  }
}
