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

  /// TODO-615：主动熄灭 Windows 任务栏的「请求注意」高亮（FlashWindowEx +
  /// FLASHW_STOP）。
  ///
  /// `SetForegroundWindow`（`window_manager` 的 `show()`/`focus()`/
  /// `setAlwaysOnTop()` 在前台锁定下会退化触发）会把 Hibiki 的任务栏按钮设为闪烁
  /// 请求注意态，用户得点一下才能消掉（TODO-341 / TODO-615）。判前台守卫在前台
  /// 判据抖动时仍可能漏判而留下残留高亮，所以唤前台路径无论如何在尾部主动 clear
  /// 一次：FLASHW_STOP 对一个本就没有 flash 的窗口是 no-op，纯幂等清除。
  ///
  /// 仅 Windows 生效，其它平台直接 no-op。原生侧失败（旧主机/缺通道）静默吞掉，
  /// 不让一次窗口装饰调用拖垮查词生命周期。
  static Future<void> clearTaskbarFlash() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('clearTaskbarFlash');
    } on PlatformException {
      // 主机不实现该方法（旧 runner / 测试桩）时静默忽略。
    } on MissingPluginException {
      // 通道未注册（widget 测试 / 非 window runner 宿主）时静默忽略。
    }
  }

  /// 把窗口/任务栏图标设为 [path] 指向的本地图片（仅 Windows）。
  ///
  /// 原生侧用 WIC 解码图片成 big/small HICON 后 WM_SETICON。运行时只改当前
  /// 窗口图标，改不了 exe 文件本身（文件图标是嵌入资源）。其它平台直接返回
  /// false 不触达 channel。成功返回 true。
  static Future<bool> setWindowIcon(String path) async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'setWindowIcon',
        <String, String>{'path': path},
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
