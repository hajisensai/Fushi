import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-684 守卫（TODO-1341 续 / BUG-651 续）：视频多字幕**各遵自带位置**、消除降级。
///
/// 两处历史降级：
/// (1) 主字幕活动集里**同锚点不同 MarginV** 的 cue（OP/ED 标题 an8 MarginV=60 + 多行歌词
///     MarginV=150/240）被裹挟进一个 Column 挤在一起，丢掉各自 authored 高度。
/// (2) 副字幕**无条件**被拽到画面顶部，丢掉自带 pos / an（哪怕自带顶部歌词 / pos 招牌）。
///
/// 修复后：(1) 同锚点不同 MarginV 各成一组、按缩放后的 MarginV 各在其 authored 高度；
/// (2) 副字幕自带**非底部**位置（pos 或 an 顶部 / 中部）遵其自带位置，自带底部 / 无位置
///     （纯 SRT、an2 对白）仍置顶避让主字幕底部对白（asbplayer 式上下分栏、不撞位）。
const String _assOp = '''
[Script Info]
PlayResX: 1920
PlayResY: 1080
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, Alignment, MarginL, MarginR, MarginV
Style: Title,Arial,60,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,8,0,0,60
Style: RomajiTop,Arial,48,&H0000FFFF,&H00000000,&H00000000,0,0,0,0,8,0,0,150
Style: RomajiBot,Arial,48,&H0000FFFF,&H00000000,&H00000000,0,0,0,0,8,0,0,240
Style: Dialogue,Arial,54,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,2,0,0,40
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:20.00,Title,,0,0,0,,1
Dialogue: 0,0:00:01.00,0:00:06.00,RomajiTop,,0,0,0,,2
Dialogue: 0,0:00:01.00,0:00:06.00,RomajiBot,,0,0,0,,3
Dialogue: 0,0:00:02.00,0:00:05.00,Dialogue,,0,0,0,,4
''';

AudioCue _cue(String t, SubtitleVAlign? v, {int s = 0, int e = 8000}) =>
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = t
      ..markup = v == null
          ? null
          : SubtitleMarkup(
              plainText: t,
              spans: const <SubtitleSpan>[],
              anchor: SubtitleAnchor(v, SubtitleHAlign.center))
      ..startMs = s
      ..endMs = e
      ..audioFileIndex = 0;

Future<void> _pump(WidgetTester tester, VideoPlayerController c) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 450,
        child: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ),
  ));
  await tester.pump();
}

double _dy(WidgetTester tester, String label) =>
    tester.getTopLeft(find.text(label).first).dy;

void main() {
  group('BUG-684 主字幕同锚点不同 MarginV 各就其位（不再裹挟成一列）', () {
    testWidgets('OP 标题 + 两行歌词按 MarginV 竖直分离（不挤成一列）',
        (WidgetTester tester) async {
      final List<AudioCue> cues =
          AssParser.parseString(content: _assOp, bookKey: 'b');
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(cues);
      c.debugUpdateCueForPosition(3000);
      expect(c.activeCues.length, 4);
      await _pump(tester, c);
      for (final String ch in <String>['1', '2', '3', '4']) {
        expect(find.text(ch), findsWidgets, reason: 'cue "\$ch" 必须渲染（不丢弃）');
      }
      final double title = _dy(tester, '1'); // MarginV=60
      final double top = _dy(tester, '2'); // MarginV=150
      final double bot = _dy(tester, '3'); // MarginV=240
      final double dlg = _dy(tester, '4'); // 底部
      expect(top, greaterThan(title), reason: 'MarginV 更大的歌词行应在标题下方');
      expect(bot, greaterThan(top), reason: 'MarginV 最大的歌词行最低');
      expect(top - title, greaterThan(25),
          reason: 'MarginV 差应转成真实竖直间距，而非裹在一个 Column 里贴着排');
      expect(bot - top, greaterThan(25));
      expect(dlg, greaterThan(225), reason: 'an2 对白仍在下半屏');
    });

    testWidgets('底部对白自带小 MarginV 不把字幕拽到用户基线以下（单调抬升，无回归）',
        (WidgetTester tester) async {
      final AudioCue withMargin = AudioCue()
        ..bookKey = 'b'
        ..chapterHref = 'c'
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = 'A'
        ..markup = SubtitleMarkup(
          plainText: 'A',
          spans: const <SubtitleSpan>[],
          anchor: const SubtitleAnchor(
              SubtitleVAlign.bottom, SubtitleHAlign.center),
          cueStyle: const SubtitleCueStyle(marginV: 40),
          playResY: 1080,
        )
        ..startMs = 0
        ..endMs = 8000
        ..audioFileIndex = 0;
      final VideoPlayerController c1 = VideoPlayerController();
      addTearDown(c1.dispose);
      c1.setCues(<AudioCue>[withMargin]);
      c1.debugUpdateCueForPosition(1000);
      await _pump(tester, c1);
      final double withMv = _dy(tester, 'A');

      final VideoPlayerController c2 = VideoPlayerController();
      addTearDown(c2.dispose);
      c2.setCues(<AudioCue>[_cue('A', SubtitleVAlign.bottom)]);
      c2.debugUpdateCueForPosition(1000);
      await _pump(tester, c2);
      final double noMv = _dy(tester, 'A');
      expect((withMv - noMv).abs(), lessThan(1.0),
          reason: '小 MarginV 不得把底部对白降到用户基线以下');
    });
  });

  group('BUG-684 副字幕各遵自带位置（非底部遵其位，底部/无位置避让置顶）', () {
    testWidgets('副字幕自带底部锚点 → 仍置顶，不与主字幕底部对白撞位', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', SubtitleVAlign.bottom)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', SubtitleVAlign.bottom)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, c);
      expect(_dy(tester, '副'), lessThan(_dy(tester, '主')),
          reason: '自带底部的副字幕仍置顶避让，不撞主字幕底部对白');
    });

    testWidgets('副字幕纯 SRT（无 markup）→ 置顶（保 TODO-1312 语义）',
        (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', null)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', null)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, c);
      expect(_dy(tester, '副'), lessThan(_dy(tester, '主')));
    });

    testWidgets('副字幕自带**顶部**锚点 → 遵其位（在上半屏）', (WidgetTester tester) async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue('主', SubtitleVAlign.bottom)]);
      c.setSecondaryCues(<AudioCue>[_cue('副', SubtitleVAlign.top)]);
      c.debugUpdateCueForPosition(1000);
      await _pump(tester, c);
      expect(_dy(tester, '副'), lessThan(225), reason: '顶部副字幕在上半屏');
      expect(_dy(tester, '主'), greaterThan(225), reason: '底部主字幕在下半屏');
    });
  });
}
