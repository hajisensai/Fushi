import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_chapter_markers.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';

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

  // media_kit 的 seek bar 无法在无头 libmpv 下驱动真实渲染，故页面层「刻度叠在 seek bar
  // 同一几何上」的接线用源码守卫锁定不变量（几何纯函数由上面的 widget/单元测试覆盖）。
  group('video_hibiki_page wires chapter markers onto seek bar (TODO-432)', () {
    final String src =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

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
  });
}
