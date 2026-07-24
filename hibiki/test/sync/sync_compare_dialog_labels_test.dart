import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'helpers/sync_compare_harness.dart';

// TODO-703: the compare dialog footer was reworded for clarity --
//   * the plain dismiss button now reads t.sync_compare_close (a dedicated
//     key), no longer the shared t.dialog_done;
//   * the primary action keeps key sync_compare_apply but its value reads
//     Sync now (N).
// These widget tests pin both the labels AND the behavior: Close must only
// pop (never run a sync); Sync-now must run _applyChoices (an export here).

// Seeds one book whose local and remote both diverged from base (a conflict),
// so the dialog renders entries and the primary action button is present.
Future<FakeCompareSyncBackend> _seedConflict(HibikiDatabase db) async {
  final EpubBookRow book = await seedCompareBook(db, 'BookA');
  await seedCompareReaderPosition(db, book.bookKey,
      updatedAt: 120, fraction: 0.6);
  await db.setSyncBaseline(sanitizeTtuFilename('BookA'), 'progress', 50);
  return FakeCompareSyncBackend(
    remoteBooks: <String, CompareRemoteBook>{
      'BookA': CompareRemoteBook.withProgress(
        folderId: 'folderA',
        timestampMs: 100,
        fraction: 0.4,
      ),
    },
  );
}

Future<void> _pumpDialog(
  WidgetTester tester,
  HibikiDatabase db,
  FakeCompareSyncBackend fake,
) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => SyncCompareDialog(db: db, backend: fake),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
      'footer uses sync_compare_close (not shared dialog_done) and tapping it '
      'only pops, no sync runs', (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);
    final FakeCompareSyncBackend fake = await _seedConflict(db);

    await _pumpDialog(tester, db, fake);

    // Dialog is up with a conflict entry.
    expect(find.text(t.sync_compare_conflicts), findsOneWidget);
    // The dismiss button reads the new dedicated close key, not dialog_done.
    expect(find.text(t.sync_compare_close), findsOneWidget);
    expect(find.text(t.dialog_done), findsNothing);

    // Tapping Close pops the dialog and runs NO sync (no export captured).
    await tester.tap(find.text(t.sync_compare_close));
    await tester.pumpAndSettle();
    expect(find.text(t.sync_compare_conflicts), findsNothing,
        reason: 'Close must pop the compare dialog');
    expect(fake.exportedByFolder, isEmpty,
        reason: 'Close is a pure dismiss, it must not trigger a sync');
  });

  testWidgets(
      'primary action reads sync_compare_apply(count) and tapping it runs '
      '_applyChoices (an export)', (WidgetTester tester) async {
    final HibikiDatabase db = memCompareDb();
    addTearDown(db.close);
    final FakeCompareSyncBackend fake = await _seedConflict(db);

    await _pumpDialog(tester, db, fake);

    // Resolve the conflict (use local, export direction) so Apply is enabled
    // and its count reflects the single actionable entry.
    await tester.tap(find.text(t.sync_compare_use_local).first);
    await tester.pumpAndSettle();

    // The primary button carries the sync_compare_apply key (value Sync now).
    expect(find.text(t.sync_compare_apply(count: 1)), findsOneWidget);

    await tester.tap(find.text(t.sync_compare_apply(count: 1)));
    await tester.pumpAndSettle();

    // _applyChoices truly ran: the conflict folder progress was exported.
    expect(fake.exportedByFolder.keys, contains('folderA'),
        reason: 'Sync now must trigger _applyChoices (the manual export)');
  });
}
