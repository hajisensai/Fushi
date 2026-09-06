import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-2157 守卫：纯字幕模式（`respectAssStyle` 关）下**行内 `\fs` 不得覆盖用户字号**。
///
/// 开关文案明示「关闭则一律使用你的外观设置」，且兄弟属性（`\c`/`\1c` 主色 BUG-1285、
/// `\3c` 描边色、`\1a` 填充透明度、`\fsp` 字距、`\shad` 阴影、`\fscx/\fscy` 缩放）早已
/// 与 `respect` 同源门控。唯独行内 `\fs` 按「历史裸像素」放行：`span.fontSizePx` 被
/// 直接当逻辑像素字号写进 `TextStyle`，把用户字号滑块整条架空。fansub 的 ASS 对白
/// 普遍在每行套 `{\fs...}`，用户表现就是「尊重 ass 关了也是改不了大小」。
///
/// 注意 `\fs` 的裸值是 **PlayRes 空间**的数字（这里 90 对 PlayResY=720），与逻辑像素
/// 无换算关系——放行它连「按显示几何缩放」都没有，纯粹是脏数字漏进渲染。
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

Future<void> _pump(
  WidgetTester tester,
  List<AudioCue> cues, {
  required bool respect,
  required double fontSize,
}) async {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
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
}

/// 取填充层（非描边层）的 [Text]：描边层带 `foreground` paint。
Text _fill(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .firstWhere((Text t) => t.style?.foreground == null);

void main() {
  group('纯字幕模式：行内 \\fs 不得覆盖用户字号', () {
    testWidgets('单独 \\fs 行：字号恒等于用户滑块值', (WidgetTester tester) async {
      await _pump(
        tester,
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,{\fs90}あ'),
        respect: false,
        fontSize: 36,
      );
      expect(_fill(tester, 'あ').style?.fontSize, 36,
          reason: r'关闭「尊重字幕自带样式」后行内 \fs90 必须失效，用用户字号 36');
    });

    testWidgets('改用户字号后真的跟着变（滑块没被架空）', (WidgetTester tester) async {
      await _pump(
        tester,
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,{\fs90}あ'),
        respect: false,
        fontSize: 60,
      );
      expect(_fill(tester, 'あ').style?.fontSize, 60,
          reason: '同一条带 \\fs 的字幕，滑块调到 60 就必须渲染 60');
    });

    testWidgets('一行内多段 \\fs（大小混排）在纯字幕模式统一成用户字号', (WidgetTester tester) async {
      await _pump(
        tester,
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,'
            r'{\fs90}大{\fs20}小'),
        respect: false,
        fontSize: 36,
      );
      expect(_fill(tester, '大').style?.fontSize, 36);
      expect(_fill(tester, '小').style?.fontSize, 36,
          reason: '纯字幕模式外观统一：同一行不得因作者 \\fs 出现大小混排');
    });

    testWidgets('respect 开：\\fs 仍按作者字号生效（不回归 ON 路径）',
        (WidgetTester tester) async {
      await _pump(
        tester,
        _parse(r'Dialogue: 0,0:00:00.00,0:00:02.00,D,,0,0,0,,{\fs90}あ'),
        respect: true,
        fontSize: 36,
      );
      // 显示区高 = 800×(720/1280) = 450 → 90×450/720 = 56.25（测试环境无真字体表，
      // cell 系数 1.0）。用户字号 36 不参与。
      expect(_fill(tester, 'あ').style?.fontSize, closeTo(56.25, 0.01),
          reason: r'尊重模式下 \fs90 仍按 PlayRes 缩放到 56.25');
    });
  });
}
