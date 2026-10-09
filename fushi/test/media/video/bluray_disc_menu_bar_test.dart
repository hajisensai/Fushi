import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/bluray_disc_menu_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final double width in <double>[180, 420]) {
    testWidgets('pending menu disables navigation but keeps exit at $width', (
      WidgetTester tester,
    ) async {
      int exits = 0;
      int navigations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: BlurayDiscMenuBar(
                navigationEnabled: false,
                backLabel: 'Back',
                topMenuLabel: 'Top menu',
                popupMenuLabel: 'Popup menu',
                onBack: () => exits++,
                onTopMenu: () => navigations++,
                onPopupMenu: () => navigations++,
              ),
            ),
          ),
        ),
      );
      for (final String key in <String>[
        'bluray-menu-top',
        'bluray-menu-popup',
      ]) {
        final Widget button = tester.widget(find.byKey(ValueKey<String>(key)));
        expect(
          button is FushiIconButtonControl
              ? button.onPressed
              : (button as FushiTextButton).onPressed,
          isNull,
        );
      }
      await tester.tap(find.byKey(const ValueKey<String>('bluray-menu-exit')));
      expect(exits, 1);
      expect(navigations, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow disc bar keeps all actions as accessible icons', (
    WidgetTester tester,
  ) async {
    final List<String> actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: BlurayDiscMenuBar(
                backLabel: 'Back',
                topMenuLabel: 'Top menu',
                popupMenuLabel: 'Popup menu',
                onBack: () => actions.add('back'),
                onTopMenu: () => actions.add('top'),
                onPopupMenu: () => actions.add('popup'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Top menu'), findsNothing);
    expect(find.byTooltip('Top menu'), findsOneWidget);
    expect(
      // The bar's own surface — Fushi controls bring their own Material.
      tester
          .getSize(
            find
                .descendant(
                  of: find.byType(BlurayDiscMenuBar),
                  matching: find.byType(Material),
                )
                .first,
          )
          .width,
      lessThanOrEqualTo(180),
    );
    await tester.tap(find.byKey(const ValueKey<String>('bluray-menu-top')));
    await tester.tap(find.byKey(const ValueKey<String>('bluray-menu-popup')));
    await tester.tap(find.byKey(const ValueKey<String>('bluray-menu-exit')));
    expect(actions, <String>['top', 'popup', 'back']);
  });

  testWidgets(
    'wide disc bar truncates long translations instead of overflowing',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                child: BlurayDiscMenuBar(
                  backLabel: 'Back',
                  topMenuLabel:
                      'A very long translated original disc top menu label',
                  popupMenuLabel:
                      'Another very long translated popup menu label',
                  onBack: () {},
                  onTopMenu: () {},
                  onPopupMenu: () {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(FushiTextButton), findsNWidgets(2));
      expect(tester.getSize(find.byType(BlurayDiscMenuBar)).width, 420);
    },
  );
}
