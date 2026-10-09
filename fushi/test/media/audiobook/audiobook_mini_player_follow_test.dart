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
}
