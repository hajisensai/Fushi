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

    testWidgets('shows loading state instead of empty hint while cues load', (
      WidgetTester tester,
    ) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.debugSetSubtitleCuesLoadingForTesting(true);

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
        loadingHint: 'Loading subtitles...',
      )));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Loading subtitles...'), findsOneWidget);
      expect(find.text('No subtitles loaded'), findsNothing);

      controller.debugSetSubtitleCuesLoadingForTesting(false);
      await tester.pump();
      expect(find.text('No subtitles loaded'), findsOneWidget);
    });

    testWidgets('no close X button (tap-outside closes, BUG-254)',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'x')]);

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

      // BUG-254：右上角 X 关闭按钮已删除，关闭改由页面层全屏 barrier（点面板外）承载。
      expect(find.byIcon(Icons.close), findsNothing);
    });

    // TODO-152 sub-A: inline action buttons (jump/copy/favorite) + header toolbar.

    testWidgets(
        'TODO-309/BUG-268: every row shows inline jump/copy/favorite buttons '
        'persistently (not only hover/selected)', (WidgetTester tester) async {
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
      // No cue is current, no hover, nothing selected: the action buttons must
      // STILL be present on every row (regression guard: revert to the old
      // `showActions = hovered || selected || selectedForCard` gate -> these
      // would be findsNothing -> red).
      expect(find.byIcon(Icons.play_arrow), findsNWidgets(2));
      expect(find.byIcon(Icons.content_copy_outlined), findsNWidgets(2));
      expect(find.byIcon(Icons.star_border), findsNWidgets(2));
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

    testWidgets(
        'TODO-340: row subtitle text wraps to full content '
        '(no single-line ellipsis), rendered per-grapheme when lookable',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      // Use distinct ascii letters (no repeats) so each grapheme is uniquely
      // findable as its own Text widget.
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'abcdefg')]);

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        // With onLookupCue the row text is rendered per-grapheme inside a Wrap
        // (wraps + precise hit-test). Each grapheme is its own Text widget.
        onLookupCue: (AudioCue _, int __, Rect ___) {},
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
        width: 280,
      )));

      // Per-grapheme rendering inside a Wrap → many single-char Text widgets,
      // none clamped to a single elided line. Revert to single-line ellipsis
      // (one Text, maxLines:1, softWrap:false) → no Wrap, no per-char → red.
      expect(find.byType(Wrap), findsWidgets);
      // Each distinct character renders as its own Text widget.
      expect(find.text('c'), findsOneWidget);
      final Text charText = tester.widget<Text>(find.text('c'));
      expect(charText.maxLines, isNull,
          reason: 'per-grapheme Text must not clamp to a single elided line');
      expect(charText.overflow, isNot(TextOverflow.ellipsis));
    });

    testWidgets(
        'TODO-340: without onLookupCue, row text is a single wrapping Text '
        '(no single-line ellipsis)', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, 1000, 'wrap me to full content even without lookup'),
      ]);

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        // onLookupCue omitted → whole sentence is a single Text, still wraps.
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
        width: 280,
      )));

      final Text rowText = tester.widget<Text>(
          find.text('wrap me to full content even without lookup'));
      expect(rowText.maxLines, isNull,
          reason:
              'row text must wrap, not clamp to one elided line (TODO-340)');
      expect(rowText.overflow, isNot(TextOverflow.ellipsis));
    });

    testWidgets(
        'TODO-340: tapping a grapheme looks up from that position (NOT seek, '
        'NOT always index 0)', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'lookup')]);
      AudioCue? seeked;
      AudioCue? lookedUp;
      int? lookupIndex;
      Rect? lookupRect;

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (AudioCue c) => seeked = c,
        onLookupCue: (AudioCue c, int i, Rect r) {
          lookedUp = c;
          lookupIndex = i;
          lookupRect = r;
        },
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      // Tap the 4th grapheme 'k' of "lookup" (index 3) → lookup must report
      // graphemeIndex 3 with that char's real rect, NOT seek, NOT index 0.
      await tester.tap(find.text('k'));
      await tester.pump();

      expect(lookedUp, isNotNull);
      expect(lookedUp!.text, 'lookup');
      expect(lookupIndex, 3,
          reason:
              'tap maps to the hit grapheme index, not always 0 (TODO-340)');
      expect(lookupRect, isNotNull);
      expect(lookupRect, isNot(Rect.zero));
      expect(seeked, isNull, reason: 'tapping text must look up, not seek');
    });

    testWidgets(
        'TODO-278a/BUG-266: without onLookupCue, tapping row text still seeks '
        '(backward compatible)', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[_cue(0, 0, 1000, 'seek me')]);
      AudioCue? seeked;

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (AudioCue c) => seeked = c,
        // onLookupCue intentionally omitted (null).
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (_) => false,
        onClose: () {},
        colorScheme: const ColorScheme.dark(),
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      await tester.tap(find.text('seek me'));
      await tester.pump();
      expect(seeked, isNotNull);
      expect(seeked!.text, 'seek me');
    });

    testWidgets(
        'TODO-301/BUG-267: favorited row gets a left tertiary border marker',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 0, 1000, 'plain row'),
        _cue(1, 2000, 3000, 'fav row'),
      ]);
      const ColorScheme cs = ColorScheme.dark();

      await tester.pumpWidget(_wrap(VideoSubtitleJumpPanel(
        controller: controller,
        onTapCue: (_) {},
        onCopyCue: (_) {},
        onFavoriteCue: (_) async {},
        isCueFavorited: (AudioCue c) => c.text == 'fav row',
        onClose: () {},
        colorScheme: cs,
        title: 'Subtitle list',
        emptyHint: 'empty',
      )));

      Border? borderOf(String text) {
        // Nearest Container ancestor of the row text == the row's own Container
        // (which carries the favorite left-border decoration).
        final Container container = tester
            .widgetList<Container>(
              find.ancestor(
                of: find.text(text),
                matching: find.byType(Container),
              ),
            )
            .first;
        return (container.decoration as BoxDecoration?)?.border as Border?;
      }

      // Favorited row has a left border in the tertiary color; plain row has
      // none (revert the favorite marker -> both null -> red).
      final Border? favBorder = borderOf('fav row');
      expect(favBorder, isNotNull);
      expect(favBorder!.left.color, cs.tertiary);
      expect(favBorder.left.width, 3);

      expect(borderOf('plain row')?.left.width ?? 0, 0);
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
