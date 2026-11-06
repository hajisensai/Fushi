import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart';

void main() {
  for (final double width in <double>[320, 720]) {
    testWidgets(
      'MD3 mini player at $width keeps a working persistent follow key',
      (WidgetTester tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final AudiobookPlayerController controller =
            AudiobookPlayerController();
        addTearDown(controller.dispose);
        final List<bool> persisted = <bool>[];
        controller.onFollowAudioPersist = (bool value) async {
          persisted.add(value);
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              splashFactory: NoSplash.splashFactory,
            ),
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: AudiobookMiniPlayer(
                    controller: controller,
                    showPlayButton: true,
                    chapterLabel:
                        'A long chapter label that must fit on a phone',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '320px reader must fit');
        final Finder follow = find.byWidgetPredicate(
          (Widget widget) =>
              widget is FushiFocusTarget &&
              widget.id.value == 'audiobook_follow',
        );
        expect(follow, findsOneWidget);
        expect(controller.followAudio.value, isTrue);
        for (final bool value in <bool>[false, true]) {
          Actions.maybeInvoke<ActivateIntent>(
            tester.element(follow),
            const ActivateIntent(),
          );
          await tester.pump();
          expect(controller.followAudio.value, value);
        }
        expect(persisted, <bool>[false, true]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'mini player scrub band stays below the button row (taps on a button '
    'bottom edge must not seek)',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(720, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: AudiobookMiniPlayer(
                controller: controller,
                showPlayButton: true,
                chapterLabel: 'Chapter',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Rect scrub = tester.getRect(
        find.byKey(const ValueKey<String>('audiobook_mini_player_scrub')),
      );
      final Iterable<Element> targets = find
          .byType(FushiFocusTarget)
          .evaluate();
      expect(targets, isNotEmpty);
      for (final Element target in targets) {
        final Rect button = tester.getRect(
          find.byElementPredicate((Element e) => e == target),
        );
        expect(
          scrub.top,
          greaterThanOrEqualTo(button.bottom),
          reason:
              '${(target.widget as FushiFocusTarget).id.value} overlaps the scrub band',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
