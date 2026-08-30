import 'dart:io';

import 'package:flutter/services.dart';

/// 把标题栏配色推给 Windows 原生 runner（DWM caption / text color）。
///
/// 仅 Windows 生效，其它平台直接 no-op。显式设置 caption color 后，
/// Windows 在窗口失焦时也不会再把标题栏灰化，所以失焦态同样跟随主题色。
class WindowCaptionChannel {
  WindowCaptionChannel._();

  static const MethodChannel _channel = MethodChannel('app.fushi/window');

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

  /// BUG-1933：Windows 全屏切换（runner 自有实现，替代 window_manager /
  /// media_kit 的去边框实现）。
  ///
  /// window_manager 的 `setFullScreen` 和 media_kit 的 `EnterNativeFullscreen`
  /// 都靠剥掉 `WS_CAPTION|WS_THICKFRAME` 实现全屏——风格变更让 DWM 重建窗口
  /// visual，至少一帧合成里 Flutter 子窗图层缺席，露出主窗重定向表面
  /// （主题 surface 色；浅色主题下就是用户看到的「全屏/取消全屏闪一帧白色」）。
  /// runner 侧改为保留边框、把窗口放大到客户区恰好盖满显示器（边框悬屏外）+
  /// TOPMOST 盖任务栏，与最大化同路径，实测不露表面；过渡瞬间还会把当前画面
  /// 快照垫进表面兜底。仅 Windows 生效，其它平台 no-op（macOS 走
  /// WindowManipulator、Linux 仍走 window_manager）。
  static Future<void> setFullscreen(bool fullscreen) async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setFullscreen', <String, bool>{
        'fullscreen': fullscreen,
      });
    } on PlatformException {
      // 旧 runner 不实现该方法时静默忽略（调用方各有回退语义）。
    } on MissingPluginException {
      // 通道未注册（widget 测试 / 非 window runner 宿主）时静默忽略。
    }
  }

  /// BUG-1933：当前是否处于 runner 自有实现的全屏态。非 Windows / 通道不可用
  /// 恒 false（window_manager 在 Windows 上不再进入全屏，其 isFullScreen 也
  /// 恒 false，两边不会都为 true）。
  static Future<bool> isFullscreen() async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isFullscreen') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
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
