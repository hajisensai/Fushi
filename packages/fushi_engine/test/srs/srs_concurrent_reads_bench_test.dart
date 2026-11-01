// 长读（全量同步冲突）进行中，短读（一张卡 / 一条笔记）的完成延迟，在真实库上量（手动跑；默认跳过）。
//
// FUSHI_SRS_REAL_DB=<srs.db 副本路径> dart test test/srs/srs_concurrent_reads_bench_test.dart
//
// 必须用副本：打开 store 可能做升级写入。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_test_storage.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? path = Platform.environment['FUSHI_SRS_REAL_DB'];

  test(
    '长读进行中的短读延迟',
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
      final QueryRow pick = await srs.db
          .customSelect(
            'SELECT id AS c, note_id AS n FROM srs_cards_cache '
            'LIMIT 1 OFFSET 500',
          )
          .getSingle();
      final String cardId = pick.read<String>('c');
      final String noteId = pick.read<String>('n');

      Future<int> ms(Future<Object?> Function() body) async {
        final Stopwatch sw = Stopwatch()..start();
        await body();
        return sw.elapsedMilliseconds;
      }

      Future<void> shortReads(String label) async {
        stdout.writeln(
          'BENCH $label cardRow=${await ms(() => store.cardRow(cardId))}ms '
          'note=${await ms(() => store.note(noteId))}ms '
          'cardDetail=${await ms(() => store.cardDetail(cardId))}ms',
        );
      }

      // 预热两轮（页缓存 / 语句缓存）。
      await shortReads('solo(warmup)');
      await shortReads('solo');
      final int longSolo = await ms(store.syncConflicts);
      stdout.writeln('BENCH syncConflicts(solo)=${longSolo}ms');

      for (int round = 0; round < 3; round++) {
        final Stopwatch longSw = Stopwatch()..start();
        bool longDone = false;
        final Future<int> long = store.syncConflicts().then((List<Object?> r) {
          longDone = true;
          return longSw.elapsedMilliseconds;
        });
        // 让长读先发出去、在执行器里跑起来。
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final Stopwatch shortSw = Stopwatch()..start();
        await store.cardRow(cardId);
        final int cardRowMs = shortSw.elapsedMilliseconds;
        await store.note(noteId);
        final int noteMs = shortSw.elapsedMilliseconds;
        final bool longStillRunning = !longDone;
        final int longMs = await long;
        stdout.writeln(
          'BENCH round$round during-long cardRow=${cardRowMs}ms '
          'cardRow+note=${noteMs}ms longStillRunningAfterShort=$longStillRunning '
          'syncConflicts=${longMs}ms',
        );
      }
    },
    skip: path == null ? '设 FUSHI_SRS_REAL_DB 才跑' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
