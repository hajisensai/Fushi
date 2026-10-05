import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart';

/// 2026-10 体验优化：底栏槽位按钮并进播放条 trailing 后，360dp 窄屏下拖 3 颗
/// 以上按钮不得让整条 bar 溢出；三联键与设置键仍须完整可见。
void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required AudiobookPlayerController controller,
    Widget? trailing,
    bool reversed = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AudiobookPlayBar(
              controller: controller,
              onOpenSettings: () {},
              reversed: reversed,
              trailing: trailing,
            ),
          ),
        ),
      ),
    );
  }

  Widget wideTrailing(int buttonCount) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (int i = 0; i < buttonCount; i++)
        IconButton(onPressed: () {}, icon: const Icon(Icons.bookmark_outline)),
      const SizedBox(width: 8),
      const Text('12:34 / 56:78  99.9%'),
    ],
  );

  for (final bool reversed in <bool>[false, true]) {
    testWidgets(
      '360dp + 5 trailing buttons does not overflow (reversed: $reversed)',
      (WidgetTester tester) async {
        final AudiobookPlayerController controller =
            AudiobookPlayerController();
        addTearDown(controller.dispose);
        await pumpBar(
          tester,
          controller: controller,
          trailing: wideTrailing(5),
          reversed: reversed,
        );

        expect(tester.takeException(), isNull);
        // trailing 进了横向滚动容器，传输键与设置键完整留在屏内。
        expect(
          find.byKey(const ValueKey<String>('audiobook_play_bar_trailing')),
          findsOneWidget,
        );
        for (final IconData icon in <IconData>[
          Icons.skip_previous_outlined,
          Icons.play_arrow_outlined,
          Icons.skip_next_outlined,
          Icons.tune_outlined,
        ]) {
          final Rect r = tester.getRect(find.byIcon(icon));
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(360));
        }

        final Finder trailingScroll = find.byKey(
          const ValueKey<String>('audiobook_play_bar_trailing'),
        );
        final ScrollableState scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: trailingScroll,
            matching: find.byType(Scrollable),
          ),
        );
        expect(scrollable.position.maxScrollExtent, greaterThan(0));
        final Rect playbackBefore = tester.getRect(
          find.byIcon(Icons.play_arrow_outlined),
        );
        await tester.drag(
          trailingScroll,
          Offset(reversed ? -80 : 80, 0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(
          scrollable.position.pixels,
          greaterThan(0),
          reason: '溢出的槽位按钮必须能用鼠标拖出来',
        );
        expect(
          tester.getRect(find.byIcon(Icons.play_arrow_outlined)),
          playbackBefore,
          reason: '横拖只移动 trailing，固定播放键不动',
        );
      },
    );
  }

  testWidgets('without trailing there is no scroll container', (
    WidgetTester tester,
  ) async {
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    await pumpBar(tester, controller: controller);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('audiobook_play_bar_trailing')),
      findsNothing,
    );
  });
}
