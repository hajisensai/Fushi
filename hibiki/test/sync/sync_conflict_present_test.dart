import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'helpers/sync_compare_harness.dart';

/// One genuine fork (both sides off baseline) → SyncCompareDialog renders it as
/// a conflict.
List<SyncConflict> _oneConflict() => <SyncConflict>[
      SyncConflict(
        assetKey: sanitizeTtuFilename('BookA'),
        dimension: 'progress',
        title: 'BookA',
        localVersion: 120,
        remoteVersion: 100,
      ),
    ];

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// Seeds a forked BookA (both sides off baseline 50) so the conflictsOnly
  /// dialog has a real conflict row to render.
  Future<(HibikiDatabase, FakeCompareSyncBackend)> seedForkedLibrary() async {
    final HibikiDatabase db = memCompareDb();
    final EpubBookRow book = await seedCompareBook(db, 'BookA');
    await seedCompareReaderPosition(db, book.bookKey,
        updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 50);
    final FakeCompareSyncBackend fake = FakeCompareSyncBackend(
      remoteBooks: <String, CompareRemoteBook>{
        'BookA': CompareRemoteBook.withProgress(
          folderId: 'folderA',
          timestampMs: 100,
          fraction: 0.4,
        ),
      },
    );
    return (db, fake);
  }

  /// Pumps a real app with an attached navigatorKey, then fires
  /// `prompter.present(...)` over that key and settles. The MaterialApp must be
  /// pumped (navigator attached) before present runs so
  /// `navigatorKey.currentContext` is non-null.
  ///
  /// [body] is started but NOT awaited to completion: when present DOES show the
  /// conflict dialog, its future only resolves once the (barrier-undismissible)
  /// dialog is popped, so awaiting it here would deadlock pumpAndSettle. The
  /// caller pops the dialog after asserting (see showing tests). When present
  /// suppresses the dialog, its future completes immediately and there is
  /// nothing left pending.
  Future<void> pumpAndPresent(
    WidgetTester tester, {
    required SyncConflictPrompter prompter,
    required GlobalKey<NavigatorState> navKey,
    required Future<void> Function() body,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    unawaited(body());
    await tester.pumpAndSettle();
  }

  /// Pops the open conflict dialog with a null result (user cancelled) and
  /// settles, letting the pending `present` future resolve so no work is left
  /// dangling after the test body returns.
  Future<void> dismissDialog(
    WidgetTester tester,
    GlobalKey<NavigatorState> navKey,
  ) async {
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('manual source presents the conflict resolution dialog',
      (WidgetTester tester) async {
    final (HibikiDatabase db, FakeCompareSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.manual,
        inBook: true, // manual ignores in-book.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsOneWidget);
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);

    await dismissDialog(tester, navKey);
  });

  testWidgets('auto source while in-book does NOT present',
      (WidgetTester tester) async {
    final (HibikiDatabase db, FakeCompareSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.auto,
        inBook: true, // auto + in-book is suppressed.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsNothing);
  });

  testWidgets('background source never presents', (WidgetTester tester) async {
    final (HibikiDatabase db, FakeCompareSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.background,
        inBook: false,
      ),
    );

    expect(find.byType(SyncCompareDialog), findsNothing);
  });

  testWidgets('auto source out-of-book presents the dialog',
      (WidgetTester tester) async {
    final (HibikiDatabase db, FakeCompareSyncBackend fake) =
        await seedForkedLibrary();
    addTearDown(db.close);
    final SyncConflictPrompter prompter = SyncConflictPrompter();
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    await pumpAndPresent(
      tester,
      prompter: prompter,
      navKey: navKey,
      body: () => prompter.present(
        navigatorKey: navKey,
        db: db,
        backend: fake,
        conflicts: _oneConflict(),
        source: ConflictSource.auto,
        inBook: false, // out of book → auto can prompt.
      ),
    );

    expect(find.byType(SyncCompareDialog), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);

    await dismissDialog(tester, navKey);
  });
}
