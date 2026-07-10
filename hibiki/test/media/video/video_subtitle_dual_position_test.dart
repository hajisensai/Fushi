import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1341 守卫：双字幕（同轨时间重叠、锚点各异的 cue，如 OP/ED 顶部 \an8 歌词 + 底部
/// \an2 对白）同时在屏时，两条必须**各就各位**（顶部的在顶、底部的在底），不再被单一
/// 「代表」cue 的位置裹挟到同一处、随 currentCue 翻转在顶/底来回跳；且每条 cue 遵循**自己
/// 的**自带样式（双轨样式独立）。
///
/// 根因（修复前）：`_buildSubtitleLayer` 把整层活动 cue 塞进一个 Column、用 currentCue 单一
/// pos/anchor 定位 → 两条锚点不同的字幕共位、代表 cue 翻转时整列来回跳。
/// 修复：按 \pos/\an 锚点分组，不同锚点各自独立定位（[Stack] 叠放）。
AudioCue _cueWithMarkup(
  String text,
  SubtitleMarkup markup, {
  int start = 0,
  int end = 8000,
}) =>
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = text
      ..markup = markup
      ..startMs = start
      ..endMs = end
      ..audioFileIndex = 0;

SubtitleMarkup _markup(
  String text, {
  required SubtitleVAlign valign,
  int? primaryColorArgb,
}) =>
    SubtitleMarkup(
      plainText: text,
      spans: const <SubtitleSpan>[],
      anchor: SubtitleAnchor(valign, SubtitleHAlign.center),
      cueStyle: primaryColorArgb == null
          ? null
          : SubtitleCueStyle(primaryColorArgb: primaryColorArgb),
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

Text _fillOf(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .firstWhere((Text t) => t.style?.foreground == null);

void main() {
  group('TODO-1341 双字幕各就各位（不同锚点独立定位，不来回跳）', () {
    testWidgets('顶部 \\an8 + 底部 \\an2 重叠：顶部在上、底部在下（不共位）',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      // A 顶部歌词 0-5000、B 底部对白 2000-8000；3000 处两条同时活动。
      c.setCues(<AudioCue>[
        _cueWithMarkup('上', _markup('上', valign: SubtitleVAlign.top),
            start: 0, end: 5000),
        _cueWithMarkup('下', _markup('下', valign: SubtitleVAlign.bottom),
            start: 2000, end: 8000),
      ]);
      c.debugUpdateCueForPosition(3000);
      // 两条都活动。
      expect(c.activeCues.map((AudioCue e) => e.text).toList(),
          <String>['上', '下']);

      await _pump(tester, VideoSubtitleOverlay(controller: c));

      // 默认统一外观：每字单层 Text（Niratan 软投影），两条都在屏 → 各 1 个。
      expect(find.text('上'), findsOneWidget);
      expect(find.text('下'), findsOneWidget);

      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      final double topDy = tester.getCenter(find.text('上').first).dy;
      final double bottomDy = tester.getCenter(find.text('下').first).dy;
      // 核心：顶部字幕落画面上半、底部字幕落下半——修复前两条会被裹挟到同一处。
      expect(topDy, lessThan(overlayRect.center.dy),
          reason: '\\an8 顶部字幕必须在画面上半');
      expect(bottomDy, greaterThan(overlayRect.center.dy),
          reason: '\\an2 底部字幕必须在画面下半');
      expect(bottomDy - topDy, greaterThan(100), reason: '两条锚点不同的字幕应明显分离，而非共位');
    });

    testWidgets('代表 cue（currentCue）翻转不改变各自位置（消除「来回变」）',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cueWithMarkup('上', _markup('上', valign: SubtitleVAlign.top),
            start: 0, end: 5000),
        _cueWithMarkup('下', _markup('下', valign: SubtitleVAlign.bottom),
            start: 2000, end: 8000),
      ]);

      // 位置 2500：currentCue 为其一。
      c.debugUpdateCueForPosition(2500);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      final Rect r1 = tester.getRect(find.byType(VideoSubtitleOverlay));
      final double top1 = tester.getCenter(find.text('上').first).dy;
      final double bottom1 = tester.getCenter(find.text('下').first).dy;
      expect(top1, lessThan(r1.center.dy));
      expect(bottom1, greaterThan(r1.center.dy));

      // 位置 4500：currentCue 可能翻转到另一条；两条位置必须保持不变（不来回跳）。
      c.debugUpdateCueForPosition(4500);
      await tester.pump();
      final double top2 = tester.getCenter(find.text('上').first).dy;
      final double bottom2 = tester.getCenter(find.text('下').first).dy;
      expect(top2, lessThan(r1.center.dy), reason: '顶部字幕不得随 currentCue 翻转跳到底部');
      expect(bottom2, greaterThan(r1.center.dy),
          reason: '底部字幕不得随 currentCue 翻转跳到顶部');
      // 位置几何稳定（同锚点定位纯函数，不受代表 cue 影响）。
      expect((top2 - top1).abs(), lessThan(1.0));
      expect((bottom2 - bottom1).abs(), lessThan(1.0));
    });

    testWidgets('双轨样式独立：每条 cue 遵循自己的主色（respectAssStyle）',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cueWithMarkup(
            '赤',
            _markup('赤',
                valign: SubtitleVAlign.top, primaryColorArgb: 0xFFFF0000),
            start: 0,
            end: 5000),
        _cueWithMarkup(
            '緑',
            _markup('緑',
                valign: SubtitleVAlign.bottom, primaryColorArgb: 0xFF00FF00),
            start: 2000,
            end: 8000),
      ]);
      c.debugUpdateCueForPosition(3000);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          textColor: const Color(0xFF112233),
          respectAssStyle: true,
        ),
      );
      // 顶部 cue 用自己的红、底部 cue 用自己的绿——双轨样式互不串（修复前也应独立，但
      // 位置修复后这条守住「双轨各遵自带样式」的整体契约）。
      expect(_fillOf(tester, '赤').style?.color, const Color(0xFFFF0000));
      expect(_fillOf(tester, '緑').style?.color, const Color(0xFF00FF00));
    });

    testWidgets('同锚点重叠 cue 仍归一堆叠（不因分组回归多位置）', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      // 两条同为底部锚点、时间重叠 → 应堆叠进同一底部组（都在下半屏）。
      c.setCues(<AudioCue>[
        _cueWithMarkup('一', _markup('一', valign: SubtitleVAlign.bottom),
            start: 0, end: 5000),
        _cueWithMarkup('二', _markup('二', valign: SubtitleVAlign.bottom),
            start: 2000, end: 8000),
      ]);
      c.debugUpdateCueForPosition(3000);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      expect(tester.getCenter(find.text('一').first).dy,
          greaterThan(overlayRect.center.dy));
      expect(tester.getCenter(find.text('二').first).dy,
          greaterThan(overlayRect.center.dy));
    });
  });
}
