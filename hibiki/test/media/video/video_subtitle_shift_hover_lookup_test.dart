import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  c.debugUpdateCueForPosition(100);
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

typedef _Hit = ({String sentence, int graphemeIndex, Rect charRect});

void main() {
  // TODO-756a / BUG-411: video subtitles are Flutter-drawn overlays (not WebView),
  // so the reader JS shift-hover path never existed for video. This wires
  // Shift-mouse-hover lookup via VideoSubtitleOverlay.onCharHover, sharing the
  // same lookup chain as click (onCharTap). Tests assert: shift-hover hits ->
  // onCharHover fires same triple as tap; non-shift hover -> no lookup; 8px
  // throttle (same char + small move = no re-fire, new char = re-fire); needHover.
  group('TODO-756a video Shift-hover lookup', () {
    testWidgets(
        'shift held + hover over char -> onCharHover fires (same triple)',
        (WidgetTester tester) async {
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharHover: (String s, int i, Rect r) =>
              hovers.add((sentence: s, graphemeIndex: i, charRect: r)),
        ),
      );

      final Offset target =
          tester.getCenter(find.text('ス').first); // grapheme 1
      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await gesture.moveTo(target);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(hovers, isNotEmpty,
          reason: 'shift-hover over a subtitle char must fire onCharHover');
      expect(hovers.last.sentence, 'テスト');
      expect(hovers.last.graphemeIndex, 1);
      expect(hovers.last.charRect.contains(target), isTrue);
    });

    testWidgets('non-shift hover -> no lookup', (WidgetTester tester) async {
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharHover: (String s, int i, Rect r) =>
              hovers.add((sentence: s, graphemeIndex: i, charRect: r)),
        ),
      );

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(tester.getCenter(find.text('ス').first));
      await tester.pump();
      expect(hovers, isEmpty,
          reason: 'plain hover without shift must not look up');
    });

    testWidgets('throttle: same char small move no re-fire; new char re-fires',
        (WidgetTester tester) async {
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharHover: (String s, int i, Rect r) =>
              hovers.add((sentence: s, graphemeIndex: i, charRect: r)),
        ),
      );

      final Offset c1 = tester.getCenter(find.text('ス').first); // grapheme 1
      final Offset c2 = tester.getCenter(find.text('ト').first); // grapheme 2

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);

      await gesture.moveTo(c1);
      await tester.pump();
      expect(hovers.length, 1);
      expect(hovers.last.graphemeIndex, 1);

      // Same char, 1px move (< 8px) -> no re-fire (throttle).
      await gesture.moveTo(c1 + const Offset(1, 0));
      await tester.pump();
      expect(hovers.length, 1,
          reason: 'same char sub-threshold move must be throttled');

      // New char -> re-fire (switch word) even if displacement is small.
      await gesture.moveTo(c2);
      await tester.pump();
      expect(hovers.length, 2,
          reason: 'hitting a new char must re-fire (switch word)');
      expect(hovers.last.graphemeIndex, 2);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });

    testWidgets('blurred (playing) shift-hover does not look up',
        (WidgetTester tester) async {
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      c.debugSetIsPlayingForTesting(true);
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          blurEnabled: true,
          onCharHover: (String s, int i, Rect r) =>
              hovers.add((sentence: s, graphemeIndex: i, charRect: r)),
        ),
      );

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      // Blurred chars do not participate in hit-test (_charHitTest returns null).
      await gesture.moveTo(const Offset(2, 2));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(hovers, isEmpty,
          reason: 'blurred subtitle must not shift-hover look up');
    });

    testWidgets(
        'needHover: onCharHover registers exactly one extra MouseRegion',
        (WidgetTester tester) async {
      final VideoPlayerController c1 = _controllerWithCue('A');
      await _pump(tester, VideoSubtitleOverlay(controller: c1));
      final int baseline = find.byType(MouseRegion).evaluate().length;

      final VideoPlayerController c2 = _controllerWithCue('A');
      await _pump(
        tester,
        VideoSubtitleOverlay(controller: c2, onCharHover: (_, __, ___) {}),
      );
      final int withHover = find.byType(MouseRegion).evaluate().length;

      expect(withHover, baseline + 1,
          reason: 'onCharHover should add exactly one hover MouseRegion');
    });

    testWidgets('shift-hover same chain as tap: same char -> identical triple',
        (WidgetTester tester) async {
      final List<_Hit> taps = <_Hit>[];
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          onCharTap: (String s, int i, Rect r) =>
              taps.add((sentence: s, graphemeIndex: i, charRect: r)),
          onCharHover: (String s, int i, Rect r) =>
              hovers.add((sentence: s, graphemeIndex: i, charRect: r)),
        ),
      );

      final Offset target = tester.getCenter(find.text('ス').first);

      await tester.tapAt(target);
      await tester.pump();

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await gesture.moveTo(target);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(taps, hasLength(1));
      expect(hovers, isNotEmpty);
      expect(hovers.last.sentence, taps.last.sentence);
      expect(hovers.last.graphemeIndex, taps.last.graphemeIndex);
      expect(hovers.last.charRect, taps.last.charRect);
    });
  });
}
