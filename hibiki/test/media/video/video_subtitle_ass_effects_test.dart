import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// ASS 高级特效守卫：`\t` 通用动画（颜色/透明度插值）、卡拉 OK `\k`/`\kf` 逐字变色、
/// `\fsp` 字间距、`\frx` 3D 旋转、样式表 Angle/ScaleX/Y/Spacing/SecondaryColour。
const String _kAssHead = r'''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: K,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
Style: Rot,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,30,1,2,0,2,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

List<AudioCue> _parse(String dialogue) =>
    AssParser.parseString(content: '$_kAssHead$dialogue\n', bookKey: 'fx');

Future<VideoPlayerController> _pump(
  WidgetTester tester,
  List<AudioCue> cues,
  int posMs,
) async {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(cues);
  // widget 测试无真实 Player：注入位置让 effectivePositionMs（\t/卡拉 OK 时基）生效。
  c.debugSetPositionForTesting(posMs);
  c.debugUpdateCueForPosition(posMs);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
    ),
  ));
  await tester.pump();
  return c;
}

Text _fill(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .firstWhere((Text t) => t.style?.foreground == null);

void main() {
  test(r'parser: \t transitions / \fsp / karaoke / style extras captured', () {
    final List<AudioCue> cues = _parse(
        r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\fsp5\t(0,1000,2,\c&HFF0000&\1a&HFF&)}あ');
    final SubtitleMarkup m = cues.single.markup!;
    expect(m.transitions, hasLength(1));
    expect(m.transitions.single.t1Ms, 0);
    expect(m.transitions.single.t2Ms, 1000);
    expect(m.transitions.single.accel, 2.0);
    expect(m.transitions.single.colorToArgb, 0xFF0000FF); // BGR FF0000 = 蓝
    expect(m.transitions.single.alphaTo, closeTo(0.0, 0.001));
    expect(m.spans.single.letterSpacingPx, 5);
    expect(m.cueStyle!.secondaryColorArgb, 0xFFFF0000); // &H0000FF& BGR = 红
    expect(m.cueStyle!.spacingPx, 0);
  });

  testWidgets(r'\t alpha animation interpolates over its window',
      (WidgetTester tester) async {
    final List<AudioCue> cues = _parse(
        r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\t(0,1000,\1a&HFF&)}あ');
    final VideoPlayerController c = await _pump(tester, cues, 500);
    // t=500 → p=0.5 → alpha 从 1 → 0 的中点。
    expect(_fill(tester, 'あ').style!.color!.a, closeTo(0.5, 0.05));
    // t=1500（窗口后）→ 全透明。
    c.debugSetPositionForTesting(1500);
    c.debugUpdateCueForPosition(1500);
    await tester.pump();
    expect(_fill(tester, 'あ').style!.color!.a, closeTo(0.0, 0.01));
  });

  testWidgets(r'\t colour animation reaches target',
      (WidgetTester tester) async {
    final List<AudioCue> cues = _parse(
        r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\c&H0000FF&\t(0,1000,\c&HFF0000&)}あ');
    final VideoPlayerController c = await _pump(tester, cues, 0);
    // 起点红（BGR 0000FF）。
    expect(_fill(tester, 'あ').style!.color!.toARGB32(), 0xFFFF0000);
    c.debugSetPositionForTesting(1200);
    c.debugUpdateCueForPosition(1200);
    await tester.pump();
    // 窗口结束 → 蓝（BGR FF0000）。
    expect(_fill(tester, 'あ').style!.color!.toARGB32(), 0xFF0000FF);
  });

  testWidgets(r'\k karaoke: syllable lights up at its start time',
      (WidgetTester tester) async {
    final List<AudioCue> cues =
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\k50}あ{\k50}い');
    final VideoPlayerController c = await _pump(tester, cues, 100);
    // t=100ms：音节1（0-500ms）已点亮=主色白；音节2（500ms 起）未到=副色红。
    expect(_fill(tester, 'あ').style!.color!.toARGB32(), 0xFFFFFFFF);
    expect(_fill(tester, 'い').style!.color!.toARGB32(), 0xFFFF0000);
    c.debugSetPositionForTesting(600);
    c.debugUpdateCueForPosition(600);
    await tester.pump();
    expect(_fill(tester, 'い').style!.color!.toARGB32(), 0xFFFFFFFF);
  });

  testWidgets(r'\kf karaoke: gradual sweep approximated as colour lerp',
      (WidgetTester tester) async {
    final List<AudioCue> cues =
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\kf100}あ');
    await _pump(tester, cues, 500);
    // 音节窗口 0-1000ms 中点：红(副)→白(主) 的中间色。
    final Color mid = _fill(tester, 'あ').style!.color!;
    expect(mid.r, closeTo(1.0, 0.05));
    expect(mid.g, greaterThan(0.3));
    expect(mid.g, lessThan(0.7));
  });

  testWidgets(r'\fsp letter spacing scales with PlayRes',
      (WidgetTester tester) async {
    final List<AudioCue> cues =
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\fsp10}あ');
    await _pump(tester, cues, 100);
    final double? ls = _fill(tester, 'あ').style!.letterSpacing;
    // 600(测试视口高)/1080 × 10 ≈ 5.56；只断言按比例缩放后为正且 < 10。
    expect(ls, isNotNull);
    expect(ls!, greaterThan(0));
    expect(ls, lessThan(10));
  });

  testWidgets(r'\frx 3D rotation wraps box in perspective Transform',
      (WidgetTester tester) async {
    final List<AudioCue> cues =
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\frx45}あ');
    await _pump(tester, cues, 100);
    final Iterable<Transform> transforms =
        tester.widgetList<Transform>(find.descendant(
      of: find.byType(VideoSubtitleOverlay),
      matching: find.byType(Transform),
    ));
    expect(
      transforms.any((Transform t) => t.transform.storage[11] != 0),
      isTrue,
      reason: r'\frx 必须产生带透视项的 3D 矩阵',
    );
  });

  testWidgets('style-table Angle rotates without inline tags',
      (WidgetTester tester) async {
    final List<AudioCue> cues =
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,Rot,,0,0,0,,あ');
    await _pump(tester, cues, 100);
    final Iterable<Transform> transforms =
        tester.widgetList<Transform>(find.descendant(
      of: find.byType(VideoSubtitleOverlay),
      matching: find.byType(Transform),
    ));
    expect(transforms, isNotEmpty, reason: '样式表 Angle=30 必须产生旋转 Transform');
  });
}
