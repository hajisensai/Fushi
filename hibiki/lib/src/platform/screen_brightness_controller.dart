import 'package:flutter/services.dart';

import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

/// 屏幕（背光）亮度控制器 —— 视频播放器左半区竖滑调亮度（TODO-057）用。
///
/// 与 mpv 的画面亮度滤镜（`video_setting_mpv_brightness`，对解码后画面做后处理）
/// **不同**：这里调的是设备**系统屏幕背光**，所以走原生平台通道而非 media_kit。
///
/// 平台诚实门控（[canControl]）：
/// - **Android**：写当前窗口的 `WindowManager.LayoutParams.screenBrightness`，
///   只影响本 App 窗口、不改系统设置；退出（[restore]）设回 -1 即跟随系统。无需权限。
/// - **iOS**：`UIScreen.main.brightness` 是系统级，进入时由调用方先 [currentBrightness]
///   存基线、退出时 [restore] 写回，避免把用户系统亮度永久改掉。
/// - **桌面（Win/macOS/Linux）**：无统一的窗口级背光 API → [canControl] 为 false，
///   左半拖动不调亮度（调用方据此诚实降级，不假装能调）。
///
/// 单例：原生通道进程级，全 App 一个实例够用。
class ScreenBrightnessController {
  ScreenBrightnessController._();

  static final ScreenBrightnessController instance =
      ScreenBrightnessController._();

  static const MethodChannel _channel = HibikiChannels.screenBrightness;

  /// 是否真能调节屏幕亮度。桌面恒 false（诚实门控），移动端 true。
  bool get canControl => isMobilePlatform;

  /// 读当前窗口/系统屏幕亮度（0..1）。不支持平台或失败返 null（调用方据此降级）。
  Future<double?> currentBrightness() async {
    if (!canControl) return null;
    try {
      final double? value =
          await _channel.invokeMethod<double>('getBrightness');
      if (value == null) return null;
      return value.clamp(0.0, 1.0);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 设置屏幕亮度（0..1，自动 clamp）。不支持平台静默 no-op。
  Future<void> setBrightness(double value) async {
    if (!canControl) return;
    final double clamped = value.clamp(0.0, 1.0).toDouble();
    try {
      await _channel.invokeMethod<void>('setBrightness', clamped);
    } on PlatformException {
      // 原生侧失败（如窗口已销毁）——亮度是非关键反馈，吞掉不打断播放。
    } on MissingPluginException {
      // 通道未接（非移动端）——门控理应拦在前，这里兜底。
    }
  }

  /// 还原为「跟随系统」。Android 设窗口亮度 -1（BRIGHTNESS_OVERRIDE_NONE）；
  /// iOS 把进入前存的 [previous] 写回（传 null 时不动，避免误改）。退出播放器必调，
  /// 防止把用户系统亮度永久留在拖动后的值。
  Future<void> restore({double? previous}) async {
    if (!canControl) return;
    try {
      await _channel.invokeMethod<void>('restoreBrightness', previous);
    } on PlatformException {
      // ignore: 还原失败不致命。
    } on MissingPluginException {
      // ignore.
    }
  }
}
