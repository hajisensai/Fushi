import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// c32 gap-vidmisc-2：ASS 动画（`\fad` / `\t` / `\move` / 卡拉 OK）在场时，逐帧 ticker
/// 只在字幕时钟变了时重建字幕层；暂停（时钟不动）时不再按屏幕刷新率整层重建。
///
/// 判据：字幕层没重建时，同一个字的 [Text] 组件还是上一帧那一个实例（build 没跑）；
/// 重建了就是新实例。
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

List<AudioCue> _parse(String dialogue) =>
    AssParser.parseString(content: '$_kAssHead$dialogue\n', bookKey: 'clk');

Text _fill(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .firstWhere((Text t) => t.style?.foreground == null);

Future<VideoPlayerController> _pump(
  WidgetTester tester,
  List<AudioCue> cues,
  int posMs,
) async {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(cues);
  c.debugSetPositionForTesting(posMs);
  c.debugUpdateCueForPosition(posMs);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(controller: c, respectAssStyle: true),
      ),
    ),
  );
  await tester.pump();
  return c;
}

void main() {
  testWidgets(r'卡拉 OK 在场、时钟不动（暂停）：逐帧 ticker 不重建字幕层', (
    WidgetTester tester,
  ) async {
    final List<AudioCue> cues = _parse(
      r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\k50}あ{\k50}い',
    );
    await _pump(tester, cues, 600);
    final Text before = _fill(tester, 'い');
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(
      identical(_fill(tester, 'い'), before),
      isTrue,
      reason: '时钟没变，字幕层不该被 ticker 逐帧重建',
    );
  });

  testWidgets(r'\t 动画在场、时钟前进：下一帧照常重建并插值', (WidgetTester tester) async {
    final List<AudioCue> cues = _parse(
      r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\t(0,1000,\1a&HFF&)}あ',
    );
    final VideoPlayerController c = await _pump(tester, cues, 500);
    final Text before = _fill(tester, 'あ');
    expect(before.style!.color!.a, closeTo(0.5, 0.05));

    // 只动时钟、不发通知：靠 ticker 发现时钟变了而重建。
    c.debugSetPositionForTesting(750);
    await tester.pump(const Duration(milliseconds: 8));
    final Text after = _fill(tester, 'あ');
    expect(identical(after, before), isFalse);
    expect(after.style!.color!.a, closeTo(0.25, 0.05));
  });

  testWidgets(r'时钟不动但调轴变了：ticker 照样重建（调轴是动画时间输入的一部分）', (
    WidgetTester tester,
  ) async {
    final List<AudioCue> cues = _parse(
      r'Dialogue: 0,0:00:00.00,0:00:02.00,K,,0,0,0,,{\t(0,1000,\1a&HFF&)}あ',
    );
    final VideoPlayerController c = await _pump(tester, cues, 500);
    expect(_fill(tester, 'あ').style!.color!.a, closeTo(0.5, 0.05));
    c.debugSetDelayMsForTesting(250, positionMs: 500);
    await tester.pump(const Duration(milliseconds: 8));
    // 字幕晚 250 ms → 等效位置 250 ms → p=0.25 → alpha 0.75。
    expect(_fill(tester, 'あ').style!.color!.a, closeTo(0.75, 0.05));
  });
}
