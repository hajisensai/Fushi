import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-738 追加（「样式最好完整呈现」）：ASS `MarginL`/`MarginR` 水平边距 + `\N` 硬换行。
///
/// 此前 Style 行只捕获 MarginV、Dialogue 行级 Margin 覆盖列整体被忽略、渲染端只有竖直
/// padding——字幕组用行级 MarginL=900 把对白横移到说话人一侧（真实文件
/// Shunkashuutou…ToonsHub.ass）、用 an7+样式 MarginL 放左上招牌，全被错误渲染成居中 /
/// 贴屏幕左缘；`\N` 被压成空格，作者排好的两行变一长行。
///
/// 语义（libass）：水平排版盒 = `[MarginL, PlayResX-MarginR]`，居中对齐在盒内居中（不对称
/// 边距 → 中心偏移 (L-R)/2）、左对齐贴盒左缘；`\N` 处硬断行。plainText 断点处保持空格
/// （查词 / 制卡 / DB 逐字节不变），仅渲染层按 lineBreakGraphemes 分行。
String _ass({required String eventsBody}) => '''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Mid,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,30,1
Style: Sign,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,7,40,40,25,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
$eventsBody
''';

Future<void> _mount(WidgetTester tester, VideoPlayerController c) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1920,
        height: 1080,
        child: VideoSubtitleOverlay(
          controller: c,
          respectAssStyle: true,
          onCharTap: (_, __, ___) {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

Rect _fillRect(WidgetTester tester, String ch) {
  final Finder fill = find.byWidgetPredicate(
      (Widget w) => w is Text && w.data == ch && w.style?.foreground == null);
  return tester.getRect(fill.first);
}

void main() {
  test('解析：Style 行 MarginL/R 捕获 + Dialogue 行级覆盖 clone（不改共享样式）', () {
    final List<AudioCue> cues = AssParser.parseString(
      bookKey: 'b',
      content: _ass(
          eventsBody: 'Dialogue: 0,0:00:00.00,0:00:02.00,Mid,,0,0,0,,普通\n'
              'Dialogue: 0,0:00:03.00,0:00:05.00,Mid,,900,0,0,,横移\n'
              'Dialogue: 0,0:00:06.00,0:00:08.00,Sign,,0,0,0,,招牌'),
    );
    expect(cues.length, 3);
    final SubtitleCueStyle plain = cues[0].markup!.cueStyle!;
    final SubtitleCueStyle shifted = cues[1].markup!.cueStyle!;
    final SubtitleCueStyle sign = cues[2].markup!.cueStyle!;
    // 样式表边距。
    expect(plain.marginL, 10);
    expect(plain.marginR, 10);
    expect(sign.marginL, 40);
    // 行级覆盖只改本条（>0 覆盖，0 沿用），且共享样式实例未被原地改。
    expect(shifted.marginL, 900);
    expect(shifted.marginR, 10, reason: '行级 0 沿用样式默认');
    expect(shifted.marginV, 30);
    expect(plain.marginL, 10, reason: '共享样式实例不得被行级覆盖污染');
    // PlayResX 透传。
    expect(cues[0].markup!.playResX, 1920);
  });

  testWidgets('渲染：行级 MarginL=900 把居中对白横移到 (L-R)/2',
      (WidgetTester tester) async {
    final List<AudioCue> cues = AssParser.parseString(
      bookKey: 'b',
      content:
          _ass(eventsBody: 'Dialogue: 0,0:00:00.00,0:00:05.00,Mid,,900,0,0,,右'),
    );
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(cues);
    await _mount(tester, c);
    c.debugUpdateCueForPosition(1000);
    await tester.pump();

    // 排版盒 [900, 1910]（MarginR 沿用样式 10），文本在盒内居中 → 中心 = (900+1910)/2
    // = 1405（容器 1920 = PlayResX，缩放 1.0）。
    final Rect r = _fillRect(tester, '右');
    expect(r.center.dx, closeTo(1405, 4),
        reason: '行级 MarginL=900 的对白应横移到说话人一侧，而非屏幕居中');
  });

  testWidgets('渲染：an7 招牌样式 MarginL=40 → 左缘偏移，不贴屏幕边',
      (WidgetTester tester) async {
    final List<AudioCue> cues = AssParser.parseString(
      bookKey: 'b',
      content:
          _ass(eventsBody: 'Dialogue: 0,0:00:00.00,0:00:05.00,Sign,,0,0,0,,牌'),
    );
    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(cues);
    await _mount(tester, c);
    c.debugUpdateCueForPosition(1000);
    await tester.pump();

    // 左对齐：文本起点 = MarginL(40) + 字幕盒内衬 12 = 52。
    final Rect r = _fillRect(tester, '牌');
    expect(r.left, closeTo(52, 4), reason: 'an7 + 样式 MarginL=40 的招牌不得贴屏幕左缘');
  });

  testWidgets(r'渲染：\N 硬换行分两行；plainText 保持空格（查词零变化）',
      (WidgetTester tester) async {
    final List<AudioCue> cues = AssParser.parseString(
      bookKey: 'b',
      content: _ass(
          eventsBody: r'Dialogue: 0,0:00:00.00,0:00:05.00,Mid,,0,0,0,,上行\N下行'),
    );
    expect(cues.single.text, '上行 下行', reason: 'plainText 断点处保持空格');
    expect(cues.single.markup!.lineBreakGraphemes, <int>[2]);

    final VideoPlayerController c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues(cues);
    await _mount(tester, c);
    c.debugUpdateCueForPosition(1000);
    await tester.pump();

    final Rect up = _fillRect(tester, '上');
    final Rect down = _fillRect(tester, '下');
    expect(down.top, greaterThanOrEqualTo(up.bottom - 1),
        reason: r'\N 后的文字应换到下一行（libass 硬换行），不再一长行');
    expect((up.left - down.left).abs(), lessThan(1),
        reason: '两行各自居中（等宽 → 左缘对齐）');
  });
}
