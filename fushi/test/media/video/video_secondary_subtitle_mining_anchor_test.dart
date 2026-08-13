import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-1592 守卫：**主字幕关掉、只开副字幕时也要能制卡**。
///
/// 病根链（用户报「制卡黑屏」，卡片图片是一整块纯黑）：
///  1. 字幕命中项只回传文本（sentence / grapheme / rect），**不带所属 cue**；
///  2. 页面侧只好用 [resolveVideoLookupAnchorCue] 去**主字幕流**按播放位置猜锚点 cue；
///  3. 主字幕关闭时主流恒空 → 锚点恒 null → `_resolveVideoMiningRange` 返回 `0..0`；
///  4. 区间非正 → 动图不抽、封面阶梯落到「字幕起点单帧」，而起点 = 0ms → ffmpeg 抽视频
///     **第 0 秒**的帧 = 片头黑帧。尺寸正确、像素全黑，Anki 侧看就是「制卡黑屏」；句子
///     音频同样因区间为 0 而空。
///
/// 修法是消除「猜锚点」这一整类特殊情况，而不是加「若副字幕则……」分支：命中项本来就
/// 诞生在按 cue 渲染的循环里，把 cue 一并带出 → **点哪条锚哪条**，主 / 副 / 重叠同一
/// 口径（顺带修主副同开时点副字幕却错锚到主字幕那句的旧错）。
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
  group('BUG-1592 命中项带出所属 cue（制卡锚点）', () {
    testWidgets('只开副字幕（主字幕流为空）：点副字幕字符 → 锚点 cue 是那条副字幕、时间窗非零',
        (WidgetTester tester) async {
      AudioCue? anchor;
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      // 用户把主字幕关掉：主流空，只有副字幕。
      c.setCues(const <AudioCue>[]);
      c.setSecondaryCues(<AudioCue>[_cue('いう', 12000, 15000)]);
      c.debugUpdateCueForPosition(13000);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect _, AudioCue cue) => anchor = cue,
        ),
      );

      await tester.tapAt(tester.getCenter(find.text('う').first));
      await tester.pump();

      expect(anchor, isNotNull, reason: '点副字幕必须回传锚点 cue，否则制卡无区间可用');
      expect(anchor!.text, 'いう');
      // 这两条就是黑图根因的正反面：区间必须是这条字幕的真实时间窗，不能塌成 0。
      expect(anchor!.startMs, 12000);
      expect(anchor!.endMs, 15000);
    });

    testWidgets('主副同开：点副字幕那条 → 锚点是副字幕 cue（不错锚到主字幕）',
        (WidgetTester tester) async {
      AudioCue? anchor;
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 5000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 1000, 4000)]);
      c.debugUpdateCueForPosition(2000);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect _, AudioCue cue) => anchor = cue,
        ),
      );

      await tester.tapAt(tester.getCenter(find.text('副').first));
      await tester.pump();

      expect(anchor?.text, '副');
      expect(anchor?.startMs, 1000);
      expect(anchor?.endMs, 4000);
    });

    testWidgets('主副同开：点主字幕那条 → 锚点仍是主字幕 cue（不串层）', (WidgetTester tester) async {
      AudioCue? anchor;
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 5000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 1000, 4000)]);
      c.debugUpdateCueForPosition(2000);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect _, AudioCue cue) => anchor = cue,
        ),
      );

      await tester.tapAt(tester.getCenter(find.text('主').first));
      await tester.pump();

      expect(anchor?.text, '主');
      expect(anchor?.startMs, 0);
      expect(anchor?.endMs, 5000);
    });

    // 主字幕**同时在放**（`currentCue` 非空）才能证明命中项用的是「被点那条」而不是
    // 「主字幕当前那条」——只开副字幕的用例里 `currentCue` 恒 null，两种实现都能过。
    testWidgets('hitTester 反查（浮层 barrier 换词路径）带出被点那条 cue（主字幕同时在放）',
        (WidgetTester tester) async {
      final VideoSubtitleHitTester hitTester = VideoSubtitleHitTester();
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 7000, 9000)]);
      c.setSecondaryCues(<AudioCue>[_cue('か', 7000, 9000)]);
      c.debugUpdateCueForPosition(8000);
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, hitTester: hitTester),
      );

      final SubtitleCharHit? hit =
          hitTester.hitTest(tester.getCenter(find.text('か').first));
      expect(hit, isNotNull);
      expect(hit!.cue.text, 'か');
      expect(hit.cue.startMs, 7000);
      expect(hit.cue.endMs, 9000);
    });

    // 同上：主字幕在放时锚点仍须是光标停留那条（此处光标锚点默认落主字幕层首字符）。
    testWidgets('选词光标（手柄查词）命中带出光标所在那条 cue', (WidgetTester tester) async {
      final VideoSubtitleHitTester hitTester = VideoSubtitleHitTester();
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(const <AudioCue>[]);
      c.setSecondaryCues(<AudioCue>[_cue('きく', 3000, 6000)]);
      c.debugUpdateCueForPosition(4000);
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, hitTester: hitTester),
      );

      final int anchorEntry = hitTester.caretAnchorEntry();
      expect(anchorEntry, greaterThanOrEqualTo(0));
      final SubtitleCharHit? hit = hitTester.caretHitAt(anchorEntry);
      expect(hit, isNotNull);
      expect(hit!.cue.startMs, 3000);
      expect(hit.cue.endMs, 6000);
    });
  });

  group('BUG-1592 有效 cue 流（无命中项的制卡兜底 + 上下 N 句上下文）', () {
    test('miningCues：主流非空取主流；主流为空（只开副字幕）落副流', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', 0, 1000)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', 0, 1000)]);
      expect(c.miningCues.single.text, '主');

      c.setCues(const <AudioCue>[]);
      expect(c.miningCues.single.text, '副',
          reason: '主字幕关闭时制卡必须落到副字幕流，否则锚点恒 null → 区间 0..0 → 封面抽片头黑帧');
    });

    test('cueStreamOwning：按身份定位锚点所属流（上下 N 句上下文取邻句用）', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final AudioCue main0 = _cue('主', 0, 1000);
      final AudioCue sec0 = _cue('副0', 0, 1000);
      final AudioCue sec1 = _cue('副1', 1000, 2000);
      c.setCues(<AudioCue>[main0]);
      c.setSecondaryCues(<AudioCue>[sec0, sec1]);

      expect(identical(c.cueStreamOwning(main0), c.cues), isTrue);
      // 副字幕锚点必须解析到副流；解析成主流会让 indexOf 恒 -1 → 上下 N 句静默失效。
      expect(c.cueStreamOwning(sec1).map((AudioCue e) => e.text).toList(),
          <String>['副0', '副1']);
      // 两条流都不含（列表合成 cue / 换集后的陈旧 cue）→ 回落有效流，不返回空。
      expect(c.cueStreamOwning(_cue('孤儿', 0, 1)).isNotEmpty, isTrue);
    });

    test('只开副字幕时按位置解析制卡 cue：非 null，且区间就是那条副字幕', () {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(const <AudioCue>[]);
      c.setSecondaryCues(<AudioCue>[
        _cue('一句', 10000, 12000),
        _cue('二句', 12000, 14000),
      ]);

      final AudioCue? resolved = resolveMiningCueForPosition(
        cues: c.miningCues,
        positionMs: 13000,
        delayMs: 0,
      );
      expect(resolved, isNotNull,
          reason: '没有查词命中项的入口（直接制卡）也必须解析得到区间，否则回退第 0 秒黑帧');
      expect(resolved!.startMs, 12000);
      expect(resolved.endMs, 14000);
    });
  });
}
