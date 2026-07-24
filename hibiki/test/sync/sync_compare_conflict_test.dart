import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'helpers/sync_compare_harness.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  /// Pumps the compare dialog over a caller-supplied [db] (so the test can seed
  /// books/positions/baselines first), waits for `_load` to settle.
  Future<void> pumpDialog(
    WidgetTester tester,
    HibikiDatabase db,
    FakeCompareSyncBackend fake, {
    bool conflictsOnly = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SyncCompareDialog(
              db: db,
              backend: fake,
              conflictsOnly: conflictsOnly,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('single-sided change is not a conflict (local == base)',
      (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);

    final EpubBookRow book = await seedCompareBook(db, 'BookA');
    // Local sat still at base 100; remote moved to 120 → only remote diverged.
    await seedCompareReaderPosition(db, book.bookKey,
        updatedAt: 100, fraction: 0.5);
    await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 100);

    final FakeCompareSyncBackend fake = FakeCompareSyncBackend(
      remoteBooks: <String, CompareRemoteBook>{
        'BookA': CompareRemoteBook.withProgress(
          folderId: 'folderA',
          timestampMs: 120,
          fraction: 0.6,
        ),
      },
    );
    await pumpDialog(tester, db, fake);

    expect(find.text('BookA'), findsOneWidget);
    // No conflict header — single-sided change resolves automatically.
    expect(find.text(t.sync_compare_conflicts), findsNothing);
  });

  testWidgets('both sides diverged from base is a conflict',
      (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);

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
    await pumpDialog(tester, db, fake);

    // Conflict section is rendered; the choice segmented button is present.
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    expect(find.text('BookA'), findsOneWidget);
  });

  testWidgets('conflictsOnly hides non-conflict books and dictionaries',
      (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);

    // Conflict book: both sides off base.
    final EpubBookRow conflictBook = await seedCompareBook(db, 'ConflictBook');
    await seedCompareReaderPosition(db, conflictBook.bookKey,
        updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(
        sanitizeTtuFilename('ConflictBook'), 'progress', 50);

    // Calm book: single-sided (local == base), resolves automatically.
    final EpubBookRow calmBook = await seedCompareBook(db, 'CalmBook');
    await seedCompareReaderPosition(db, calmBook.bookKey,
        updatedAt: 100, fraction: 0.5);
    await db.setSyncBaseline(sanitizeTtuFilename('CalmBook'), 'progress', 100);

    final FakeCompareSyncBackend fake = FakeCompareSyncBackend(
      remoteBooks: <String, CompareRemoteBook>{
        'ConflictBook': CompareRemoteBook.withProgress(
          folderId: 'folderC',
          timestampMs: 100,
          fraction: 0.4,
        ),
        'CalmBook': CompareRemoteBook.withProgress(
          folderId: 'folderK',
          timestampMs: 120,
          fraction: 0.6,
        ),
      },
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    expect(find.text('ConflictBook'), findsOneWidget);
    expect(find.text('CalmBook'), findsNothing);
  });

  testWidgets(
      'conflictsOnly Apply only syncs conflict books, not hidden non-conflict ones',
      (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);

    // Conflict book: both sides off base → manual choice required.
    final EpubBookRow conflictBook = await seedCompareBook(db, 'ConflictBook');
    await seedCompareReaderPosition(db, conflictBook.bookKey,
        updatedAt: 120, fraction: 0.6);
    await db.setSyncBaseline(
        sanitizeTtuFilename('ConflictBook'), 'progress', 50);

    // Calm book: single-sided local change (remote == base) → auto-export
    // direction, seeded as useLocal. It is HIDDEN in conflictsOnly mode, so
    // Apply must NOT touch its remote folder. This is the [Important] guard.
    final EpubBookRow calmBook = await seedCompareBook(db, 'CalmBook');
    await seedCompareReaderPosition(db, calmBook.bookKey,
        updatedAt: 200, fraction: 0.7);
    await db.setSyncBaseline(sanitizeTtuFilename('CalmBook'), 'progress', 100);

    final FakeCompareSyncBackend fake = FakeCompareSyncBackend(
      remoteBooks: <String, CompareRemoteBook>{
        'ConflictBook': CompareRemoteBook.withProgress(
          folderId: 'folderC',
          timestampMs: 100,
          fraction: 0.4,
        ),
        'CalmBook': CompareRemoteBook.withProgress(
          folderId: 'folderK',
          timestampMs: 100, // remote == base → single-sided, not a conflict.
          fraction: 0.5,
        ),
      },
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    // Only the conflict book is visible; Apply count reflects the single
    // conflict, not the hidden calm book.
    expect(find.text('ConflictBook'), findsOneWidget);
    expect(find.text('CalmBook'), findsNothing);

    // Resolve the conflict to export (use local), then Apply.
    await tester.tap(find.text(t.sync_compare_use_local).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    // Fake backend recorded an export ONLY for the conflict folder; the hidden
    // calm book's folder was never synced.
    expect(fake.exportedByFolder.keys, contains('folderC'));
    expect(fake.exportedByFolder.keys, isNot(contains('folderK')));
  });

  testWidgets('conflictsOnly with zero conflicts shows the empty state',
      (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);

    // A library with one non-conflict (single-sided) book and no conflicts.
    final EpubBookRow calmBook = await seedCompareBook(db, 'CalmBook');
    await seedCompareReaderPosition(db, calmBook.bookKey,
        updatedAt: 200, fraction: 0.7);
    await db.setSyncBaseline(sanitizeTtuFilename('CalmBook'), 'progress', 100);

    final FakeCompareSyncBackend fake = FakeCompareSyncBackend(
      remoteBooks: <String, CompareRemoteBook>{
        'CalmBook': CompareRemoteBook.withProgress(
          folderId: 'folderK',
          timestampMs: 100, // remote == base → single-sided, not a conflict.
          fraction: 0.5,
        ),
      },
    );
    await pumpDialog(tester, db, fake, conflictsOnly: true);

    // No phantom blank list: an explicit empty-state message is shown.
    expect(find.text(t.sync_compare_empty), findsOneWidget);
    expect(find.text('CalmBook'), findsNothing);
  });

  testWidgets('resolving a conflict via Apply writes the baseline',
      (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);

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
    await pumpDialog(tester, db, fake);

    expect(find.text(t.sync_compare_conflicts), findsOneWidget);

    // Pick "use local" (export) for the conflict, then Apply.
    await tester.tap(find.text(t.sync_compare_use_local).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    // Manual export ran (folder progress written) and the baseline advanced to
    // the local version — so the divergence no longer reads as a conflict.
    expect(fake.exportedByFolder['folderA']?.lastBookmarkModified, 120);
    expect(await db.getSyncBaseline(sanitizeTtuFilename('BookA'), 'progress'),
        120);
  });
}
