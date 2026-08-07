import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-915 守卫：
/// ① 尊重 .ass 模式**完全按作者字号**（mpv 平价基线；用户决策：尊重即尊重字号，
///   用户字号滑块不参与 ASS 字号——曾试做 sub-scale 倍率，按用户要求取消）。
/// ② respectAssStyle 关 = 纯字幕模式（asbplayer 语义）：\pos/\an/层/边距全不参与——主
///   字幕恒底部居中、同文本多层拷贝（KFX 特效层）去重只渲染一条、文本互异的竖排堆叠。
///   旧行为「样式不尊重、位置却尊重」把特效层渲染成同位叠印乱字（用户截图）。
const String _kAssHead = r'''
[Script Info]
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: D,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''';

List<AudioCue> _parse(String dialogues) =>
    AssParser.parseString(content: '$_kAssHead$dialogues\n', bookKey: 'sc');

Future<VideoPlayerController> _pump(
  WidgetTester tester,
  List<AudioCue> cues, {
  required bool respect,
  double fontSize = 36,
}) async {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  // 视频分辨率与测试面同比（800×600 vs 1280×720 皆 4:3? 否）：给 \pos 映射用；
  // 16:9 内容在 800×600 面上 letterbox，位置断言只看相对关系不钉像素。
  c.debugVideoWidthOverride = 1280;
  c.debugVideoHeightOverride = 720;
  c.setCues(cues);
  c.debugSetPositionForTesting(500);
  c.debugUpdateCueForPosition(500);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: VideoSubtitleOverlay(
        controller: c,
        respectAssStyle: respect,
        fontSize: fontSize,
      ),
    ),
  ));
  await tester.pump();
  return c;
}

Text _fill(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .firstWhere((Text t) => t.style?.foreground == null);

void main() {
  group('① 尊重 .ass = 尊重字号（完全按作者字号，滑块不参与）', () {
    testWidgets('ASS 字号按显示几何缩放，完全按作者字号（mpv 平价基线）', (WidgetTester tester) async {
      await _pump(
          tester, _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,あ'),
          respect: true);
      // 视频内容矩形高 = 800×(720/1280)=450 → 48×450/720 = 30（测试环境无真字体表，
      // cell 系数 1.0）。
      expect(_fill(tester, 'あ').style?.fontSize, closeTo(30, 0.01));
    });

    testWidgets('用户字号滑块（fontSize）不影响 ASS 字号（尊重即尊重字号）',
        (WidgetTester tester) async {
      await _pump(
          tester, _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,あ'),
          respect: true, fontSize: 60);
      // fontSize 60（滑块调大）不得放大 ASS 字幕：仍是作者字号换算的 30。
      expect(_fill(tester, 'あ').style?.fontSize, closeTo(30, 0.01));
      // 描边同理不受滑块影响：Outline=2 → 半径 2×450/720=1.25 → strokeWidth ×2 = 2.5。
      final Text stroke = tester
          .widgetList<Text>(find.text('あ'))
          .firstWhere((Text t) => t.style?.foreground != null);
      expect(stroke.style!.foreground!.strokeWidth, closeTo(2.5, 0.01));
    });
  });

  group('② respectAssStyle 关 = 纯字幕模式（asbplayer 语义）', () {
    testWidgets('同文本多层拷贝（KFX 特效层）去重：只渲染一条', (WidgetTester tester) async {
      await _pump(
          tester,
          _parse('Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,'
              r'{\pos(400,300)}重'
              '\nDialogue: 1,0:00:00.00,0:00:02.00,D,,0,0,0,,'
              r'{\pos(400,300)\1a&HFF&}重'),
          respect: false);
      // 纯字幕模式：同文本两层只渲染一条（respect 开时两层各 stroke+fill 同位叠画）。
      expect(find.text('重'), findsOneWidget);
    });

    testWidgets(r'\pos 顶部招牌 + 底部对白：位置语义归零，都落底部堆叠、不叠印',
        (WidgetTester tester) async {
      await _pump(
          tester,
          _parse('Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,'
              r'{\pos(200,50)}甲'
              '\nDialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,乙'),
          respect: false);
      final Rect a = tester.getRect(find.text('甲'));
      final Rect b = tester.getRect(find.text('乙'));
      // \pos(200,50)（顶部）被忽略：两条都在测试面下半部（600 高 → dy>300）。
      expect(a.top, greaterThan(300), reason: '纯字幕模式忽略 \\pos，恒底部');
      expect(b.top, greaterThan(300));
      // 竖排堆叠、不叠印（矩形不相交）。
      expect(a.intersect(b).isEmpty, isTrue, reason: '文本互异的同时字幕必须分行堆叠，不得同位叠印');
    });

    testWidgets('respect 开：\\pos 招牌仍按自带位置（本修复不回归 ON 路径）',
        (WidgetTester tester) async {
      await _pump(
          tester,
          _parse('Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,'
              r'{\pos(200,50)}甲'
              '\nDialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,乙'),
          respect: true);
      // respect 开时每字符渲染 stroke+fill 两层 Text（同位），取 first 即可。
      final Rect a = tester.getRect(find.text('甲').first);
      final Rect b = tester.getRect(find.text('乙').first);
      // \pos y=50/720 → 上半部；对白仍底部。
      expect(a.top, lessThan(300), reason: 'respect 开时 \\pos 顶部招牌在上半部');
      expect(b.top, greaterThan(300));
    });
  });
}
