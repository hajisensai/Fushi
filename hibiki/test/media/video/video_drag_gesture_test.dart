import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-057 守卫：视频画面「左半区竖滑调屏幕亮度 / 右半区竖滑调音量 + 指示条」。
///
/// 实现复用 media_kit 移动控制条内建的 volumeGesture/brightnessGesture（含内建
/// 音量/亮度指示器），亮度落设备背光经 [ScreenBrightnessController]（移动端真生效、
/// 桌面诚实门控）。没有可在宿主里跑的真手势/真亮度，故走源码扫描守卫；撤掉接线转红。
void main() {
  final String videoPage = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();
  final String brightnessCtrl = File(
    'lib/src/platform/screen_brightness_controller.dart',
  ).readAsStringSync();

  String mobileThemeBody() {
    final int start = videoPage.indexOf(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    expect(start, greaterThanOrEqualTo(0),
        reason: 'missing _mobileControlsTheme');
    final int end = videoPage.indexOf('Future<void> _setDelayMs', start);
    expect(end, greaterThan(start),
        reason: 'missing _setDelayMs after mobile theme');
    return videoPage.substring(start, end);
  }

  group('TODO-057 video drag brightness/volume guards', () {
    test('enables media_kit built-in volume + brightness drag gestures', () {
      // 复用 media_kit 控制条手势而不是自造一套（避免与其内建手势冲突、白拿指示器）。
      expect(
          videoPage.contains('volumeGesture: _brightness.canControl'), isTrue);
      expect(
        videoPage.contains('brightnessGesture: _brightness.canControl'),
        isTrue,
      );
    });

    test('does NOT enable horizontal seek-drag gesture', () {
      // 横滑 seek 超出本任务范围，且与既有 seek 键 / 双击全屏语义重叠 → 明确关闭。
      expect(videoPage.contains('seekGesture: false'), isTrue);
    });

    test('volume callback reuses the existing 0..100 volume channel', () {
      // 不另开第二套音量状态：经 _onMediaKitVolumeChanged → _applyUserVideoVolume，
      // 与 TODO-044 方向键音量同一 setter / 持久化 helper。
      expect(videoPage.contains('onVolumeChanged: _onMediaKitVolumeChanged'),
          isTrue);
      expect(videoPage.contains('_applyUserVideoVolume(pct)'), isTrue);
      expect(videoPage.contains('controller.setVolume(clamped)'), isTrue);
    });

    test('right-side volume drag uses the shared Hibiki indicator builder', () {
      final String body = mobileThemeBody();
      expect(body.contains('volumeIndicatorBuilder:'), isTrue,
          reason:
              'Right-half vertical volume drag should render the same right-side HUD.');
      expect(body.contains('_buildRightVolumeIndicator(value * 100.0)'), isTrue,
          reason:
              'media_kit passes 0..1; Hibiki HUD uses the same 0..100 volume scale.');
    });

    test('brightness callback goes through ScreenBrightnessController', () {
      expect(
        videoPage.contains('onBrightnessChanged: _onMediaKitBrightnessChanged'),
        isTrue,
      );
      expect(videoPage.contains('ScreenBrightnessController.instance'), isTrue);
      expect(videoPage.contains('_brightness.setBrightness('), isTrue);
    });

    test('brightness is restored on exit (no permanent system change)', () {
      // 退出播放器把进页快照写回；media_kit 手势复位也回调 restore。
      expect(videoPage.contains('_brightness.restore('), isTrue);
      expect(videoPage.contains('onBrightnessReset:'), isTrue);
      expect(videoPage.contains('_ensureEnterBrightness()'), isTrue);
    });

    test('does NOT break tap-to-pause: playAndPauseOnTap stays enabled', () {
      // media_kit 的竖直 drag 与 tap 同一 arena，纯点击 drag 不启动 → 单击暂停照常。
      expect(videoPage.contains('playAndPauseOnTap: true'), isTrue);
    });
  });

  group('TODO-057 ScreenBrightnessController guards', () {
    test('control is gated to mobile only (desktop honestly cannot)', () {
      expect(
        brightnessCtrl.contains('bool get canControl => isMobilePlatform'),
        isTrue,
      );
    });

    test('exposes setBrightness / restoreBrightness over the channel', () {
      expect(
        brightnessCtrl.contains("invokeMethod<void>('setBrightness'"),
        isTrue,
      );
      expect(
        brightnessCtrl.contains("invokeMethod<void>('restoreBrightness'"),
        isTrue,
      );
      expect(
        brightnessCtrl.contains("invokeMethod<double>('getBrightness'"),
        isTrue,
      );
    });
  });
}
