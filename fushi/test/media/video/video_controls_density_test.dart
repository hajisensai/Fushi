import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_controls_density.dart';

/// 「小窗模式 / 按窗口大小缩控件」的判据真相源。页面只读本文件的结论，
/// 所以阈值与取舍在这里钉死一次即可，不必去 widget 树里翻。
void main() {
  VideoControlsDensitySpec resolve(
    double width, {
    VideoMiniSurface surface = VideoMiniSurface.none,
    double height = 720,
  }) => resolveVideoControlsDensity(
    playerSize: Size(width, height),
    surface: surface,
  );

  group('resolveVideoControlsDensity', () {
    test('宽敞窗口用 full 档且完全不缩放（零回归基线）', () {
      final VideoControlsDensitySpec spec = resolve(1280);
      expect(spec.density, VideoControlsDensity.full);
      expect(spec.scale, 1.0);
      expect(spec.showSeekBar, isTrue);
      expect(spec.showTopBar, isTrue);
      expect(spec.showBottomButtonBar, isTrue);
      expect(spec.showCenterTransport, isFalse);
    });

    test('阈值边界：800 仍是 full，799 进 compact', () {
      expect(
        resolve(kVideoControlsCompactWidth).density,
        VideoControlsDensity.full,
      );
      expect(
        resolve(kVideoControlsCompactWidth - 1).density,
        VideoControlsDensity.compact,
      );
    });

    test('阈值边界：480 仍是 compact，479 进 mini', () {
      expect(
        resolve(kVideoControlsMiniWidth).density,
        VideoControlsDensity.compact,
      );
      expect(
        resolve(kVideoControlsMiniWidth - 1).density,
        VideoControlsDensity.mini,
      );
    });

    test('compact 只缩尺寸，chrome 一件不少', () {
      final VideoControlsDensitySpec spec = resolve(600);
      expect(spec.density, VideoControlsDensity.compact);
      expect(spec.scale, lessThan(1.0));
      expect(spec.showSeekBar, isTrue);
      expect(spec.showTopBar, isTrue);
      expect(spec.showBottomButtonBar, isTrue);
    });

    test('mini 收掉进度条/顶栏/底栏，改出居中三键', () {
      final VideoControlsDensitySpec spec = resolve(360);
      expect(spec.isMini, isTrue);
      expect(spec.showSeekBar, isFalse);
      expect(spec.showTopBar, isFalse);
      expect(spec.showBottomButtonBar, isFalse);
      expect(spec.showCenterTransport, isTrue);
      expect(spec.showSeekLabels, isFalse);
    });

    test('手机横屏不因为「矮」被误判成小窗（宽度判据的存在理由）', () {
      // 844x390 典型横屏手机、568x320 最窄的 iPhone SE 横屏：都不许进 mini，
      // 否则正常手机播放的控件会凭空缩一圈 —— 纯回归。
      expect(resolve(844, height: 390).density, VideoControlsDensity.full);
      expect(resolve(568, height: 320).density, VideoControlsDensity.compact);
      expect(resolve(568, height: 320).isMini, isFalse);
    });

    test('桌面小窗表面直接进 mini，与尺寸无关', () {
      final VideoControlsDensitySpec spec = resolve(
        1920,
        surface: VideoMiniSurface.desktopMiniWindow,
      );
      expect(spec.isMini, isTrue);
      expect(spec.showCenterTransport, isTrue);
    });

    test('系统画中画进 mini 但一个 chrome 都不画（系统自己画）', () {
      final VideoControlsDensitySpec spec = resolve(
        320,
        surface: VideoMiniSurface.pictureInPicture,
      );
      expect(spec.isMini, isTrue);
      expect(
        spec.showCenterTransport,
        isFalse,
        reason: 'PiP 里系统自带播放控件，app 再画一套就是两层按钮重影',
      );
      expect(spec.showTopBar, isFalse);
      expect(spec.showBottomButtonBar, isFalse);
      expect(VideoMiniSurface.pictureInPicture.systemOwnsChrome, isTrue);
      expect(VideoMiniSurface.desktopMiniWindow.systemOwnsChrome, isFalse);
      expect(VideoMiniSurface.none.systemOwnsChrome, isFalse);
    });

    test('尺寸未就绪（0 / 非有限）退回 full，不许首帧闪一下小窗形态', () {
      expect(resolve(0).density, VideoControlsDensity.full);
      expect(resolve(-1).density, VideoControlsDensity.full);
      expect(resolve(double.infinity).density, VideoControlsDensity.full);
      expect(resolve(double.nan).density, VideoControlsDensity.full);
    });
  });

  group('videoSlimProgressBarVisible', () {
    const VideoControlsDensitySpec full = VideoControlsDensitySpec(
      density: VideoControlsDensity.full,
      scale: 1,
      showSeekBar: true,
      showSeekLabels: true,
      showTopBar: true,
      showBottomButtonBar: true,
      showCenterTransport: false,
    );
    const VideoControlsDensitySpec mini = VideoControlsDensitySpec(
      density: VideoControlsDensity.mini,
      scale: 0.72,
      showSeekBar: false,
      showSeekLabels: false,
      showTopBar: false,
      showBottomButtonBar: false,
      showCenterTransport: true,
    );

    bool visible({
      VideoControlsDensitySpec spec = full,
      VideoMiniSurface surface = VideoMiniSurface.none,
      bool preferenceEnabled = true,
      bool controlsVisible = false,
    }) => videoSlimProgressBarVisible(
      spec: spec,
      surface: surface,
      preferenceEnabled: preferenceEnabled,
      controlsVisible: controlsVisible,
    );

    test('常规档：开关开 + 控制条已淡出才显', () {
      expect(visible(), isTrue);
      expect(
        visible(controlsVisible: true),
        isFalse,
        reason: '控制条在场时它自带完整进度条，两条并存是重影',
      );
      expect(visible(preferenceEnabled: false), isFalse);
    });

    test('mini 档恒显，不受开关管（它是唯一的进度指示）', () {
      expect(visible(spec: mini, preferenceEnabled: false), isTrue);
      expect(
        visible(spec: mini, preferenceEnabled: false, controlsVisible: true),
        isTrue,
      );
    });

    test('系统画中画恒不显，优先级最高', () {
      expect(
        visible(spec: mini, surface: VideoMiniSurface.pictureInPicture),
        isFalse,
      );
      expect(visible(surface: VideoMiniSurface.pictureInPicture), isFalse);
    });
  });

  group('videoMiniChromeVisible', () {
    final VideoControlsDensitySpec mini = resolveVideoControlsDensity(
      playerSize: const Size(320, 180),
      surface: VideoMiniSurface.desktopMiniWindow,
    );
    final VideoControlsDensitySpec full = resolveVideoControlsDensity(
      playerSize: const Size(1280, 720),
      surface: VideoMiniSurface.none,
    );
    final VideoControlsDensitySpec pip = resolveVideoControlsDensity(
      playerSize: const Size(320, 180),
      surface: VideoMiniSurface.pictureInPicture,
    );

    // 桌面小窗表面；hover（controlsVisible）在这条路径上不是输入。
    bool inMiniWindow(
      VideoControlsDensitySpec spec, {
      required bool revealed,
    }) => videoMiniChromeVisible(
      spec: spec,
      surface: VideoMiniSurface.desktopMiniWindow,
      revealed: revealed,
      controlsVisible: true,
    );

    test('mini 档：只认显式唤出', () {
      expect(inMiniWindow(mini, revealed: true), isTrue);
      expect(
        inMiniWindow(mini, revealed: false),
        isFalse,
        reason: '小窗常态只剩画面 + 字幕 + 底部细线；hover 不是本函数的输入，'
            '鼠标扫过不该弹出一层按钮',
      );
    });

    test('常规窗口被挤窄到 mini 档（surface none）：chrome 跟 hover 走，不认唤出位', () {
      // media_kit 那层已整套关掉，三键是画面上唯一的控件；只认快捷键会让鼠标用户
      // 悬停一个按钮都不出现（#1596 时 hover 还能唤出）。
      expect(
        videoMiniChromeVisible(
          spec: mini,
          surface: VideoMiniSurface.none,
          revealed: false,
          controlsVisible: true,
        ),
        isTrue,
      );
      expect(
        videoMiniChromeVisible(
          spec: mini,
          surface: VideoMiniSurface.none,
          revealed: true,
          controlsVisible: false,
        ),
        isFalse,
        reason: '常规窗口里唤出位没人该读',
      );
    });

    test('常规档恒不画：那一档的 chrome 归 media_kit（hover 唤起是它的语义）', () {
      expect(inMiniWindow(full, revealed: true), isFalse);
      expect(inMiniWindow(full, revealed: false), isFalse);
    });

    test('系统画中画恒不画：chrome 归系统，本仓再画一套就是两层按钮重影', () {
      expect(inMiniWindow(pip, revealed: true), isFalse);
    });
  });
}
