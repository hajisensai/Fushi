import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue(String text) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'ch'
    ..sentenceIndex = 0
    ..textFragmentId = '#s1'
    ..text = text
    ..startMs = 0
    ..endMs = 5000
    ..audioFileIndex = 0;
}

VideoPlayerController _controllerWithCue(String text) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[_cue(text)]);
  c.debugUpdateCueForPosition(100); // 让 currentCue=该句
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  testWidgets('blur off: no ImageFiltered around subtitle', (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    await _pump(
        tester, VideoSubtitleOverlay(controller: c, blurEnabled: false));
    expect(find.text('テ'), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('blur on: ImageFiltered wraps subtitle, revealed=false',
      (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: true));
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('blur on + tap reveal: ImageFiltered gone after reveal',
      (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: true));
    expect(find.byType(ImageFiltered), findsOneWidget);
    await tester.tap(find.byKey(const Key('video-subtitle-reveal')));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('appearance: custom font size applied', (tester) async {
    final VideoPlayerController c = _controllerWithCue('A');
    await _pump(
      tester,
      VideoSubtitleOverlay(controller: c, fontSize: 40),
    );
    final Text txt = tester.widget<Text>(find.text('A'));
    expect(txt.style?.fontSize, 40);
  });

  group('hitTester 按全局坐标反查字幕字符（点同句换词不恢复播放的基础）', () {
    testWidgets('命中字符返回正确的整句 + grapheme 下标 + 矩形', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      final Offset center = tester.getCenter(find.text('ス')); // grapheme 1
      final SubtitleCharHit? hit = ht.hitTest(center);
      expect(hit, isNotNull);
      expect(hit!.sentence, 'テスト');
      expect(hit.graphemeIndex, 1);
      expect(hit.charRect.contains(center), isTrue);
    });

    testWidgets('点字幕外的空白返回 null（barrier 据此走 dismiss）', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      // 左上角远离底部居中的字幕。
      expect(ht.hitTest(const Offset(2, 2)), isNull);
    });

    testWidgets('模糊态不反查（与点击不查词一致）', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, hitTester: ht, blurEnabled: true),
      );

      final Offset center = tester.getCenter(find.text('ス'));
      expect(ht.hitTest(center), isNull);
    });

    testWidgets('无当前字幕句时返回 null', (tester) async {
      final VideoPlayerController c = VideoPlayerController(); // 无 cue
      final VideoSubtitleHitTester ht = VideoSubtitleHitTester();
      await _pump(tester, VideoSubtitleOverlay(controller: c, hitTester: ht));

      expect(ht.hitTest(const Offset(100, 100)), isNull);
    });
  });
}
