import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_jump_panel.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue(int i, int s, int e, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Stack(children: <Widget>[child])),
    );

void main() {
  group('formatCueTimestamp', () {
    test('sub-hour cues format as m:ss', () {
      expect(formatCueTimestamp(0), '0:00');
      expect(formatCueTimestamp(7000), '0:07');
      expect(formatCueTimestamp(187000), '3:07');
      expect(formatCueTimestamp(599000), '9:59');
    });

    test('hour-plus cues format as h:mm:ss', () {
      expect(formatCueTimestamp(3600000), '1:00:00');
      expect(formatCueTimestamp(3729000), '1:02:09');
    });

    test('negative clamps to zero (defensive)', () {
      expect(formatCueTimestamp(-500), '0:00');
    });

    test('truncates sub-second to floor (no rounding up)', () {
      // 1999ms is still 0:01, not 0:02.
      expect(formatCueTimestamp(1999), '0:01');
    });
  });

  group('VideoSubtitleJumpPanel', () {
    testWidgets('renders one row per cue with timestamp + text', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, 1000, 'first line'),
        _cue(1, 65000, 67000, 'second line'),
      ]);

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      expect(find.text('first line'), findsOneWidget);
      expect(find.text('second line'), findsOneWidget);
      expect(find.text('0:00'), findsOneWidget);
      expect(find.text('1:05'), findsOneWidget);
    });

    testWidgets('tapping a row reports the tapped cue (for seek)', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, 1000, 'first line'),
        _cue(1, 2000, 3000, 'second line'),
      ]);
      AudioCue? tapped;

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (AudioCue cue) => tapped = cue,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      await tester.tap(find.text('second line'));
      await tester.pump();

      expect(tapped, isNotNull);
      expect(tapped!.startMs, 2000);
      expect(tapped!.text, 'second line');
    });

    testWidgets('highlights the current playing cue and follows changes', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, 1000, 'alpha'),
        _cue(1, 2000, 3000, 'beta'),
      ]);

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      FontWeight? weightOf(String text) =>
          tester.widget<Text>(find.text(text)).style?.fontWeight;

      // No cue active yet → neither bold.
      expect(weightOf('alpha'), isNot(FontWeight.w600));
      expect(weightOf('beta'), isNot(FontWeight.w600));

      // Position inside cue0 → 'alpha' becomes the highlighted (bold) row.
      controller.debugUpdateCueForPosition(500);
      await tester.pump();
      expect(weightOf('alpha'), FontWeight.w600);
      expect(weightOf('beta'), isNot(FontWeight.w600));

      // Advance into cue1 → highlight follows to 'beta'.
      controller.debugUpdateCueForPosition(2500);
      await tester.pump();
      expect(weightOf('beta'), FontWeight.w600);
      expect(weightOf('alpha'), isNot(FontWeight.w600));
    });

    testWidgets('shows empty hint when there are no cues', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(const <AudioCue>[]);

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'No subtitles loaded',
      )));

      expect(find.text('No subtitles loaded'), findsOneWidget);
    });

    testWidgets('close button fires onClose', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'x')]);
      bool closed = false;

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onClose: () => closed = true,
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closed, isTrue);
    });
  });
}
