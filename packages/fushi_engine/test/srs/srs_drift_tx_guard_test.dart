// 收掉 Dart 写路径的第 1 步：内核 Drift 事务守卫（native/fushi_fsrs/src/store/drift_guard.rs）只计数、不拦。
// Drift 在写连接上开着事务时来的 sync2 命令按 Join / ReadVisible / Reject 分类记数；后面的步骤靠这些计数验收
// 「Join 集合缩小了」。这里钉住：计数读得到、只在 Drift 事务开着时记、行为不变；Dart 的改投影命令集合与内核同一组。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const String kUid = '01928c3e-0000-7000-8000-00000000d71f';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> open() async {
    final SrsStorage storage = await openTestSrsStorage();
    return SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: kUid,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      fallbackRolloverHour: () => 4,
    );
  }

  test('本机写入在 Drift 事务里发的命令记为 Join；事务外的只读命令不计；行为不变', () async {
    final SrsDbStore s = await open();
    await s.debugDriftTxGuardHits(reset: true);

    final String noteId = await s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{srsLapisFieldId(kUid, 'Expression'): '食べる'},
    );
    final String card = (await s.cardsOfNote(noteId)).single.id;
    await s.answer(card, 3);
    await s.sync2Checkpoint('manual', 'manual');
    // 不排写锁的只读命令（不在 Drift 事务里）：不计。
    await s.sync2Status();

    final Map<String, Map<String, int>> hits = await s.debugDriftTxGuardHits(
      reset: true,
    );
    expect(
      hits.keys,
      unorderedEquals(<String>['join', 'readVisible', 'reject']),
    );
    expect(hits['join']!['apply'], greaterThanOrEqualTo(2));
    expect(hits['join']!['checkpoint'], 1);
    expect(hits['join']!.containsKey('status'), isFalse);
    expect(hits['readVisible']!.containsKey('status'), isFalse);
    expect(hits['reject'], isEmpty, reason: '$hits');
    // reset 之后清零。
    expect(await s.debugDriftTxGuardHits(), <String, Map<String, int>>{
      'join': <String, int>{},
      'readVisible': <String, int>{},
      'reject': <String, int>{},
    });
    // 写入照常落库（守卫不拦）。
    expect((await s.cardRow(card))!.lastLogId, isNotNull);
  });

  test('重建缓存的 Drift 事务里发的 rebuild_caches 记为 Join', () async {
    final SrsDbStore s = await open();
    await s.debugDriftTxGuardHits(reset: true);
    await s.rebuildCaches();
    final Map<String, Map<String, int>> hits = await s.debugDriftTxGuardHits();
    expect(hits['join'], <String, int>{'rebuild_caches': 1});
    expect(hits['reject'], isEmpty);
  });

  test('Dart 的改投影命令集合与内核 PROJECTING_OPS 同一组', () {
    final String src = File(
      '../../native/fushi_fsrs/src/store/ffi.rs',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int from = src.indexOf('const PROJECTING_OPS: &[&str] = &[');
    expect(from, greaterThanOrEqualTo(0));
    final String body = src.substring(from, src.indexOf('];', from));
    final Set<String> rust = <String>{
      for (final RegExpMatch m in RegExp(r'"([a-z_0-9]+)"').allMatches(body))
        m.group(1)!,
    };
    expect(rust, isNotEmpty);
    expect(SrsDbStore.kSrsSync2ProjectingOps, rust);
  });
}
