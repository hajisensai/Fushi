import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-897 描边宽守卫：ASS `Outline`/`\bord` 是**向外扩的半径**（libass
/// `FT_Glyph_StrokeBorder`），Flutter 居中 stroke 可见只剩一半——渲染必须 ×2；
/// `Outline:0` 明示无描边时不得被 clamp 下限画出 0.5px 细边（mpv 完全不画）。
const String _kAssHead = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Bord2,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
Style: Bord0,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

List<AudioCue> _parse(String dialogue) =>
    AssParser.parseString(content: '$_kAssHead$dialogue\n', bookKey: 'bord');

Future<void> _pump(WidgetTester tester, List<AudioCue> cues) async {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(cues);
  c.debugSetPositionForTesting(500);
  c.debugUpdateCueForPosition(500);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
    ),
  ));
  await tester.pump();
}

Iterable<Text> _strokeTexts(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .where((Text t) => t.style?.foreground != null);

void main() {
  test('assOutlineStrokeWidth：半径 ×2 成居中 strokeWidth；<=0 无描边', () {
    expect(assOutlineStrokeWidth(3), 6);
    expect(assOutlineStrokeWidth(0.5), 1);
    expect(assOutlineStrokeWidth(0), 0);
    expect(assOutlineStrokeWidth(-1), 0);
  });

  testWidgets('Outline=2：stroke 层 strokeWidth = 2×(2×显示高/PlayResY)（半径×2）',
      (WidgetTester tester) async {
    await _pump(
        tester, _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,Bord2,,0,0,0,,あ'));
    final Iterable<Text> strokes = _strokeTexts(tester, 'あ');
    expect(strokes, isNotEmpty, reason: 'Outline=2 必须有描边层');
    // 测试面 600 高、无视频分辨率 → assFontScale = 600/1080；半径 = 2×600/1080，
    // 可见宽须与 mpv 同 = 半径 → 居中 strokeWidth = 半径×2。
    const double expected = (2 * 600 / 1080) * 2;
    expect(
        strokes.first.style!.foreground!.strokeWidth, closeTo(expected, 0.01));
  });

  testWidgets('Outline=0：不画描边层（不被 clamp 下限强制成 0.5px 细边）',
      (WidgetTester tester) async {
    await _pump(
        tester, _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,Bord0,,0,0,0,,あ'));
    expect(_strokeTexts(tester, 'あ'), isEmpty,
        reason: 'Outline:0 明示无描边，mpv/libass 完全不画');
  });
}
