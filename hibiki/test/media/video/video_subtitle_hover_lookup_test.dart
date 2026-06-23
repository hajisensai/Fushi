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
  // TODO-756b: "look up on hover" toggle gates VideoSubtitleOverlay's hover
  // lookup. When ON (hoverAutoLookupEnabled: true), plain mouse-hover over a
  // subtitle char looks up WITHOUT holding Shift. When OFF (default), the chain
  // falls back to TODO-756a Shift+hover (plain hover = no lookup). Same lookup
  // chain (onCharHover) and same 8px throttle as 756a — only the gate differs.
  group('TODO-756b video hover-auto lookup', () {
    testWidgets('enabled: plain hover (no Shift) -> onCharHover fires',
        (WidgetTester tester) async {
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          hoverAutoLookupEnabled: true,
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

      // No Shift pressed at all.
      await gesture.moveTo(target);
      await tester.pump();

      expect(hovers, isNotEmpty,
          reason: 'with hover-auto enabled, plain hover must look up');
      expect(hovers.last.sentence, 'テスト');
      expect(hovers.last.graphemeIndex, 1);
      expect(hovers.last.charRect.contains(target), isTrue);
    });

    testWidgets('disabled (default): plain hover -> no lookup',
        (WidgetTester tester) async {
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          // hoverAutoLookupEnabled defaults to false.
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
          reason: 'with hover-auto disabled, plain hover must NOT look up');
    });

    testWidgets(
        'disabled (default): Shift+hover still looks up (756a fallback)',
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

      final Offset target = tester.getCenter(find.text('ス').first);
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
          reason: 'disabled falls back to 756a Shift+hover');
      expect(hovers.last.graphemeIndex, 1);
    });

    testWidgets('enabled: 8px throttle still applies on plain hover',
        (WidgetTester tester) async {
      final List<_Hit> hovers = <_Hit>[];
      final VideoPlayerController c = _controllerWithCue('テスト');
      await _pump(
        tester,
        VideoSubtitleOverlay(
          controller: c,
          hoverAutoLookupEnabled: true,
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

      await gesture.moveTo(c1);
      await tester.pump();
      expect(hovers.length, 1);
      expect(hovers.last.graphemeIndex, 1);

      // Same char, sub-threshold move -> throttled (no re-fire).
      await gesture.moveTo(c1 + const Offset(1, 0));
      await tester.pump();
      expect(hovers.length, 1,
          reason: 'same char sub-threshold move must be throttled');

      // New char -> re-fire (switch word).
      await gesture.moveTo(c2);
      await tester.pump();
      expect(hovers.length, 2,
          reason: 'hitting a new char must re-fire (switch word)');
      expect(hovers.last.graphemeIndex, 2);
    });
  });
}
