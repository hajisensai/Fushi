// BUG-3608：纯字幕模式（「尊重字幕自带样式」关）下，同时间戳、用 \pos 显式排成上下两行
// 的 ASS 对白被上下颠倒。纯字幕模式把整层折进一个底部堆叠组、按活动集发现顺序（文件序）
// 入槽，slot0 贴底——文件序第一行（作者放在 y=900，靠上）反而画在最下面。修复后组内
// 行序按作者排版的竖直次序（\pos y / 锚点 + MarginV）排，同位置的仍按文件序（libass 碰撞
// 语义）不变。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

// 与反馈截图同结构：Default 底部样式，两条同起止时间的事件用 \pos 分别放在 y=900（上）
// 与 y=1020（下），文件序是「上面那行先写」。
const String _kPosPair = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:02:27.10,0:02:30.67,Default,,0,0,0,,{\pos(820,900)\c&H00ffff&}ああ 真っ赤な羽毛の
Dialogue: 0,0:02:27.10,0:02:30.67,Default,,0,0,0,,{\pos(940,1020)\c&H00ffff&}でっかい鳥だ。
''';

// 无 \pos 的同样式两行：位置相同，保持既有 libass 碰撞次序（先写的贴底）。
const String _kPlainPair = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,先写的羽
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,后写的鳥
''';

AudioCue _cue(String raw, {required int index}) {
  final SubtitleMarkup m = parseSubtitleMarkup(
    raw,
    playResX: 1920,
    playResY: 1080,
  );
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = index
    ..textFragmentId = '[data-cue-id="$index"]'
    ..text = m.plainText
    ..markup = m
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

Future<VideoPlayerController> _pumpPlain(
  WidgetTester tester,
  String ass,
  int atMs,
) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  addTearDown(c.dispose);
  c.setCues(AssParser.parseString(content: ass, bookKey: 'z'));
  c.debugUpdateCueForPosition(atMs);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1920,
          height: 1080,
          child: VideoSubtitleOverlay(controller: c, respectAssStyle: false),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  group('orderPlainCuesByAuthoredPosition', () {
    test('底部锚组：\\pos 更靠下的在前（slot0 贴底）', () {
      final AudioCue upper = _cue(r'{\pos(820,900)}上', index: 52);
      final AudioCue lower = _cue(r'{\pos(940,1020)}下', index: 53);
      expect(
        orderPlainCuesByAuthoredPosition(<AudioCue>[
          upper,
          lower,
        ], anchorBottom: true),
        <AudioCue>[lower, upper],
      );
    });

    test('顶部锚组（副字幕置顶）：更靠上的在前（slot0 贴顶）', () {
      final AudioCue upper = _cue(r'{\pos(820,900)}上', index: 1);
      final AudioCue lower = _cue(r'{\pos(940,1020)}下', index: 2);
      expect(
        orderPlainCuesByAuthoredPosition(<AudioCue>[
          lower,
          upper,
        ], anchorBottom: false),
        <AudioCue>[upper, lower],
      );
    });

    test('无显式位置的同锚点对白保持发现顺序（稳定，既有行为不变）', () {
      final AudioCue a = _cue('甲', index: 1);
      final AudioCue b = _cue('乙', index: 2);
      final List<AudioCue> input = <AudioCue>[a, b];
      expect(
        orderPlainCuesByAuthoredPosition(input, anchorBottom: true),
        <AudioCue>[a, b],
      );
      expect(
        orderPlainCuesByAuthoredPosition(input, anchorBottom: false),
        <AudioCue>[a, b],
      );
    });

    test('顶部 \\an8 的行排在底部对白之上', () {
      final AudioCue top = _cue(r'{\an8}顶', index: 1);
      final AudioCue bottom = _cue('底', index: 2);
      expect(
        orderPlainCuesByAuthoredPosition(<AudioCue>[
          top,
          bottom,
        ], anchorBottom: true),
        <AudioCue>[bottom, top],
      );
    });
  });

  testWidgets('纯字幕模式：\\pos 排成上下的同时间戳两行保持作者的上下次序', (WidgetTester tester) async {
    await _pumpPlain(tester, _kPosPair, 148000);
    final double upperTop = tester.getRect(find.text('羽').first).top;
    final double lowerTop = tester.getRect(find.text('鳥').first).top;
    expect(
      upperTop,
      lessThan(lowerTop),
      reason:
          '作者把「ああ 真っ赤な羽毛の」放在 y=900（上）、「でっかい鳥だ。」'
          '放在 y=1020（下），纯字幕模式不得颠倒',
    );
  });

  testWidgets('纯字幕模式：无 \\pos 的同时间戳两行仍按 libass 碰撞次序（先写的贴底）', (
    WidgetTester tester,
  ) async {
    await _pumpPlain(tester, _kPlainPair, 2000);
    final double firstTop = tester.getRect(find.text('羽').first).top;
    final double secondTop = tester.getRect(find.text('鳥').first).top;
    expect(firstTop, greaterThan(secondTop));
  });
}
