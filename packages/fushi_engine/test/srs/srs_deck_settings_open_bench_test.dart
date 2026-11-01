// 牌组设置页打开时的读路径（deckTree + 同步冲突）在真实库上的墙钟耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_REAL_DB=<srs.db 副本路径> dart test test/srs/srs_deck_settings_open_bench_test.dart
//
// 必须用副本：打开 store 可能做升级写入。
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_test_storage.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? path = Platform.environment['FUSHI_SRS_REAL_DB'];

  test(
    '牌组设置页打开读路径',
    () async {
      final TestSrs srs = await openTestSrsAt(path!, inline: false);
      final String uid =
          (await srs.db
                  .customSelect(
                    'SELECT profile_uid AS u FROM srs_entities '
                    "WHERE kind = 'deck' LIMIT 1",
                  )
                  .getSingle())
              .read<String>('u');
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'bench',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      Future<T> time<T>(String label, Future<T> Function() body) async {
        final Stopwatch sw = Stopwatch()..start();
        final T r = await body();
        stdout.writeln('BENCH $label=${sw.elapsedMilliseconds}ms');
        return r;
      }

      final SrsDeckTree tree = await time('deckTree(cold)', store.deckTree);
      await time('deckTree(warm)', store.deckTree);
      final String deckId = tree.decks.first.id;
      final int all = (await time(
        'syncConflicts(all)',
        store.syncConflicts,
      )).length;
      stdout.writeln('BENCH conflicts(all)=$all deck=$deckId');
      final int one = (await time(
        'syncConflicts(deck)',
        () =>
            store.syncConflicts(entity: (kind: SrsEntityKind.deck, id: deckId)),
      )).length;
      stdout.writeln('BENCH conflicts(deck)=$one');
    },
    skip: path == null ? '设 FUSHI_SRS_REAL_DB 才跑' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
