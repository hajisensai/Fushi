// 反馈 #xif6-gtSz7：统一外观下字幕描边颜色 / 粗细可自定义，阴影颜色可自定义。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = 0
  ..endMs = 2000
  ..audioFileIndex = 0;

Future<void> _pump(
  WidgetTester tester, {
  required double outlineThickness,
  Color outlineColor = const Color(0xFF123456),
}) async {
  final VideoPlayerController c = VideoPlayerController();
  addTearDown(c.dispose);
  c.setCues(<AudioCue>[_cue('あい')]);
  c.debugSetPositionForTesting(500);
  c.debugUpdateCueForPosition(500);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VideoSubtitleOverlay(
          controller: c,
          shadowColor: const Color(0xE6FF0000),
          shadowThickness: 3,
          outlineColor: outlineColor,
          outlineThickness: outlineThickness,
        ),
      ),
    ),
  );
  await tester.pump();
}

Iterable<Text> _strokeTexts(WidgetTester tester, String ch) => tester
    .widgetList<Text>(find.text(ch))
    .where((Text t) => t.style?.foreground != null);

void main() {
  group('VideoSubtitleStyle 描边字段', () {
    test('默认无描边，旧 JSON 缺字段也无描边（外观不变）', () {
      expect(VideoSubtitleStyle.defaults.outlineThickness, 0);
      expect(VideoSubtitleStyle.defaults.outlineColor, isNull);
      expect(
        VideoSubtitleStyle.defaults.resolveOutlineColor(),
        kDefaultSubtitleOutlineColor,
      );
      final VideoSubtitleStyle legacy = VideoSubtitleStyle.decode(
        '{"_v":2,"fontSize":30}',
      );
      expect(legacy.outlineThickness, 0);
      expect(legacy.outlineColor, isNull);
    });

    test('encode/decode 往返保留描边色、粗细与阴影色，粗细夹到上限', () {
      final VideoSubtitleStyle s = VideoSubtitleStyle.defaults.copyWith(
        outlineColor: const Color(0xFF00FF00),
        outlineThickness: 2.5,
        shadowColor: const Color(0xE60000FF),
      );
      final VideoSubtitleStyle back = VideoSubtitleStyle.decode(
        VideoSubtitleStyle.encode(s),
      );
      expect(back.outlineColor, const Color(0xFF00FF00));
      expect(back.outlineThickness, 2.5);
      expect(back.shadowColor, const Color(0xE60000FF));

      final VideoSubtitleStyle huge = VideoSubtitleStyle.decode(
        VideoSubtitleStyle.encode(s.copyWith(outlineThickness: 99)),
      );
      expect(huge.outlineThickness, kVideoSubtitleMaxOutline);
    });

    test('subtitleOutlineStrokeWidth：可见宽 ×2；<=0 不描边', () {
      expect(subtitleOutlineStrokeWidth(2), 4);
      expect(subtitleOutlineStrokeWidth(0), 0);
      expect(subtitleOutlineStrokeWidth(-1), 0);
    });
  });

  group('VideoSubtitleOverlay 统一外观描边', () {
    testWidgets('粗细 0：不画描边层，只有带柔和投影的填充（历史外观）', (WidgetTester tester) async {
      await _pump(tester, outlineThickness: 0);
      expect(_strokeTexts(tester, 'あ'), isEmpty);
      final Text fill = tester.widget<Text>(find.text('あ').first);
      expect(fill.style!.shadows, isNotEmpty);
      expect(fill.style!.shadows!.first.color, const Color(0xE6FF0000));
    });

    testWidgets('粗细 2：描边层用用户色、strokeWidth=4，投影在描边层、填充层无投影', (
      WidgetTester tester,
    ) async {
      await _pump(tester, outlineThickness: 2);
      final List<Text> strokes = _strokeTexts(tester, 'あ').toList();
      expect(strokes, isNotEmpty, reason: '开了描边必须有描边层');
      final Paint paint = strokes.first.style!.foreground!;
      expect(paint.color.toARGB32(), 0xFF123456);
      expect(paint.strokeWidth, closeTo(4, 1e-9));
      expect(
        strokes.first.style!.shadows!.first.color,
        const Color(0xE6FF0000),
      );
      final Iterable<Text> fills = tester
          .widgetList<Text>(find.text('あ'))
          .where((Text t) => t.style?.foreground == null);
      expect(fills, isNotEmpty);
      for (final Text f in fills) {
        expect(
          f.style!.shadows ?? const <Shadow>[],
          isEmpty,
          reason: '填充层不重复挂投影（阴影 < 描边 < 填充）',
        );
      }
    });
  });
}
