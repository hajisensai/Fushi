// BUG-2539：ASS `Layer` 曾只用作分组键后缀、不参与绘制 z 序——各组按活跃集发现顺序
// （cue 文件序）进 Stack，谁靠后谁在上。招牌（Layer 0 手写字）排在对白（Layer 1）之后
// 就盖住对白；libass 是先按 Layer 升序、同层再按事件序。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

const String _kHead = r'''
[Script Info]
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
Style: Sign,Arial,40,&H00000000,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 1,0:00:01.00,0:00:04.00,Default,,0,0,0,,That is why.
Dialogue: 0,0:00:01.00,0:00:04.00,Sign,,0,0,0,,{\an7\pos(100,600)}Hoh
''';

AudioCue _cue(String text, {required int layer, required int index}) {
  final SubtitleMarkup m = parseSubtitleMarkup(text,
      playResX: 1280, playResY: 720, layer: layer);
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

void main() {
  test('sortCueGroupsForPaint：Layer 升序、同层按事件序、稳定', () {
    final AudioCue sign = _cue(r'{\pos(1,1)}S', layer: 0, index: 5);
    final AudioCue dlg = _cue('D', layer: 1, index: 2);
    final AudioCue fxA = _cue(r'{\pos(2,2)}A', layer: 1, index: 7);
    final AudioCue fxB = _cue(r'{\pos(3,3)}B', layer: 1, index: 3);
    final List<(String, List<AudioCue>)> sorted = sortCueGroupsForPaint(
      <(String, List<AudioCue>)>[
        ('a', <AudioCue>[fxA]),
        ('d', <AudioCue>[dlg]),
        ('s', <AudioCue>[sign]),
        ('b', <AudioCue>[fxB]),
      ],
    );
    expect(sorted.map((g) => g.$1).toList(), <String>['s', 'd', 'b', 'a'],
        reason: 'Layer 0 最底；Layer 1 内按 sentenceIndex 2 < 3 < 7');
    // 单组原样返回（不新建列表）。
    final List<(String, List<AudioCue>)> one = <(String, List<AudioCue>)>[
      ('x', <AudioCue>[dlg]),
    ];
    expect(identical(sortCueGroupsForPaint(one), one), isTrue);
  });

  testWidgets('Layer 0 招牌在文件里排在 Layer 1 对白之后，仍画在对白之下',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final VideoPlayerController c = VideoPlayerController()
      ..debugVideoWidthOverride = 1280
      ..debugVideoHeightOverride = 720;
    addTearDown(c.dispose);
    c.setCues(AssParser.parseString(content: _kHead, bookKey: 'z'));
    c.debugUpdateCueForPosition(2000);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 720,
          child: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
        ),
      ),
    ));
    await tester.pump();

    // 组 Stack 的 Positioned.fill 按分组键挂 ValueKey<String>；列表序 = 绘制序。
    final List<String> keys = tester
        .widgetList<Positioned>(find.descendant(
          of: find.byType(VideoSubtitleOverlay),
          matching: find.byWidgetPredicate(
              (Widget w) => w is Positioned && w.key is ValueKey<String>),
        ))
        .map((Positioned p) => (p.key! as ValueKey<String>).value)
        .toList();
    expect(keys, hasLength(2));
    final int signIdx = keys.indexWhere((String k) => k.startsWith('m|p:'));
    final int dlgIdx = keys.indexWhere((String k) => k.contains(':L1'));
    expect(signIdx, greaterThanOrEqualTo(0));
    expect(dlgIdx, greaterThanOrEqualTo(0));
    expect(signIdx, lessThan(dlgIdx),
        reason: 'Layer 0 招牌先画（在下），Layer 1 对白后画（在上）');
  });
}
