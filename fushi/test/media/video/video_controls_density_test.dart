import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_controls_density.dart';

/// 「小窗模式 / 按窗口大小缩控件」的判据真相源。页面只读本文件的结论，
/// 所以阈值与取舍在这里钉死一次即可，不必去 widget 树里翻。
void main() {
  group('videoPortraitToolbarInlineCount：竖屏工具栏平铺几颗（拍板台 jJt0PSb1LO）', () {
    // MD3：48 + 4 缝、两端 8，再乘胶囊缩放 48/56。
    const double scale = 48 / 56;
    const VideoPortraitToolbarMetrics md3 = VideoPortraitToolbarMetrics(
      slotWidth: 52 * scale,
      chromeWidth: 12 * scale,
    );
    // Apple：44 无缝、两端 4。
    const VideoPortraitToolbarMetrics apple = VideoPortraitToolbarMetrics(
      slotWidth: 44,
      chromeWidth: 8,
    );

    test('360dp 手机（两侧各留 16）：6 颗常驻 +「⋯」，四颗可收项全进「⋯」', () {
      for (final VideoPortraitToolbarMetrics m in <VideoPortraitToolbarMetrics>[
        md3,
        apple,
      ]) {
        expect(
          videoPortraitToolbarInlineCount(
            availableWidth: 360 - 32,
            pinned: 6,
            foldable: 4,
            metrics: m,
          ),
          0,
        );
        // 6 + ⋯ 必须真放得下（设计图的前提）。
        expect(m.widthFor(7), lessThanOrEqualTo(360 - 32));
      }
    });

    test('宽一些的手机多平铺几颗，按优先级从前往后', () {
      // 412dp：MD3 8 颗（6 + 收藏 + ⋯）= 12·s + 8·52·s ≈ 366.9 ≤ 380。
      expect(
        videoPortraitToolbarInlineCount(
          availableWidth: 412 - 32,
          pinned: 6,
          foldable: 4,
          metrics: md3,
        ),
        1,
      );
      // Apple 每格 44：412 宽 = 380 → 6 + 2 + ⋯ = 9 格 404 > 380，6 + 1 + ⋯ = 360 ≤ 380。
      expect(
        videoPortraitToolbarInlineCount(
          availableWidth: 412 - 32,
          pinned: 6,
          foldable: 4,
          metrics: apple,
        ),
        1,
      );
    });

    test('全部平铺放得下就不留「⋯」那一格', () {
      // 10 颗全平铺 = 8 + 440 = 448；带「⋯」时只能 9 + 1 格。宽 448 应全部平铺。
      expect(
        videoPortraitToolbarInlineCount(
          availableWidth: apple.widthFor(10),
          pinned: 6,
          foldable: 4,
          metrics: apple,
        ),
        4,
      );
      // 少 1 像素就放不下全部，得留「⋯」：6 + 2 + ⋯ = 9 格。
      expect(
        videoPortraitToolbarInlineCount(
          availableWidth: apple.widthFor(10) - 1,
          pinned: 6,
          foldable: 4,
          metrics: apple,
        ),
        2,
      );
    });

    test('宽度未量出 / 没有可收项', () {
      expect(
        videoPortraitToolbarInlineCount(
          availableWidth: double.infinity,
          pinned: 6,
          foldable: 4,
          metrics: md3,
        ),
        0,
      );
      expect(
        videoPortraitToolbarInlineCount(
          availableWidth: 0,
          pinned: 6,
          foldable: 4,
          metrics: md3,
        ),
        0,
      );
      expect(
        videoPortraitToolbarInlineCount(
          availableWidth: 1000,
          pinned: 6,
          foldable: 0,
          metrics: md3,
        ),
        0,
      );
    });
  });

  group('videoInitialMiniSurface：新挂载的视频页以哪个表面起步', () {
    test('BUG-4804：已在系统画中画里 → 新页直接以 pictureInPicture 起步', () {
      // 本地换集是 pushReplacement 的新页；PiP 里自动连播到下一集时系统窗口没动，
      // 新页收不到「进入」事件，起步值错了就一直错到用户退出 PiP。
      final VideoMiniSurface surface = videoInitialMiniSurface(
        desktopMiniWindowClaimed: false,
        pictureInPictureActive: true,
      );
      expect(surface, VideoMiniSurface.pictureInPicture);
      expect(surface.systemOwnsChrome, isTrue);
      // 起步表面决定密度档：PiP 档在画面里一个 chrome 都不画（宽度再大也一样）。
      final VideoControlsDensitySpec spec = resolveVideoControlsDensity(
        playerSize: const Size(1280, 720),
        surface: surface,
      );
      expect(spec.showTopBar, isFalse);
      expect(spec.showSeekBar, isFalse);
      expect(spec.showCenterTransport, isFalse);
    });

    test('桌面接过了上一集的小窗 → desktopMiniWindow', () {
      expect(
        videoInitialMiniSurface(
          desktopMiniWindowClaimed: true,
          pictureInPictureActive: false,
        ),
        VideoMiniSurface.desktopMiniWindow,
      );
    });

    test('两边都没有小窗 → none（常规起播不受影响）', () {
      expect(
        videoInitialMiniSurface(
          desktopMiniWindowClaimed: false,
          pictureInPictureActive: false,
        ),
        VideoMiniSurface.none,
      );
    });
  });

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
      showTopBar: true,
      showBottomButtonBar: true,
      showCenterTransport: false,
    );
    const VideoControlsDensitySpec mini = VideoControlsDensitySpec(
      density: VideoControlsDensity.mini,
      scale: 0.72,
      showSeekBar: false,
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
        reason:
            '小窗常态只剩画面 + 字幕 + 底部细线；hover 不是本函数的输入，'
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

  // 字幕列表开 / 关卡顿：侧栏宽度动画每帧都改播放区宽度，controls 子树不能跟着
  // 每帧重建，只有换档才重建。
  group('VideoControlsDensityBuilder', () {
    Widget host({
      required double width,
      required ValueNotifier<VideoMiniSurface> surface,
      required List<VideoControlsDensity> builds,
      Color color = const Color(0xFF000000),
    }) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 400,
            child: ColoredBox(
              color: color,
              child: VideoControlsDensityBuilder(
                surface: surface,
                builder: (BuildContext _, VideoControlsDensitySpec spec) {
                  builds.add(spec.density);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('宽度连续变化但档位不变时不重建子树', (WidgetTester tester) async {
      final ValueNotifier<VideoMiniSurface> surface =
          ValueNotifier<VideoMiniSurface>(VideoMiniSurface.none);
      addTearDown(surface.dispose);
      final List<VideoControlsDensity> builds = <VideoControlsDensity>[];
      final ValueNotifier<double> width = ValueNotifier<double>(1400);
      addTearDown(width.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<double>(
          valueListenable: width,
          builder: (BuildContext _, double w, __) => Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: w,
                height: 400,
                child: _Inner(surface: surface, builds: builds),
              ),
            ),
          ),
        ),
      );
      expect(builds, <VideoControlsDensity>[VideoControlsDensity.full]);
      // 模拟侧栏挤窄动画：1400 → 900 逐帧收窄，全程 full 档。
      for (double w = 1380; w >= 900; w -= 20) {
        width.value = w;
        await tester.pump();
      }
      expect(builds, <VideoControlsDensity>[VideoControlsDensity.full]);
      // 跨过 compact 阈值才重建一次。
      width.value = kVideoControlsCompactWidth - 1;
      await tester.pump();
      width.value = kVideoControlsCompactWidth - 40;
      await tester.pump();
      expect(builds, <VideoControlsDensity>[
        VideoControlsDensity.full,
        VideoControlsDensity.compact,
      ]);
    });

    testWidgets('父级重建与小窗表面变化照常刷到子树', (WidgetTester tester) async {
      final ValueNotifier<VideoMiniSurface> surface =
          ValueNotifier<VideoMiniSurface>(VideoMiniSurface.none);
      addTearDown(surface.dispose);
      final List<VideoControlsDensity> builds = <VideoControlsDensity>[];
      await tester.pumpWidget(
        host(width: 1400, surface: surface, builds: builds),
      );
      // 父级换了新的 widget（外层状态变化）：必须重建，不能吃缓存。
      await tester.pumpWidget(
        host(
          width: 1400,
          surface: surface,
          builds: builds,
          color: const Color(0xFF111111),
        ),
      );
      expect(builds, <VideoControlsDensity>[
        VideoControlsDensity.full,
        VideoControlsDensity.full,
      ]);
      // 只改小窗表面、尺寸不变：重新解档并重建。
      surface.value = VideoMiniSurface.desktopMiniWindow;
      await tester.pump();
      expect(builds.last, VideoControlsDensity.mini);
    });
  });
}

/// 只把 [VideoControlsDensityBuilder] 建一次：外层只改宽度时它收不到新配置，
/// 单纯验证「约束变化」这一条路径。
class _Inner extends StatefulWidget {
  const _Inner({required this.surface, required this.builds});

  final ValueNotifier<VideoMiniSurface> surface;
  final List<VideoControlsDensity> builds;

  @override
  State<_Inner> createState() => _InnerState();
}

class _InnerState extends State<_Inner> {
  late final Widget _child = VideoControlsDensityBuilder(
    surface: widget.surface,
    builder: (BuildContext _, VideoControlsDensitySpec spec) {
      widget.builds.add(spec.density);
      return const SizedBox.expand();
    },
  );

  @override
  Widget build(BuildContext context) => _child;
}
