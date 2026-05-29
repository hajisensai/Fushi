import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiIconButton', () {
    testWidgets('renders icon and tooltip via Semantics', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiIconButton(
          icon: Icons.play_arrow,
          tooltip: 'Play',
        ),
      ));

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
    });

    testWidgets('calls onTap when enabled and tapped', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.add,
          tooltip: 'Add',
          onTap: () => tapped = true,
        ),
      ));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tapped, isTrue);
    });

    testWidgets('disabled button does not fire onTap', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.delete,
          tooltip: 'Delete',
          enabled: false,
          onTap: () => tapped = true,
        ),
      ));

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();

      expect(tapped, isFalse);
    });

    testWidgets('busy mode disables during async onTap', (tester) async {
      final completer = Completer<void>();
      int tapCount = 0;

      await tester.pumpWidget(buildTestApp(
        HibikiIconButton(
          icon: Icons.sync,
          tooltip: 'Sync',
          busy: true,
          onTap: () async {
            tapCount++;
            await completer.future;
          },
        ),
      ));

      await tester.tap(find.byType(InkWell));
      await tester.pump();

      // Second tap should be ignored (busy)
      await tester.tap(find.byType(InkWell));
      await tester.pump();

      expect(tapCount, 1);

      completer.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('isWideTapArea uses IconButton instead of InkWell',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiIconButton(
          icon: Icons.settings,
          tooltip: 'Settings',
          isWideTapArea: true,
        ),
      ));

      expect(find.byType(IconButton), findsOneWidget);
    });
  });
}
