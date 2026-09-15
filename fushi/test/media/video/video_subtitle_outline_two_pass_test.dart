// BUG-2541：尊重 .ass 时描边曾逐字 Stack(描边, 填充)——后一个字的描边画在前一个字的
// 填充之上，斜体 / 紧排时黑描边啃进前字的白填充，笔画看着变粗；重叠量随字号 / 亚像素
// 位置变，于是「字重随窗口大小变」。libass 先合成整行描边位图再叠整行填充位图。
// 另：缩放后描边宽曾夹 [0.5, 24]，小窗口里细描边被下限截断、相对字身越缩越粗。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

const String _kHead = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Bord2,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,-1,0,0,100,100,0,0,1,2,0,2,10,10,20,1
Style: Thin,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0.3,0,2,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

List<AudioCue> _parse(String dialogue) =>
    AssParser.parseString(content: '$_kHead$dialogue\n', bookKey: 'tp');

Future<void> _pump(WidgetTester tester, List<AudioCue> cues,
    {double height = 1080}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final VideoPlayerController c = VideoPlayerController()
    ..debugVideoWidthOverride = 1920
    ..debugVideoHeightOverride = 1080;
  addTearDown(c.dispose);
  c.setCues(cues);
  c.debugSetPositionForTesting(500);
  c.debugUpdateCueForPosition(500);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1920,
        height: height,
        child: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('带描边的行：所有描边层先于所有填充层（整行两遍，描边不压相邻字填充）',
      (WidgetTester tester) async {
    await _pump(
        tester, _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,Bord2,,0,0,0,,abc'));
    final List<Text> texts = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(VideoSubtitleOverlay),
            matching: find.byType(Text)))
        .where((Text t) => t.data != null && 'abc'.contains(t.data!))
        .toList();
    expect(texts, hasLength(6), reason: '3 字 × (描边 + 填充)');
    final List<bool> isStroke =
        texts.map((Text t) => t.style?.foreground != null).toList();
    expect(isStroke, <bool>[true, true, true, false, false, false],
        reason: '树序 = 绘制序：整行描边在下、整行填充在上');
    // 两遍几何同构：同一字的描边 / 填充矩形重合。
    final Rect strokeRect = tester.getRect(find
        .byWidgetPredicate((Widget w) =>
            w is Text && w.data == 'b' && w.style?.foreground != null)
        .first);
    final Rect fillRect = tester.getRect(find
        .byWidgetPredicate((Widget w) =>
            w is Text && w.data == 'b' && w.style?.foreground == null)
        .first);
    expect(fillRect, strokeRect);
  });

  testWidgets('小窗口里细描边照实缩放，不被 0.5 下限截断', (WidgetTester tester) async {
    // 显示区高 200 / PlayResY 1080 → Outline 0.3 → 0.0556 半径 → 居中 stroke 0.111。
    await _pump(
        tester, _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,Thin,,0,0,0,,あ'),
        height: 200);
    final Text stroke = tester
        .widgetList<Text>(find.text('あ'))
        .firstWhere((Text t) => t.style?.foreground != null);
    expect(stroke.style!.foreground!.strokeWidth,
        closeTo(0.3 * 200 / 1080 * 2, 0.005),
        reason: '旧 clamp(0.5, 24) 会把它抬成 1.0，相对字身粗一个量级');
  });
}
