import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_chapter_markers.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';

/// BUG-3062：移动端章节刻度没落在进度条轨道上。
///
/// 真页面（media_kit + libmpv）在无头测试里起不来，这里按 fork `material.dart` 的移动端
/// 布局原样搭一个控件区：进度条热区容器靠 `seekBarMargin`（左右内缩 + bottom）摆在
/// bottomCenter Stack 里、里面是**真的** [VideoM3eSeekTrack]；章节刻度层按页面同一套
/// 外层结构（左右内缩 + band.bottom + Align.bottomCenter + SizedBox(band.height)）叠上去。
/// 两边只共享页面也在用的纯函数（[videoSeekBarContainerBottom] /
/// [videoM3eSeekTrackCenterFromBottom] / [videoSeekBarTrackBand]），断言的是**画出来的**
/// 轨道与刻度：轨道手柄 x / 中线 y 从 M3E 轨道拖动时的时间气泡反推（气泡底边中点 =
/// (w·f, centerY − 14·scale)），刻度 x / 带中线从刻度层的真实布局盒取。
void main() {
  const double baseline = 8; // _videoBottomChromeBaseline
  const double lift = 12; // M3E 浮动底栏抬升（任意正值即可）
  const double side = 24; // _videoSeekBarSideInset

  ({
    double containerBottom,
    double containerHeight,
    double scale,
    double trackCenter,
  })
  geometry({
    required double uiScale,
    required double density,
    required double systemInset,
  }) {
    final double containerBottom = videoSeekBarContainerBottom(
      isDesktop: false,
      buttonBarHeight: 56 * uiScale * density,
      seekBarButtonGap: 8 * uiScale * density,
      floatingLift: lift,
      bottomChromeBaseline: baseline,
      bottomSystemInset: systemInset,
      desktopButtonBarOverlap: 0,
    );
    final double containerHeight = 40 * uiScale * density;
    final double scale = uiScale * density;
    return (
      containerBottom: containerBottom,
      containerHeight: containerHeight,
      scale: scale,
      trackCenter:
          containerBottom +
          videoM3eSeekTrackCenterFromBottom(
            containerHeight: containerHeight,
            scale: scale,
            alignment: Alignment.bottomCenter,
          ),
    );
  }

  Widget harness({
    required Size size,
    required double uiScale,
    required double density,
    required double systemInset,
    required double position,
    required VideoPlayerController controller,
  }) {
    final g = geometry(
      uiScale: uiScale,
      density: density,
      systemInset: systemInset,
    );
    final double tickHeight = (5 * uiScale + 8 * uiScale) * density;
    final ({double bottom, double height}) band = videoSeekBarTrackBand(
      trackCenter: g.trackCenter,
      tickHeight: tickHeight,
    );
    return MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: SizedBox.fromSize(
          size: size,
          child: Stack(
            children: <Widget>[
              // fork material.dart：进度条与按钮行同在 bottomCenter Stack，
              // 进度条靠 seekBarMargin 抬起、左右内缩。
              Positioned.fill(
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: <Widget>[
                    Container(
                      key: const ValueKey<String>('track'),
                      margin: EdgeInsets.only(
                        left: side,
                        right: side,
                        bottom: g.containerBottom,
                      ),
                      height: g.containerHeight,
                      child: VideoM3eSeekTrack(
                        visual: VideoSeekBarVisual(
                          position: position,
                          buffer: 0,
                          hover: position,
                          hovering: false,
                          dragging: true,
                          playing: false,
                          duration: const Duration(minutes: 20),
                          alignment: Alignment.bottomCenter,
                        ),
                        color: Colors.purple,
                        scale: g.scale,
                      ),
                    ),
                  ],
                ),
              ),
              // 章节刻度层：与 _buildChapterMarkersOverlay 同一外层结构。
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: side,
                    right: side,
                    bottom: band.bottom,
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      height: band.height,
                      width: double.infinity,
                      child: VideoChapterMarkers(
                        key: const ValueKey<String>('markers'),
                        controller: controller,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 手机横屏宽度：full（≥800）与 compact（480–800）两档；mini 档不画进度条，刻度层
  // 直接不挂（见下方源码守卫）。
  final List<
    ({String name, Size size, double density, double uiScale, double inset})
  >
  cases =
      <
        ({String name, Size size, double density, double uiScale, double inset})
      >[
        (
          name: 'full 844×390',
          size: const Size(844, 390),
          density: 1,
          uiScale: 1,
          inset: 0,
        ),
        (
          name: 'full 915×412 + 手势栏 inset',
          size: const Size(915, 412),
          density: 1,
          uiScale: 1.25,
          inset: 24,
        ),
        (
          name: 'compact 740×360',
          size: const Size(740, 360),
          density: 0.88,
          uiScale: 1,
          inset: 0,
        ),
        (
          name: 'compact 667×375 界面放大',
          size: const Size(667, 375),
          density: 0.88,
          uiScale: 1.15,
          inset: 16,
        ),
      ];

  for (final c in cases) {
    testWidgets('BUG-3062 ${c.name}：章节刻度 x / 中线与 M3E 轨道手柄一致', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = c.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      const int durationMs = 1200000;
      controller.debugSetDurationForTesting(durationMs);
      // 0、中间若干点、末尾附近（< 1，末尾 == 时长的章节按约定不画）。
      const List<double> fractions = <double>[0, 0.137, 0.5, 0.83, 0.999];
      controller.debugSetChaptersForTesting(<VideoChapter>[
        for (int i = 0; i < fractions.length; i++)
          VideoChapter(
            index: i,
            title: 'C$i',
            start: Duration(milliseconds: (fractions[i] * durationMs).round()),
          ),
      ]);
      final double scale = c.uiScale * c.density;

      for (final double f in fractions) {
        await tester.pumpWidget(
          harness(
            size: c.size,
            uiScale: c.uiScale,
            density: c.density,
            systemInset: c.inset,
            position: f,
            controller: controller,
          ),
        );
        await tester.pump();

        // 轨道：拖动时的时间气泡底边中点 = (手柄 x, 轨道中线 − 14·scale)。
        final Finder bubble = find.descendant(
          of: find.descendant(
            of: find.byType(VideoM3eSeekTrack),
            matching: find.byType(FractionalTranslation),
          ),
          matching: find.byType(Container),
        );
        expect(bubble, findsOneWidget);
        final Offset bubbleBottom =
            tester.getBottomLeft(bubble.first) +
            Offset(tester.getSize(bubble.first).width / 2, 0);
        final double thumbX = bubbleBottom.dx;
        final double trackY = bubbleBottom.dy + 14 * scale;

        // 刻度：刻度层画布宽内按比例线性摆放（首尾 clamp 半条线宽）。
        final Rect markers = tester.getRect(
          find.byKey(const ValueKey<String>('markers')),
        );
        const double half = 1; // 默认 thickness 2 的一半
        final double markerX = (markers.left + f * markers.width).clamp(
          markers.left + half,
          markers.right - half,
        );

        expect(
          markerX,
          closeTo(thumbX, half + 0.01),
          reason: '${c.name} f=$f：章节刻度 x 偏离轨道手柄 x',
        );
        expect(
          markers.center.dy,
          closeTo(trackY, 0.01),
          reason:
              '${c.name} f=$f：刻度带中线不在轨道中线上（BUG-3062 修前移动端 '
              'full 档整条落在轨道下方 7.5×缩放、compact 档还按未缩小的按钮行抬高）',
        );
        // 刻度带必须真的盖住轨道线（轨道静止 3·scale、拖动 6·scale 粗）。
        expect(markers.top, lessThan(trackY - 3 * scale));
        expect(markers.bottom, greaterThan(trackY + 3 * scale));
      }
    });
  }

  test('videoM3eSeekTrackCenterFromBottom：底对齐 10×缩放 / 显式 inset 优先 / 居中', () {
    expect(
      videoM3eSeekTrackCenterFromBottom(
        containerHeight: 40,
        scale: 1.5,
        alignment: Alignment.bottomCenter,
      ),
      15,
    );
    expect(
      videoM3eSeekTrackCenterFromBottom(
        containerHeight: 40,
        scale: 1.5,
        alignment: Alignment.bottomCenter,
        trackBottomInset: 26,
      ),
      26,
    );
    expect(
      videoM3eSeekTrackCenterFromBottom(
        containerHeight: 40,
        scale: 1,
        alignment: Alignment.center,
      ),
      20,
    );
  });

  test('videoSeekBarContainerBottom：移动端 = 基线+inset+抬升+按钮行+间距；桌面骑按钮行上沿', () {
    expect(
      videoSeekBarContainerBottom(
        isDesktop: false,
        buttonBarHeight: 49.28,
        seekBarButtonGap: 7.04,
        floatingLift: 12,
        bottomChromeBaseline: 8,
        bottomSystemInset: 24,
        desktopButtonBarOverlap: 0,
      ),
      closeTo(8 + 24 + 12 + 49.28 + 7.04, 1e-9),
    );
    expect(
      videoSeekBarContainerBottom(
        isDesktop: true,
        buttonBarHeight: 56,
        seekBarButtonGap: 8,
        floatingLift: 12,
        bottomChromeBaseline: 8,
        bottomSystemInset: 24,
        desktopButtonBarOverlap: 16,
      ),
      12 + 56 - 16,
    );
  });

  // 页面层接线：真页面起不来，用源码守卫钉住「刻度 / 主题 / 暗角 / 胶囊同一个几何来源」。
  group('BUG-3062 页面接线同源', () {
    final String src = readVideoFushiSource();

    test('M3E 轨道 widget 自己也按 videoM3eSeekTrackCenterFromBottom 画中线', () {
      final String chrome = maskComments(
        File('lib/src/media/video/video_m3e_chrome.dart').readAsStringSync(),
      );
      final String build = methodBody(
        chrome.substring(chrome.indexOf('class _VideoM3eSeekTrackState')),
        'Widget build(BuildContext context)',
      );
      expect(build.contains('videoM3eSeekTrackCenterFromBottom('), isTrue);
      expect(build.contains('(6 + 4)'), isFalse, reason: '不得再内联第二份中线公式');
    });

    test('_videoSeekBarTrackCenter 由容器底缘 + M3E 轨道中线函数组成', () {
      final String body = maskComments(
        methodBody(src, 'double get _videoSeekBarTrackCenter'),
      );
      expect(body.contains('_videoSeekBarContainerBottom'), isTrue);
      expect(body.contains('videoM3eSeekTrackCenterFromBottom('), isTrue);
      expect(body.contains('_controlsDensityScale'), isTrue);
    });

    test('刻度层 / 缩略图层 / 自动连播卡都按 _videoSeekBarTrackCenter 锚定', () {
      for (final String sig in <String>[
        'Widget _buildChapterMarkersOverlay(',
        'Widget _buildThumbnailPreviewOverlay(',
        'Widget _buildAutoAdvanceOverlay(',
      ]) {
        final String body = maskComments(methodBody(src, sig));
        expect(
          body.contains('trackCenter: _videoSeekBarTrackCenter'),
          isTrue,
          reason: '$sig 必须从真实轨道中线取刻度带',
        );
      }
      final String chapter = maskComments(
        methodBody(src, 'Widget _buildChapterMarkersOverlay('),
      );
      expect(
        chapter.contains('_controlsDensity.showSeekBar'),
        isTrue,
        reason: 'mini 档没有进度条，刻度层不该挂',
      );
    });

    test('移动端主题的 seekBarMargin.bottom 走 videoSeekBarContainerBottom', () {
      final String body = maskComments(
        methodBody(src, 'MaterialVideoControlsThemeData _mobileControlsTheme('),
      );
      expect(body.contains('videoSeekBarContainerBottom('), isTrue);
    });
  });
}
