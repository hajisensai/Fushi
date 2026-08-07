import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// TODO-1312：统一多层字幕渲染重构守卫。
/// ① 同轨时间轴重叠的多条 cue 都渲染（不因越过被选那条 end 落 gap 而闪烁 / 只显其一）。
/// ② 副字幕并入 Flutter overlay 副层一起渲染（画面顶部），并可逐字符查词（登记进同一
///    命中表，二维 = 哪条 cue + 该 cue 内 grapheme）。
AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  group('VideoPlayerController.activeCues 重叠 cue 全渲染（TODO-1312 ①）', () {
    test('重叠区两条 cue 都进 activeCues；越过一条 end 后仍连续（不清空/不闪）', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('X', 0, 3000), _cue('Y', 2000, 4000)]);

      // 只 cue0 覆盖。
      c.debugUpdateCueForPosition(1000);
      expect(c.activeCues.map((AudioCue e) => e.text).toList(), <String>['X']);

      // 重叠区：两条都活动（核心修复）。
      c.debugUpdateCueForPosition(2500);
      expect(c.activeCues.map((AudioCue e) => e.text).toList(),
          <String>['X', 'Y']);

      // cue0 已结束(>3000)：activeCues 仍非空（cue1 还在）——旧实现此刻会因 findCueIndex
      // 越过 cue0.end 而 overlay 清空/切换闪烁。
      c.debugUpdateCueForPosition(3500);
      expect(c.activeCues.map((AudioCue e) => e.text).toList(), <String>['Y']);
      // 代表 cue（查词锚 / 跳句旧路径）仍按 findCueIndex 单条选出，语义不变。
      expect(c.currentCue?.text, 'Y');
    });

    test('gap（无任何 cue 覆盖）：activeCues 清空 + currentCue 清空（BUG-074 语义保留）', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('X', 0, 1000), _cue('Y', 3000, 4000)]);
      c.debugUpdateCueForPosition(2000); // gap
      expect(c.activeCues, isEmpty);
      expect(c.currentCue, isNull);
      expect(c.currentCueIndex, -1);
    });
  });

  group('VideoPlayerController 副字幕 cue 流（TODO-1312 ②）', () {
    test('setSecondaryCues → secondaryActiveCues 随位置求活动集；clear 归空', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 5000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 1000, 4000)]);

      // pos 500：副字幕未开始。
      c.debugUpdateCueForPosition(500);
      expect(c.secondaryActiveCues, isEmpty);
      // pos 2000：副字幕活动。
      c.debugUpdateCueForPosition(2000);
      expect(c.secondaryActiveCues.map((AudioCue e) => e.text).toList(),
          <String>['副']);
      // 主字幕不受副字幕影响。
      expect(c.currentCue?.text, '主');

      c.clearSecondaryCues();
      c.debugUpdateCueForPosition(2000);
      expect(c.secondaryActiveCues, isEmpty);
    });
  });

  group('VideoSubtitleOverlay 多层渲染 + 二维查词（TODO-1312）', () {
    testWidgets('重叠 cue 两个字幕盒都渲染', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('X', 0, 5000), _cue('Y', 2000, 8000)]);
      c.debugUpdateCueForPosition(3000); // 重叠区
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      // 默认统一外观每字单层 Text（Niratan 软投影）。两条 cue 都在屏 → 各 1 个 Text。
      expect(find.text('X'), findsOneWidget);
      expect(find.text('Y'), findsOneWidget);
    });

    testWidgets('副字幕渲染在主字幕上方（画面顶部）', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 5000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 5000)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, VideoSubtitleOverlay(controller: c));

      expect(find.text('主'), findsOneWidget);
      expect(find.text('副'), findsOneWidget);
      final double mainDy = tester.getCenter(find.text('主').first).dy;
      final double secondaryDy = tester.getCenter(find.text('副').first).dy;
      expect(secondaryDy, lessThan(mainDy), reason: '副字幕应在画面顶部（dy 更小），主字幕在底部');
    });

    testWidgets('点副字幕字符 → onCharTap 带副字幕整句（二维查词）', (WidgetTester tester) async {
      String? tapped;
      int? tappedIndex;
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('あ', 0, 5000)]);
      c.setSecondaryCues(<AudioCue>[_cue('いう', 0, 5000)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect _) {
            tapped = s;
            tappedIndex = i;
          },
        ),
      );
      // 点副字幕第 2 个字 'う' → 归属副字幕整句 'いう'、grapheme 1。
      await tester.tapAt(tester.getCenter(find.text('う').first));
      await tester.pump();
      expect(tapped, 'いう');
      expect(tappedIndex, 1);
    });

    testWidgets('点主字幕字符仍查主字幕整句（有副字幕时不串层）', (WidgetTester tester) async {
      String? tapped;
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 5000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 5000)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect _) => tapped = s,
        ),
      );
      await tester.tapAt(tester.getCenter(find.text('主').first));
      await tester.pump();
      expect(tapped, '主');
    });

    testWidgets('hitTester 反查副字幕字符（点同句换词基础，二维）', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('あ', 0, 5000)]);
      c.setSecondaryCues(<AudioCue>[_cue('か', 0, 5000)]);
      c.debugUpdateCueForPosition(1000);
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      final Offset secondaryCenter = tester.getCenter(find.text('か').first);
      final SubtitleCharHit? hit = ht.hitTest(secondaryCenter);
      expect(hit, isNotNull);
      expect(hit!.sentence, 'か');
      expect(hit.graphemeIndex, 0);
    });

    testWidgets('单主字幕、无副字幕：结构退化为单字幕盒（无 Stack 包裹，历史几何不变)',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('A', 0, 5000)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, VideoSubtitleOverlay(controller: c));
      // 单层直接返回，overlay 直接子不是把主/副并列的 Stack（LayoutBuilder 在最外）。
      // 默认统一外观每字单层 Text（Niratan 软投影）。
      expect(find.text('A'), findsOneWidget);
    });
  });
}
