import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/shelf_sort.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';
import 'package:fushi_core/fushi_core.dart';

Widget host(Widget child) => ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );

void main() {
  testWidgets('mobile library actions stay visible while many tags scroll', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool selected = false;
    ShelfSortMode? chosen;
    await tester.pumpWidget(
      host(
        FushiTagFilterBar(
          tags: List<BookTagRow>.generate(
            20,
            (int i) => BookTagRow(
              id: i,
              name: 'Long tag $i',
              colorValue: 0xFF2196F3,
              sortOrder: i,
              createdAt: 0,
            ),
          ),
          pinActions: true,
          showTagManagement: false,
          onToggleFilter: (_) {},
          onReorder: (_, __) async {},
          onToggleSelectionMode: () => selected = true,
          sortMode: ShelfSortMode.recent,
          sortModeLabel: (ShelfSortMode mode) => mode.name,
          onSortModeChanged: (ShelfSortMode mode) => chosen = mode,
        ),
      ),
    );
    final Finder select = find.widgetWithIcon(
      IconButton,
      Icons.checklist_outlined,
    );
    final Finder sort = find.widgetWithIcon(IconButton, Icons.sort);
    final Offset before = tester.getCenter(sort);
    expect(tester.getCenter(select).dy, before.dy);
    expect(tester.getSize(select).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(sort).height, greaterThanOrEqualTo(44));
    await tester.drag(find.byType(ListView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(sort), before);
    await tester.tap(select);
    expect(selected, isTrue);
    await tester.tap(sort);
    await tester.pumpAndSettle();
    await tester.tap(find.text(ShelfSortMode.title.name));
    await tester.pumpAndSettle();
    expect(chosen, ShelfSortMode.title);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact sync strip preserves progress and collapses when idle', (
    WidgetTester tester,
  ) async {
    addTearDown(() {
      syncInProgress.value = false;
      syncProgress.value = null;
    });
    syncInProgress.value = true;
    syncProgress.value = const SyncProgress(
      phase: SyncPhase.dictionaries,
      itemIndex: 0,
      itemTotal: 2,
      title: 'Dictionary',
    );
    await tester.pumpWidget(host(const SyncProgressBanner(compact: true)));
    final double compactHeight =
        tester.getSize(find.byType(SyncProgressBanner)).height;
    expect(find.textContaining('Dictionary'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );
    await tester.pumpWidget(host(const SyncProgressBanner()));
    expect(
      tester.getSize(find.byType(SyncProgressBanner)).height,
      greaterThan(compactHeight),
    );
    syncInProgress.value = false;
    await tester.pump();
    expect(tester.getSize(find.byType(SyncProgressBanner)).height, 0);
  });
}
