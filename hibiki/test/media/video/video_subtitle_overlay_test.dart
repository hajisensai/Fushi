import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
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
  group('default position clears the bottom controls bar (TODO-089)', () {
    testWidgets('default subtitle bottom stays above the controls reserve',
        (tester) async {
      // 用户诉求：字幕默认不遮盖底部进度条。默认 overlay（bottomPadding=100）渲染时，
      // 字幕底缘到容器底的距离必须 >= 控制条预留高度，否则进度条会盖住字幕。
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(tester, VideoSubtitleOverlay(controller: c));

      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      final Rect charRect = tester.getRect(find.text('A'));
      final double gapFromBottom = overlayRect.bottom - charRect.bottom;
      expect(
        gapFromBottom,
        greaterThanOrEqualTo(kVideoControlsBottomReserve),
        reason: '字幕底缘距容器底 $gapFromBottom < 控制条预留 '
            '$kVideoControlsBottomReserve，会被进度条遮挡',
      );
    });

    testWidgets(
        'a manual lower bottomPadding is respected (covers bar by choice)',
        (tester) async {
      // 「除非用户手动调位置」：用户显式把字幕放低（20px）时如实尊重，不强制抬升。
      final VideoPlayerController c = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, bottomPadding: 20),
      );

      final Rect overlayRect =
          tester.getRect(find.byType(VideoSubtitleOverlay));
      final Rect charRect = tester.getRect(find.text('A'));
      final double gapFromBottom = overlayRect.bottom - charRect.bottom;
      // 字幕被有意放进控制条区：底缘距底应明显小于预留高度（尊重用户值）。
      expect(gapFromBottom, lessThan(kVideoControlsBottomReserve));
    });
  });

  testWidgets('blur off: no ImageFiltered around subtitle', (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    await _pump(
        tester, VideoSubtitleOverlay(controller: c, blurEnabled: false));
    expect(find.text('テ'), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('blur on + playing: ImageFiltered wraps subtitle, revealed=false',
      (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    c.debugSetIsPlayingForTesting(true); // 听力沉浸模糊只在播放中生效
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: true));
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('blur on + playing + tap reveal: ImageFiltered gone after reveal',
      (tester) async {
    final VideoPlayerController c = _controllerWithCue('テスト');
    c.debugSetIsPlayingForTesting(true);
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

    testWidgets('模糊态（播放中）不反查（与点击不查词一致）', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');
      c.debugSetIsPlayingForTesting(true); // 播放中才真模糊
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

  group('BUG-198 字幕字符层不吞鼠标 hover、tap 仍查词', () {
    testWidgets('字幕字符不再各自包 opaque GestureDetector（hover 透传）', (tester) async {
      // 旧实现每个字符包 HitTestBehavior.opaque 的 GestureDetector，吞掉指针
      // hover hit-test，盖在其下的 media_kit MouseRegion 收不到鼠标 → 鼠标移到
      // 字幕文字上控制条不再被唤起、光标被吃。根因修后字符层不得再有 opaque
      // GestureDetector；tap 命中统一交给一片 translucent GestureDetector。
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, onCharTap: (_, __, ___) {}),
      );
      final Iterable<GestureDetector> detectors =
          tester.widgetList<GestureDetector>(find.byType(GestureDetector));
      // 不允许任何 opaque GestureDetector（撤修复改回逐字符 opaque → 红）。
      for (final GestureDetector d in detectors) {
        expect(
          d.behavior,
          isNot(HitTestBehavior.opaque),
          reason: '字幕层出现 opaque GestureDetector，会吞 hover/光标（BUG-198 回归）',
        );
      }
      // 至少有一片 translucent 的 tap 层（承载查词）。
      expect(
        detectors.any((GestureDetector d) =>
            d.behavior == HitTestBehavior.translucent && d.onTapUp != null),
        isTrue,
        reason: '缺少 translucent 的字符 tap 层',
      );
    });

    testWidgets('tap 字幕字符仍触发 onCharTap（反查命中正确 grapheme）', (tester) async {
      String? tappedSentence;
      int? tappedIndex;
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect _) {
            tappedSentence = s;
            tappedIndex = i;
          },
        ),
      );
      await tester.tapAt(tester.getCenter(find.text('ス'))); // grapheme 1
      await tester.pump();
      expect(tappedSentence, 'テスト');
      expect(tappedIndex, 1);
    });
  });

  group('BUG-199 听力沉浸模糊只在播放中、查词暂停保持清晰', () {
    testWidgets('播放中：ImageFiltered 模糊；暂停（查词）：清晰无模糊', (tester) async {
      final VideoPlayerController c = _controllerWithCue('テスト');

      // 播放中 → 模糊生效。
      c.debugSetIsPlayingForTesting(true);
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c, blurEnabled: true),
      );
      expect(find.byType(ImageFiltered), findsOneWidget, reason: '播放中沉浸模式应模糊');

      // 暂停（查词必先暂停）→ 字幕清晰（撤 `&& isPlaying` → 仍模糊 → 红）。
      c.debugSetIsPlayingForTesting(false);
      await tester.pump();
      expect(find.byType(ImageFiltered), findsNothing,
          reason: '查词/暂停时字幕不该再被打码（BUG-199）');
    });
  });
}
