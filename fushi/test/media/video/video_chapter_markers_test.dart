import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';
import '../../pages/video_fushi_page_source_corpus.dart';
import 'package:fushi/src/media/video/video_chapter_markers.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';

void main() {
  group('chapterMarkerFractions (TODO-432)', () {
    List<VideoChapter> mk(List<int> startsMs) {
      return <VideoChapter>[
        for (int i = 0; i < startsMs.length; i++)
          VideoChapter(
            index: i,
            title: 'C$i',
            start: Duration(milliseconds: startsMs[i]),
          ),
      ];
    }

    test('start/duration 映射成 [0,1) 比例（含首章 0.0）', () {
      // 5 章在 0 / 25% / 50% / 75% 处（总时长 1000s），第 5 章在 100% 被丢弃。
      final List<double> fractions = chapterMarkerFractions(
        chapters: mk(<int>[0, 250000, 500000, 750000, 1000000]),
        durationMs: 1000000,
      );
      expect(fractions, <double>[0.0, 0.25, 0.5, 0.75]);
    });

    test('durationMs <= 0（时长未知）=> 空（无刻度，待播放器就绪）', () {
      final List<VideoChapter> chapters = mk(<int>[0, 300000]);
      expect(
          chapterMarkerFractions(chapters: chapters, durationMs: 0), isEmpty);
      expect(
          chapterMarkerFractions(chapters: chapters, durationMs: -5), isEmpty);
    });

    test('start >= duration 的章节被丢弃（轨道最右端不画）', () {
      // 第 2 章起点等于总时长、第 3 章超过总时长，都丢弃。
      final List<double> fractions = chapterMarkerFractions(
        chapters: mk(<int>[0, 500000, 1000000, 1500000]),
        durationMs: 1000000,
      );
      expect(fractions, <double>[0.0, 0.5]);
    });

    test('同起点 / 同比例升序去重（不画重叠竖线）', () {
      final List<double> fractions = chapterMarkerFractions(
        chapters: mk(<int>[0, 0, 500000, 500000]),
        durationMs: 1000000,
      );
      expect(fractions, <double>[0.0, 0.5]);
    });

    test('空章节列表 => 空比例', () {
      expect(
        chapterMarkerFractions(
            chapters: const <VideoChapter>[], durationMs: 1000000),
        isEmpty,
      );
    });
  });

  group('videoSeekBarTrackBand (TODO-432)', () {
    test('桌面：刻度带以轨道中线（≈一个按钮行高）为中心、取 tickHeight 一小段', () {
      final ({double bottom, double height}) band = videoSeekBarTrackBand(
        isDesktop: true,
        buttonBarHeight: 56,
        seekBarButtonGap: 8,
        seekBarContainerHeight: 52,
        seekBarTrackHeight: 5,
        bottomChromeBaseline: 24,
        bottomSystemInset: 0,
        tickHeight: 13,
      );
      // 桌面轨道中线 = buttonBarHeight = 56；带底缘 = 56 - 13/2 = 49.5。
      expect(band.bottom, 49.5);
      expect(band.height, 13);
    });

    test('移动：刻度带以轨道中线（seekBarBottom + 轨道半高）为中心', () {
      // seekBarBottom = baseline(24) + inset(0) + buttonBar(56) + gap(8) = 88；
      // 轨道中线 = 88 + 5/2 = 90.5；带底缘 = 90.5 - 13/2 = 84。
      final ({double bottom, double height}) band = videoSeekBarTrackBand(
        isDesktop: false,
        buttonBarHeight: 56,
        seekBarButtonGap: 8,
        seekBarContainerHeight: 52,
        seekBarTrackHeight: 5,
        bottomChromeBaseline: 24,
        bottomSystemInset: 0,
        tickHeight: 13,
      );
      expect(band.bottom, 84);
      expect(band.height, 13);
    });

    test('移动：系统底部 inset（导航栏）叠进轨道中线 → 带底缘随之抬高', () {
      // seekBarBottom = 24 + 30 + 56 + 8 = 118；中线 = 118 + 2.5 = 120.5；底缘 = 114。
      final ({double bottom, double height}) band = videoSeekBarTrackBand(
        isDesktop: false,
        buttonBarHeight: 56,
        seekBarButtonGap: 8,
        seekBarContainerHeight: 52,
        seekBarTrackHeight: 5,
        bottomChromeBaseline: 24,
        bottomSystemInset: 30,
        tickHeight: 13,
      );
      expect(band.bottom, 114);
      expect(band.height, 13);
    });
  });

  group('VideoChapterMarkers widget (TODO-432)', () {
    testWidgets('有章节 + 已知时长 => 画刻度（CustomPaint 上墙）',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.debugSetChaptersForTesting(<VideoChapter>[
        const VideoChapter(index: 0, title: 'A', start: Duration.zero),
        const VideoChapter(index: 1, title: 'B', start: Duration(seconds: 300)),
        const VideoChapter(index: 2, title: 'C', start: Duration(seconds: 600)),
      ]);
      controller.debugSetDurationForTesting(1200000); // 1200s

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 20,
              child: VideoChapterMarkers(
                controller: controller,
                color: const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      );

      // 有章节 + 时长已知：CustomPaint 真渲染（painter 非空），非 SizedBox.shrink。
      final Finder paint = find.descendant(
        of: find.byType(VideoChapterMarkers),
        matching: find.byType(CustomPaint),
      );
      expect(paint, findsWidgets);
      final CustomPaint widget = tester.widgetList<CustomPaint>(paint).last;
      expect(widget.painter, isNotNull);
    });

    testWidgets('时长未知（duration=0）=> 不画（SizedBox.shrink）',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.debugSetChaptersForTesting(<VideoChapter>[
        const VideoChapter(index: 0, title: 'A', start: Duration.zero),
        const VideoChapter(index: 1, title: 'B', start: Duration(seconds: 300)),
      ]);
      // 不设 duration override：durationMs 回退 null（无 Player）→ chapterMarkerFractions 空。

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 20,
              child: VideoChapterMarkers(
                controller: controller,
                color: const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      );

      // 时长未知：折叠成 SizedBox.shrink，没有 CustomPaint 画刻度。
      expect(
        find.descendant(
          of: find.byType(VideoChapterMarkers),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    testWidgets('时长就绪后通知 => 刻度即时出现（换片 / 媒体头解析）', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.debugSetChaptersForTesting(<VideoChapter>[
        const VideoChapter(index: 0, title: 'A', start: Duration.zero),
        const VideoChapter(index: 1, title: 'B', start: Duration(seconds: 300)),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 20,
              child: VideoChapterMarkers(
                controller: controller,
                color: const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      );
      // 初始时长未知：无刻度。
      expect(
        find.descendant(
          of: find.byType(VideoChapterMarkers),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );

      // 媒体头解析出时长 → controller 通知 → AnimatedBuilder 重绘 → 刻度出现。
      controller.debugSetDurationForTesting(600000);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(VideoChapterMarkers),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });
  });

  // BUG-1783：刻度层与 seek bar 轨道的**水平基准**必须同源。这一组直接编码 bug 的数学
  // 形式——旧守卫只断言 builder 体里出现字符串 `left: 16` / `right: 16`，而当年的 SafeArea
  // 就叠在那个 Padding 外面，字符串照样命中、守卫恒绿。字面量存在 ≠ 基准一致。
  group('videoControlsChromeInsets (BUG-1783)', () {
    // 横屏刘海机：`shortEdges` 让 cutout 落在左 / 右短边（实测反算 padding.left ≈ 45）。
    const EdgeInsets cutout = EdgeInsets.only(left: 45, right: 30);

    test('非全屏路由：系统安全区再大，控制条外层 padding 也恒为零', () {
      expect(
        videoControlsChromeInsets(
          isFullscreenRoute: false,
          systemPadding: cutout,
        ),
        EdgeInsets.zero,
        reason: 'fork 窗口态走 EdgeInsets.zero 分支；移动端因 BUG-221 永远落在这一支，'
            '刻度层多缩一段就会与轨道分叉',
      );
    });

    test('全屏路由：与 media_kit 一样吃系统安全区', () {
      expect(
        videoControlsChromeInsets(
          isFullscreenRoute: true,
          systemPadding: cutout,
        ),
        cutout,
      );
    });

    test('controls theme 显式设了 padding 时以它为准（两条路径都是）', () {
      const EdgeInsets themed = EdgeInsets.all(4);
      for (final bool fullscreen in <bool>[false, true]) {
        expect(
          videoControlsChromeInsets(
            isFullscreenRoute: fullscreen,
            systemPadding: cutout,
            themePadding: themed,
          ),
          themed,
        );
      }
    });

    test('刘海横屏下刻度层与轨道左右边界逐像素相等', () {
      // 用户那台机：2532×1170 @ DPR 3 → 844 逻辑宽。
      const double w = 844;
      final EdgeInsets insets = videoControlsChromeInsets(
        isFullscreenRoute: false,
        systemPadding: cutout,
      );
      // 轨道（fork material.dart 窗口态 + seekBarMargin 16）：不含任何安全区。
      double trackX(double f) => 16 + f * (w - 32);
      // 刻度层：控制条外层 padding + 同样的 16，内部按剩余宽线性。
      double markerX(double f) =>
          insets.left + 16 + f * (w - 32 - insets.horizontal);
      for (final double f in <double>[0, 0.25, 0.5, 0.75, 1]) {
        expect(
          markerX(f),
          closeTo(trackX(f), 0.001),
          reason: 'f=$f 处刻度与轨道错位——修前的 SafeArea 让误差 '
              'Δ(f)=padding.left−f·padding.horizontal 随比例斜切：'
              '首章右偏、末章左偏、中间某点恰好蒙对',
        );
      }
    });
  });

  // media_kit 的 seek bar 无法在无头 libmpv 下驱动真实渲染，故页面层「刻度叠在 seek bar
  // 同一几何上」的接线用源码守卫锁定不变量（几何纯函数由上面的 widget/单元测试覆盖）。
  group('video_fushi_page wires chapter markers onto seek bar (TODO-432)', () {
    // 章节刻度层 builder 已搬进 video_fushi/chapter.part.dart（TODO-590 batch8），
    // 读「主壳 + 全部 part」合并语料才能切到 builder 定义体。
    final String src = readVideoFushiSource();

    test('controls Stack 挂了 _buildChapterMarkersOverlay 层', () {
      expect(src.contains('_buildChapterMarkersOverlay(controller)'), isTrue,
          reason: 'controls Stack 必须挂章节刻度层，否则进度条上不显示刻度');
      expect(src.contains('Widget _buildChapterMarkersOverlay('), isTrue,
          reason: '刻度层 builder 缺失');
    });

    test('刻度层仅有章节时挂、几何对齐 seek bar、随控制条显隐', () {
      final int start = src.indexOf('Widget _buildChapterMarkersOverlay(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = src.indexOf('Widget _buildChapterSidePanel(', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      // 仅有章节时挂（无章节折叠成 SizedBox.shrink）。
      expect(body.contains('if (!_hasChapters) return const SizedBox.shrink()'),
          isTrue,
          reason: '无章节时不该画刻度');
      // 竖直锚定走纯函数 videoSeekBarTrackBand（与 seek bar 同源几何）。
      expect(body.contains('videoSeekBarTrackBand('), isTrue,
          reason: '刻度竖直位置必须用 videoSeekBarTrackBand 对齐 seek bar 轨道');
      // 水平内缩 16 对齐 seekBarMargin。
      expect(body.contains('left: 16') && body.contains('right: 16'), isTrue,
          reason: '刻度水平范围必须左右各内缩 16 对齐 seekBarMargin');
      // 随控制条可见性显隐，与 seek bar 同步。
      expect(body.contains('_videoControlsVisible'), isTrue,
          reason: '刻度必须随控制条显隐，与 seek bar 同步');
      // 纯视觉层不拦指针，不破坏 seek bar 拖动。
      expect(body.contains('IgnorePointer'), isTrue,
          reason: '刻度层必须 IgnorePointer，否则会拦掉 seek bar 拖动');
    });

    // BUG-1783：两个叠在 controls Stack 上的兄弟层都不许自己吃系统安全区。
    //
    // 用 methodBody 而不是「下一个方法签名」做切片：两个 builder 在文件里的先后顺序
    // 一变，手写的结束锚点就会把整段剩余语料吞进 body，负向断言随即失去意义（实测正是
    // 这样先红的）。methodBody 自己做花括号配对并掩掉注释——后者同样必要：修复本身在
    // 注释里解释了「原本是 SafeArea、为什么不能用」，裸 contains 会把说明当违规命中。
    test('刻度层与缩略图预览层都走 _videoControlsChromeInsets，不再套 SafeArea', () {
      for (final (String name, String signature) in <(String, String)>[
        ('章节刻度层', 'Widget _buildChapterMarkersOverlay('),
        ('缩略图预览层', 'Widget _buildThumbnailPreviewOverlay('),
      ]) {
        final String body = maskComments(methodBody(src, signature));
        expect(
          body.contains('SafeArea'),
          isFalse,
          reason: '$name 不得套 SafeArea：它恒吃 MediaQuery.padding，而 media_kit 轨道在'
              '非全屏路由下恒零内缩（移动端因 BUG-221 永远是非全屏），两者基准会分叉',
        );
        expect(
          body.contains('_videoControlsChromeInsets()'),
          isTrue,
          reason: '$name 的外层 padding 必须走 _videoControlsChromeInsets()，'
              '与 media_kit 控制条同一条真相',
        );
      }
    });
  });
}
