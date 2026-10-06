import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

Widget _app(Widget child, {required bool glass}) {
  return MaterialApp(
    theme: buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      textTheme: Typography.material2021().black,
      glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
      glassDesign: glass,
    ).copyWith(splashFactory: NoSplash.splashFactory),
    builder: (BuildContext context, Widget? child) =>
        FushiGlassScope(child: child!),
    home: Scaffold(
      body: Center(child: SizedBox(width: 400, child: child)),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  // Glass surfaces can keep a ticker alive; advance past finite transitions.
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  for (final bool glass in <bool>[false, true]) {
    testWidgets('menu callback can push a dialog (glass: $glass)', (
      WidgetTester tester,
    ) async {
      Future<int?>? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () {
                result = showFushiMenu<int>(
                  context: context,
                  position: const RelativeRect.fromLTRB(100, 100, 100, 100),
                  items: <PopupMenuEntry<int>>[
                    PopupMenuItem<int>(
                      value: 7,
                      onTap: () {
                        unawaited(
                          showDialog<void>(
                            context: context,
                            builder: (BuildContext context) =>
                                const AlertDialog(
                                  title: Text('Opened from menu'),
                                ),
                          ),
                        );
                      },
                      child: const Text('Open dialog'),
                    ),
                  ],
                );
              },
              child: const Text('Open menu'),
            ),
          ),
          glass: glass,
        ),
      );
      await tester.tap(find.text('Open menu'));
      await _settle(tester);
      await tester.tap(find.text('Open dialog'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Opened from menu'), findsOneWidget);
      expect(find.text('Open dialog', skipOffstage: false), findsNothing);
      expect(await result, 7);
    });

    testWidgets('search preserves a custom leading action (glass: $glass)', (
      WidgetTester tester,
    ) async {
      int invoked = 0;
      await tester.pumpWidget(
        _app(
          FushiSearchBar(
            hintText: 'Search',
            leading: IconButton(
              key: const ValueKey<String>('search-leading'),
              onPressed: () => invoked++,
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          glass: glass,
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('search-leading')));
      expect(invoked, 1);
      expect(tester.takeException(), isNull);
    });

    for (final FushiSearchFieldSize size in FushiSearchFieldSize.values) {
      testWidgets('search autofocus works ($size, glass: $glass)', (
        WidgetTester tester,
      ) async {
        final FocusNode focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          _app(
            FushiSearchBar(
              hintText: 'Search',
              size: size,
              focusNode: focus,
              autofocus: true,
            ),
            glass: glass,
          ),
        );
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
