import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// TODO-057 守卫：视频画面「左半区竖滑调屏幕亮度 / 右半区竖滑调音量 + 指示条」。
///
/// 实现复用 media_kit 移动控制条内建的 volumeGesture/brightnessGesture，但 HUD
/// 由 Hibiki 自己接管：右侧音量、左侧亮度，均显示 0..100%。亮度落设备背光经
/// [ScreenBrightnessController]（移动端真生效、桌面诚实门控）；音量不依赖亮度能力。
/// 没有可在宿主里跑的真手势/真亮度，故走源码扫描守卫；撤掉接线转红。
void main() {
  final String videoPage = readVideoHibikiSource();
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
    test('enables independent volume gesture and brightness-gated drag gesture',
        () {
      // 复用 media_kit 控制条手势而不是自造一套；音量是播放器能力，不应跟随亮度能力门控。
      expect(videoPage.contains('volumeGesture: true'), isTrue);
      expect(
        videoPage.contains('volumeGesture: _brightness.canControl'),
        isFalse,
      );
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

    test('right-side volume drag hides media_kit indicator and uses page HUD',
        () {
      final String body = mobileThemeBody();
      expect(body.contains('volumeIndicatorBuilder:'), isTrue,
          reason:
              'Right-half vertical volume drag should explicitly suppress media_kit HUD.');
      expect(body.contains('const SizedBox.shrink()'), isTrue,
          reason: 'Hibiki page-level HUD owns the visible volume feedback.');
      expect(videoPage.contains('_showVolumeOsd(clamped)'), isTrue,
          reason: 'onVolumeChanged must feed the sustained page HUD.');
    });

    test(
        'left-side brightness drag hides media_kit indicator and uses page HUD',
        () {
      final String body = mobileThemeBody();
      expect(body.contains('brightnessIndicatorBuilder:'), isTrue,
          reason:
              'Left-half vertical brightness drag should explicitly suppress media_kit HUD.');
      expect(
        body.contains('const SizedBox.shrink()'),
        isTrue,
        reason: 'Hibiki page-level HUD owns the visible brightness feedback.',
      );
      expect(videoPage.contains('_showBrightnessOsd(clamped * 100.0)'), isTrue,
          reason: 'onBrightnessChanged must feed the sustained page HUD.');
    });

    test('brightness callback goes through ScreenBrightnessController', () {
      expect(
        videoPage.contains('onBrightnessChanged: _onMediaKitBrightnessChanged'),
        isTrue,
      );
      expect(videoPage.contains('ScreenBrightnessController.instance'), isTrue);
      expect(videoPage.contains('_brightness.setBrightness('), isTrue);
      expect(videoPage.contains('_showBrightnessOsd('), isTrue);
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
