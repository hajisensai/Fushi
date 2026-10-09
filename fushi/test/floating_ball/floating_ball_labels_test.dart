import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/semantics.dart'
    show SemanticsAction, SemanticsData, SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test(
    'button label preference defaults on and survives file database reopen',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'fushi_ball_labels_',
      );
      final File file = File('${directory.path}/prefs.sqlite');
      FushiDatabase open() =>
          FushiDatabase.forTesting(DatabaseConnection(NativeDatabase(file)));
      FushiDatabase database = open();
      PreferencesRepository prefs = PreferencesRepository(database);
      try {
        await prefs.loadFromDb();
        expect(prefs.floatingBallShowLabels, isTrue);
        for (final bool shown in <bool>[false, true]) {
          await prefs.setFloatingBallShowLabels(shown);
          prefs.dispose();
          await database.close();
          database = open();
          prefs = PreferencesRepository(database);
          await prefs.loadFromDb();
          expect(prefs.floatingBallShowLabels, shown);
        }
      } finally {
        prefs.dispose();
        await database.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    testWidgets(
      'labels toggle while expanded on $platform; icon stays named and clickable',
      (WidgetTester tester) async {
        final ValueNotifier<bool> showLabels = ValueNotifier<bool>(true);
        final SemanticsHandle semantics = tester.ensureSemantics();
        int invoked = 0;
        int backgroundTaps = 0;
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const Key actionKey = ValueKey<String>('labels-test-lookup');
        SemanticsNode accessibleAction() {
          // Tooltip exposes the accessible description through `tooltip`, not
          // `label`. Start at the real icon so getSemantics resolves its merged
          // actionable node, rather than an ancestor Material/container node.
          final Finder icon = find.descendant(
            of: find.byKey(actionKey),
            matching: find.byIcon(Icons.search),
          );
          expect(icon, findsOneWidget);
          final SemanticsNode node = tester.getSemantics(icon);
          final SemanticsData data = node.getSemanticsData();
          expect(data.tooltip, 'Lookup example');
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.hasAction(SemanticsAction.tap), isTrue);
          return node;
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: showLabels,
                  builder: (BuildContext context, bool shown, Widget? child) =>
                      Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => backgroundTaps++,
                            child: const SizedBox.expand(),
                          ),
                          ReaderFloatingBall(
                            viewport: const Rect.fromLTWH(0, 0, 400, 600),
                            actions: <ReaderHeaderAction>[
                              ReaderHeaderAction(
                                key: actionKey,
                                icon: Icons.search,
                                label: 'Lookup example',
                                onPressed: () => invoked++,
                              ),
                            ],
                            dock: ReaderFloatingBallDock.right,
                            verticalFraction: 0.7,
                            animate: false,
                            showLabels: shown,
                            onDockChanged:
                                (
                                  ReaderFloatingBallDock dock,
                                  double fraction,
                                ) {},
                          ),
                        ],
                      ),
                ),
              ),
            ),
          );
          await tester.tap(
            find.byKey(
              const ValueKey<String>('fushi_reader_floating_ball_icon'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Lookup example'), findsOneWidget);
          accessibleAction();
          final Offset oldLabelCenter = tester.getCenter(
            find.text('Lookup example'),
          );
          final Offset originalIconCenter = tester.getCenter(
            find.byKey(actionKey),
          );

          showLabels.value = false;
          await tester.pumpAndSettle();
          expect(find.text('Lookup example'), findsNothing);
          expect(find.byTooltip('Lookup example'), findsOneWidget);
          final SemanticsNode hiddenLabelAction = accessibleAction();
          expect(tester.getCenter(find.byKey(actionKey)), originalIconCenter);
          await tester.tapAt(oldLabelCenter);
          await tester.pump();
          expect(
            backgroundTaps,
            1,
            reason: 'Hidden labels must not leave invisible input surfaces',
          );
          expect(invoked, 0);
          tester.binding.pipelineOwner.semanticsOwner!.performAction(
            hiddenLabelAction.id,
            SemanticsAction.tap,
          );
          await tester.pumpAndSettle();
          expect(
            invoked,
            1,
            reason: 'The named icon remains an accessible action',
          );

          showLabels.value = true;
          await tester.pumpAndSettle();
          expect(find.text('Lookup example'), findsOneWidget);
          showLabels.value = false;
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(actionKey));
          await tester.pumpAndSettle();
          expect(invoked, 2);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          semantics.dispose();
          showLabels.dispose();
        }
      },
    );
  }
}
