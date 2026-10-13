import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-3313：ASS 字幕跳转后位置 / 时间错乱。
///
/// seek 刚发出时 player 吐的还是跳转前的旧位置。活动集（哪几条在屏）早已按跳转目标
/// 算好，但 overlay 的 `\move` 定位与 `\fad` / `\t` / `\k` 时间曾经读的是那个旧位置——
/// 新句子按旧时间插值。这里钉住「同一帧里活动集与动画读同一个字幕时钟」。
const String _kAssHead = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: K,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

List<AudioCue> _parse(String events) =>
    AssParser.parseString(content: '$_kAssHead$events\n', bookKey: 'seek');

AudioCue _cue(int i, int startMs, int endMs) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = startMs
  ..endMs = endMs;

Text _fill(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .firstWhere((Text t) => t.style?.foreground == null);

void main() {
  testWidgets(r'暂停态 seek 进带 \t 的句子：动画按跳转目标插值，不按滞后旧位置', (
    WidgetTester tester,
  ) async {
    final List<AudioCue> cues = _parse(
      'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,い\n'
      r'Dialogue: 0,0:00:10.00,0:00:12.00,K,,0,0,0,,{\t(0,1000,\1a&HFF&)}あ',
    );
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(cues);
    c.debugSetIsPlayingForTesting(false);
    c.debugSetPositionForTesting(1500);
    c.debugUpdateCueForPosition(1500);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('い'), findsWidgets);

    // 跳到 10.2s；player 仍吐旧位置 1500（seek 未落地 / 暂停态不推进）。
    await c.seekMs(10200);
    c.debugUpdateCueForPosition(1500);
    await tester.pump();

    expect(find.text('い'), findsNothing, reason: '活动集已按目标换成新句');
    // cue 内 200ms → \t(0,1000) 进度 0.2 → alpha 1 → 0 的 0.8 处。修复前按旧位置
    // 1500 算 elapsed=-8500，动画停在起点（alpha 1.0）。
    expect(_fill(tester, 'あ').style!.color!.a, closeTo(0.8, 0.05));
  });

  group('字幕时钟 subtitleClockMs', () {
    test('普通 seek 暂停在途：时钟停在目标，ASS 动画与活动集同一个时间点', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 1000, 2000), _cue(1, 5000, 6000)]);
      c.debugSetIsPlayingForTesting(false);
      c.debugSetPositionForTesting(1500);
      c.debugUpdateCueForPosition(1500);

      await c.seekMs(5500);
      c.debugUpdateCueForPosition(1500);
      final AudioCue line1 = c.activeCues.single;
      expect(line1.text, 'line1');
      expect(c.subtitleClockMs, 5500);
      expect(c.effectivePositionMsForCue(line1), 5500);
      expect(c.effectiveSubtitleClockMs, 5500);
    });

    test('落地后时钟回到真实位置（不把动画钉在跳转目标）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 1000, 2000), _cue(1, 5000, 6000)]);
      c.debugSetIsPlayingForTesting(true);
      c.debugSetPositionForTesting(1500);
      c.debugUpdateCueForPosition(1500);

      await c.seekMs(5500);
      expect(c.subtitleClockMs, 5500, reason: '真实位置还是旧值');
      c.debugSetPositionForTesting(5520);
      expect(c.subtitleClockMs, 5520, reason: '已落地：跟真实位置逐帧走');
      c.debugUpdateCueForPosition(5520);
      c.debugSetPositionForTesting(5800);
      expect(c.subtitleClockMs, 5800);
    });

    test('图形字幕遮蔽层用的 effectivePositionMs 仍是真实位置（位图由 libmpv 按真实帧画）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 1000, 2000), _cue(1, 5000, 6000)]);
      c.debugSetIsPlayingForTesting(false);
      c.debugSetPositionForTesting(1500);
      await c.seekMs(5500);
      expect(c.effectivePositionMs, 1500);
      expect(c.subtitleClockMs, 5500);
    });

    test('skipToCue 在途：时钟取落点，进入引导窗口后跟真实位置', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 1000, 2000),
        _cue(1, 5000, 6000),
      ];
      c.setCues(cues);
      c.debugSetIsPlayingForTesting(true);
      c.debugSetPositionForTesting(1500);
      c.debugUpdateCueForPosition(1500);

      await c.skipToCue(c.cues[1]);
      final int landing = VideoPlayerController.cueSeekTargetMs(
        cueStartMs: 5000,
        delayMs: 0,
        preRollMs: VideoPlayerController.kCueSeekPreRollMs,
        prevCueStartMs: 1000,
      );
      expect(c.subtitleClockMs, landing, reason: '旧位置 1500 在目标句窗口外');
      c.debugSetPositionForTesting(4900);
      expect(c.subtitleClockMs, 4900, reason: '已进引导窗口：跟真实位置');
    });
  });

  group('普通 seek 往回跳：滞后旧位置不被误判落地', () {
    test('播放态往回跳远：旧位置大于目标也不把上一句闪回来', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 1000, 2000), _cue(1, 8000, 10000)]);
      c.debugSetIsPlayingForTesting(true);
      c.debugSetPositionForTesting(9000);
      c.debugUpdateCueForPosition(9000);
      expect(c.currentCue!.text, 'line1');

      await c.seekMs(1500);
      expect(c.currentCue!.text, 'line0');
      // 修复前单向判据 9125 ≥ 1500 − 250 → 误判落地 → 回到 line1。
      c.debugSetPositionForTesting(9125);
      c.debugUpdateCueForPosition(9125);
      expect(c.currentCue!.text, 'line0');
      expect(c.subtitleClockMs, 1500);

      c.debugSetPositionForTesting(1520);
      c.debugUpdateCueForPosition(1520);
      expect(c.currentCue!.text, 'line0');
      c.debugSetPositionForTesting(9000);
      c.debugUpdateCueForPosition(9000);
      expect(c.currentCue!.text, 'line1', reason: '落地后放行真实位置');
    });

    test('播放态短距离往回跳：落地窗口内的旧位置也不算落地', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[_cue(0, 1000, 2000), _cue(1, 2500, 3500)]);
      c.debugSetIsPlayingForTesting(true);
      c.debugSetPositionForTesting(3000);
      c.debugUpdateCueForPosition(3000);
      expect(c.currentCue!.text, 'line1');

      await c.seekMs(1500);
      c.debugSetPositionForTesting(3125);
      c.debugUpdateCueForPosition(3125);
      expect(c.currentCue!.text, 'line0');
    });

    test('plainSeekLanded 纯判据', () {
      bool landed(int raw, int target, int? from) =>
          VideoPlayerController.plainSeekLanded(
            rawPosMs: raw,
            targetMs: target,
            fromMs: from,
          );
      // 往前跳：旧位置在目标之前，不算；到达容差内算。
      expect(landed(1500, 5500, 1500), isFalse);
      expect(landed(5300, 5500, 1500), isTrue);
      expect(landed(5700, 5500, 1500), isTrue);
      // 往回跳：旧位置 ≥ 发出时位置，不算；真落点算。
      expect(landed(9125, 1500, 9000), isFalse);
      expect(landed(3125, 1500, 3000), isFalse);
      expect(landed(1520, 1500, 3000), isTrue);
      // 极短往回跳（≤ 容差）不区分新旧值，按窗口判。
      expect(landed(1700, 1500, 1650), isTrue);
      // 发出时位置未知（无 player）：只按窗口。
      expect(landed(1600, 1500, null), isTrue);
      expect(landed(9000, 1500, null), isFalse);
    });
  });
}
