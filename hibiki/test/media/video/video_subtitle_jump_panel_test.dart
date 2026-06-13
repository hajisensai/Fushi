import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_jump_panel.dart';
import 'package:hibiki/src/media/video/video_subtitle_selection.dart';
import 'package:hibiki/utils.dart';
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
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
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
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
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

    testWidgets(
        'filters favorites/selected, checkbox multi-selects card context, '
        'and row tap still seeks', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 0, 1000, 'alpha line'),
        _cue(1, 2000, 3000, 'beta favorite'),
        _cue(2, 4000, 5200, 'gamma line'),
      ];
      controller.setCues(cues);
      final Set<int> selectedStarts = <int>{};
      AudioCue? tapped;

      await tester.pumpWidget(_wrap(StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          return VideoSubtitleJumpPanel(
            controller: controller,
            onTapCue: (AudioCue cue) => tapped = cue,
            onClose: () {},
            onCopyCue: (_) {},
            onFavoriteCue: (_) async {},
            isCueFavorited: (AudioCue cue) => cue.text.contains('favorite'),
            isCueSelectedForCard: (AudioCue cue) =>
                selectedStarts.contains(cue.startMs),
            onToggleCueSelection: (AudioCue cue) {
              setState(() {
                if (!selectedStarts.add(cue.startMs)) {
                  selectedStarts.remove(cue.startMs);
                }
              });
            },
            onClearCueSelection: () => setState(selectedStarts.clear),
            colorScheme: const ColorScheme.dark(),
            title: 'Subtitle list',
            emptyHint: 'empty',
            width: 520,
          );
        },
      )));

      expect(find.text('alpha line'), findsOneWidget);
      expect(find.text('beta favorite'), findsOneWidget);
      expect(find.text('gamma line'), findsOneWidget);

      await tester.tap(find.text(t.video_subtitle_filter_favorites));
      await tester.pumpAndSettle();
      expect(find.text('beta favorite'), findsOneWidget);
      expect(find.text('alpha line'), findsNothing);

      await tester.tap(find.text(t.video_subtitle_filter_all));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();
      expect(tapped, isNull,
          reason: 'checkbox selection must not trigger the row seek callback');
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pump();
      expect(selectedStarts, <int>{0, 4000});

      final AudioCue? context = buildSelectedSubtitleCueContext(
        cues: cues,
        selectedStartMs: selectedStarts,
      );
      expect(context, isNotNull);
      expect(context!.startMs, 0);
      expect(context.endMs, 5200);
      expect(context.text, 'alpha line\ngamma line');

      await tester.tap(find.text(t.video_subtitle_filter_selected));
      await tester.pumpAndSettle();
      expect(find.text('alpha line'), findsOneWidget);
      expect(find.text('gamma line'), findsOneWidget);
      expect(find.text('beta favorite'), findsNothing);

      await tester.tap(find.text('gamma line'));
      await tester.pump();
      expect(tapped, isNotNull);
      expect(tapped!.startMs, 4000);
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
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
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
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
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
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closed, isTrue);
    });

    // TODO-152 sub-A: inline action buttons (jump/copy/favorite) + header toolbar.

    testWidgets('current cue row shows inline jump/copy/favorite buttons', (
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
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));
      // Selecting the current cue keeps its inline three buttons visible.
      controller.debugUpdateCueForPosition(500);
      await tester.pump();

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.content_copy_outlined), findsOneWidget);
      expect(find.byIcon(Icons.star_border), findsOneWidget);
    });

    testWidgets('inline copy button fires onCopyCue with the row cue', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'copy me')]);
      AudioCue? copied;

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onCopyCue: (AudioCue c) => copied = c,
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));
      controller.debugUpdateCueForPosition(500);
      await tester.pump();

      await tester.tap(find.byIcon(Icons.content_copy_outlined));
      await tester.pump();
      expect(copied, isNotNull);
      expect(copied!.text, 'copy me');
    });

    testWidgets(
        'inline favorite button fires onFavoriteCue + filled star when '
        'favorited', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'fav me')]);
      AudioCue? favorited;
      bool isFav = false;

      VideoSubtitleJumpPanel panel() => VideoSubtitleJumpPanel(
            controller: controller,
            onTapCue: (_) {},
            onCopyCue: (_) {},
            onFavoriteCue: (AudioCue c) async => favorited = c,
            isCueFavorited: (_) => isFav,
            onClose: () {},
            colorScheme: const ColorScheme.dark(),
            title: 'Subtitle list',
            emptyHint: 'empty',
          );

      await tester.pumpWidget(_wrap(panel()));
      controller.debugUpdateCueForPosition(500);
      await tester.pump();

      // Not favorited yet -> hollow star.
      expect(find.byIcon(Icons.star_border), findsOneWidget);
      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pump();
      expect(favorited, isNotNull);
      expect(favorited!.text, 'fav me');

      // Favorited state rebuild -> filled star.
      isFav = true;
      await tester.pumpWidget(_wrap(panel()));
      controller.debugUpdateCueForPosition(500);
      await tester.pump();
      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('header toolbar has font A-/A+ and auto-scroll toggle', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'x')]);

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      // Font step buttons + auto-scroll (default on -> filled icon).
      expect(find.byIcon(Icons.text_decrease), findsOneWidget);
      expect(find.byIcon(Icons.text_increase), findsOneWidget);
      expect(find.byIcon(Icons.vertical_align_center), findsOneWidget);

      // Toggle auto-scroll off -> pause icon.
      await tester.tap(find.byIcon(Icons.vertical_align_center));
      await tester.pump();
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
    });

    testWidgets('larger font button enlarges row text', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'sized')]);

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      double fontOf(String text) =>
          tester.widget<Text>(find.text(text)).style!.fontSize!;
      final double before = fontOf('sized');

      await tester.tap(find.byIcon(Icons.text_increase));
      await tester.pump();
      expect(fontOf('sized'), greaterThan(before),
          reason: 'A+ enlarges row font (local transient step)');
    });
  });

  // Source guard: inline tooltips wire to existing i18n keys; copy toast reuses
  // copied_to_clipboard (no new redundant copied key).
  test('source guard: jump panel inline action i18n keys exist', () {
    expect(t.video_subtitle_list_jump, isNotEmpty);
    expect(t.video_subtitle_list_font_smaller, isNotEmpty);
    expect(t.video_subtitle_list_font_larger, isNotEmpty);
    expect(t.video_subtitle_list_auto_scroll, isNotEmpty);
    expect(t.copy, isNotEmpty);
    expect(t.collection_sentence, isNotEmpty);
  });
}
