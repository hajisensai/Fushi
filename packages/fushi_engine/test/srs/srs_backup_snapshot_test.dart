import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_backup_snapshot.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000c3';

/// 自动备份不再占着 SRS 的写连接：快照在后台 isolate 里、srs.db 上另开的一条 Rust 只读连接里读
/// （[SrsCore.beginRead]，srs_backup_snapshot.dart）。这里用真实的文件库（WAL），走生产路径。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  int t = DateTime.utc(2026, 10, 23, 9).millisecondsSinceEpoch;
  late Directory tmp;
  late SrsStorage srs;
  late SrsDbStore store;
  late SrsBackupStore backups;

  setUp(() async {
    t = DateTime.utc(2026, 10, 23, 9).millisecondsSinceEpoch;
    tmp = await Directory.systemTemp.createTemp('srs_backup_snapshot_test_');
    srs = await SrsStorage.open(
      path: p.join(tmp.path, kSrsDatabaseFileName),
      inline: true,
    );
    store = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kProfile,
      deviceId: 'snap',
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-snap',
      ),
    );
    backups = SrsBackupStore(
      root: Directory(p.join(tmp.path, 'srs_backups')),
      profileUid: kProfile,
      mediaDir: Directory(p.join(tmp.path, 'srs_media', kProfile)),
    );
  });
  tearDown(() async {
    await srs.close();
    await tmp.delete(recursive: true);
  });

  Future<String> addNote(String text) => store.createNote(
    noteTypeId: store.lapisNoteTypeId,
    fieldsById: <String, String>{srsLapisFieldId(kProfile, 'Expression'): text},
  );

  Future<void> addReviewed(String text) async {
    final String card = (await store.cardsOfNote(
      await addNote(text),
    )).single.id;
    t += 60 * 1000;
    await store.answer(card, 3);
  }

  List<String> tmpLeftovers() => backups.profileDir.existsSync()
      ? backups.profileDir
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path))
            .where((String n) => n.endsWith('.tmp') || n.endsWith('.deflate'))
            .toList()
      : const <String>[];

  test('后台独立只读连接：备份内容、计数、指纹与写连接上读的逐项相同', () async {
    for (final String w in <String>['雪', '雨', '風']) {
      await addReviewed(w);
    }
    final List<String> lines = await store.exportCanonicalLines();
    final SrsBackupInfo info = await backups.create(
      store,
      kind: SrsBackupKind.manual,
      profileName: '日语',
      nowMs: t,
    );
    expect(info.manifest.fingerprint, await store.changeFingerprint());
    expect(info.manifest.eventCount, lines.length);
    final ({int notes, int cards, int reviews}) counts = await store
        .backupCounts();
    expect(info.manifest.noteCount, counts.notes);
    expect(info.manifest.cardCount, counts.cards);
    expect(info.manifest.reviewCount, 3);
    final SrsBackupArchive arch = await SrsBackupStore.read(info.file);
    try {
      expect(
        arch.events.map((SrsEvent e) => e.canonical()),
        unorderedEquals(lines),
      );
      expect(arch.serverTimes, await store.exportServerTimes());
    } finally {
      arch.close();
    }
    expect(tmpLeftovers(), isEmpty);
  });

  test('快照拿到后主连接照常写，写入不进这份快照', () async {
    await addReviewed('雪');
    final List<String> before = await store.exportCanonicalLines();
    final String events = p.join(tmp.path, 'events.tmp');
    final String times = p.join(tmp.path, 'times.tmp');
    final SrsBackupSnapshotReader reader = await SrsBackupSnapshotReader.start(
      core: srs.core,
      profileUid: kProfile,
      eventsPath: events,
      serverTimesPath: times,
      pageSize: 1,
    );
    // 读事务开着（快照已定）时主连接写入不受阻；以前同一连接上的长事务会让它排到读完之后。
    await addReviewed('雨').timeout(const Duration(seconds: 5));
    final ({int eventCount, SrsBackupCounts counts}) r = await reader.done;
    expect(r.eventCount, before.length);
    expect(r.counts.notes, 1);
    expect(r.counts.reviews, 1);
    expect(
      LineSplitter.split(await File(events).readAsString()).toList(),
      unorderedEquals(before),
    );
    expect(
      (await store.exportCanonicalLines()).length,
      greaterThan(before.length),
    );
  });

  test('叫停：后台读完当前页就回滚，create 抛 SrsBackupCancelled、不留暂存文件', () async {
    for (final String w in <String>['雪', '雨', '風', '花']) {
      await addReviewed(w);
    }
    final String events = p.join(tmp.path, 'events.tmp');
    final SrsBackupSnapshotReader reader = await SrsBackupSnapshotReader.start(
      core: srs.core,
      profileUid: kProfile,
      eventsPath: events,
      serverTimesPath: p.join(tmp.path, 'times.tmp'),
      pageSize: 1,
    );
    reader.cancel();
    await expectLater(reader.done, throwsA(isA<SrsSnapshotCancelled>()));

    // create 的叫停：shouldStop 一开始就为 true → 不开读、不出文件。
    await expectLater(
      backups.create(
        store,
        kind: SrsBackupKind.auto,
        profileName: '日语',
        nowMs: t,
        shouldStop: () => true,
      ),
      throwsA(isA<SrsBackupCancelled>()),
    );
    expect(tmpLeftovers(), isEmpty);
    expect(await backups.list(), isEmpty);
    // 叫停后主连接照常可写（读连接已关、没有残留的读事务）。
    await addReviewed('月').timeout(const Duration(seconds: 5));
  });

  test('开不了只读会话（库已关）：start 原样抛错，不挂起', () async {
    final SrsCore closed = SrsCore.open(p.join(tmp.path, 'closed.db'))..close();
    await expectLater(
      SrsBackupSnapshotReader.start(
        core: closed,
        profileUid: kProfile,
        eventsPath: p.join(tmp.path, 'e.tmp'),
        serverTimesPath: p.join(tmp.path, 's.tmp'),
      ).timeout(const Duration(seconds: 10)),
      throwsA(isA<StateError>()),
    );
  });
}
