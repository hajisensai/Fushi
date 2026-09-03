import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';

/// TODO-057 守卫：视频画面「左半区竖滑调屏幕亮度 / 右半区竖滑调音量 + 指示条」。
///
/// 实现复用 media_kit 移动控制条内建的 volumeGesture/brightnessGesture，但 HUD
/// 由 Hibiki 自己接管：右侧音量、左侧亮度，均显示 0..100%。亮度落设备背光经
/// [ScreenBrightnessController]（移动端真生效、桌面诚实门控）；音量不依赖亮度能力。
/// 没有可在宿主里跑的真手势/真亮度，故走源码扫描守卫；撤掉接线转红。
void main() {
  final String videoPage = readVideoFushiSource();
  final String brightnessCtrl = File(
    'lib/src/platform/screen_brightness_controller.dart',
  ).readAsStringSync();

  String mobileThemeBody() {
    final int start = videoPage.indexOf(
      'MaterialVideoControlsThemeData _mobileControlsTheme(',
    );
    expect(start, greaterThanOrEqualTo(0),
        reason: 'missing _mobileControlsTheme');
    // TODO-590 batch11：_mobileControlsTheme 已搬到 controls_theme.part.dart，是合并语料
    // 末方法。原下界 _setDelayMs 在主壳、现排到了它之前，故改用 part 顶格 extension 闭合
    // `\n}` 作下界——它紧随末方法 _mobileControlsTheme。
    final int end = videoPage.indexOf('\n}', start);
    expect(end, greaterThan(start),
        reason: 'missing part-extension close after mobile theme');
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

    test(
        'enables horizontal seek-drag gesture with absolute-time HUD (TODO-916)',
        () {
      // TODO-916 症状①：移动控制条启用 fork 内置横滑 seek（之前明确关闭），按时长比例
      // 换算目标 + 居中 HUD 显「目标绝对时间」。与 seek 键 / 双击全屏语义并存（竞技场
      // 先达成者胜）。旧 `seekGesture: false` 守卫随该特性合并作废。
      expect(videoPage.contains('seekGesture: false'), isFalse,
          reason:
              'TODO-916 enabled horizontal seek; stale disable must be gone');
      expect(videoPage.contains('seekGesture: true'), isTrue);
      // BUG-1506：换算入口在 BUG-1485 换掉了，这条锚点没跟上，把 develop 守成恒红。
      // 旧断言钉的是 fork 内建的 `horizontalGestureSensitivity:`（每像素时间与总时长
      // 成正比 = 「一拽就起飞」的根因）；现在换算由 Hibiki 侧注入的
      // [VideoHorizontalSeekGesture.resolveDelta] 接管，fork 的比例制灵敏度在 resolver
      // 在场时根本不被读。三条一起断，才既守住新契约又堵回旧公式：
      // ① resolver 字段在；② 它真接到了那个可单测的纯函数（只有字段名等于没接线）；
      // ③ 带冒号的具名参数形态**不许回来**——不带冒号会被
      //    `video_fushi_page.dart` 里那条解释性注释命中（本文件读的是合并语料）。
      // 三条都走 containsCodeLine 剥注释，注释里的同名字面量一律不算数。
      expect(containsCodeLine(videoPage, 'horizontalSeekResolver:'), isTrue,
          reason: 'BUG-1485/1506：横滑换算必须经 Hibiki 侧 resolver 注入');
      expect(
        containsCodeLine(videoPage, 'VideoHorizontalSeekGesture.resolveDelta('),
        isTrue,
        reason: 'BUG-1506：resolver 必须真接到纯函数，光有字段名不算接线',
      );
      expect(
        containsCodeLine(videoPage, 'horizontalGestureSensitivity:'),
        isFalse,
        reason: 'BUG-1485：改回按视频总时长比例换算的 fork 灵敏度即回归',
      );
      // 居中 HUD 替换 fork 默认增量条，显目标绝对时间 + 增量两行。
      expect(
        videoPage.contains(
            'seekIndicatorBuilder: (BuildContext context, Duration delta) =>'),
        isTrue,
      );
      expect(
          videoPage.contains('_buildSeekIndicator(controller, delta)'), isTrue);
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

    test('does NOT break tap-to-pause: playAndPauseOnTap stays wired', () {
      // media_kit 的竖直 drag 与 tap 同一 arena，纯点击 drag 不启动 → 单击暂停照常。
      // 开/关现在是用户设置（默认 true，见 video_asbplayer_config_test 的 defaults
      // 用例）；这里锁的是「竖滑手势没有把这条接线摘掉」。
      expect(
        videoPage.contains('playAndPauseOnTap: _asbConfig.tapTogglesPlayback'),
        isTrue,
      );
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
