// 复习同步：一台设备同时用多个同步目录（BUG-3565 / BUG-3566），数据库副本这一侧。
//
// 引擎规则由 fushi_srs 的模拟器覆盖（内存副本）；这里钉数据库副本必须与之一致的部分：
// 冻结批次留存（srs_sent_batches）、按目录进度的持久化、转发（新落地 / S 变小进发件箱）、
// 旧版本本机状态（冻结中的批次存在 JSON 里）的迁移。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';
import 'support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000cc';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory cloudRoot;
  late Directory hostRoot;

  setUp(() {
    cloudRoot = Directory.systemTemp.createTempSync('fushi_srs_cloud_');
    hostRoot = Directory.systemTemp.createTempSync('fushi_srs_host_');
  });
  tearDown(() {
    cloudRoot.deleteSync(recursive: true);
    hostRoot.deleteSync(recursive: true);
  });

  Future<SrsDbStore> device(String id, {SrsStorage? storage}) async {
    final SrsStorage st = storage ?? await openTestSrsStorage();
    return SrsDbStore.open(
      db: st.db,
      core: st.core,
      profileUid: kProfile,
      deviceId: id,
    );
  }

  Future<SrsSyncReport> syncTo(SrsDbStore s, Directory root, String key) =>
      SrsSyncEngine(
        directory: SrsAssetStoreDirectory(
          store: LocalDirectoryAssetStore(root),
          profileUid: kProfile,
        ),
        directoryKey: key,
        replica: s,
      ).syncOnce();

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  String? expressionOf(SrsNoteView? n) =>
      n?.field(srsLapisFieldId(kProfile, 'Expression'));

  test('桥：只连云盘与只连 host 的设备经两边都连的设备互通；桥不换化身', () async {
    final SrsDbStore cloudOnly = await device('cloud');
    final SrsDbStore bridge = await device('bridge');
    final SrsDbStore hostOnly = await device('phone');
    final String fromCloud = await addNote(cloudOnly, '雪');
    final String fromPhone = await addNote(hostOnly, '雨');
    final String bridgeWriter = bridge.writerId;
    for (int round = 0; round < 4; round++) {
      expect((await syncTo(cloudOnly, cloudRoot, 'cloud')).error, isNull);
      final SrsSyncReport a = await syncTo(bridge, cloudRoot, 'cloud');
      final SrsSyncReport b = await syncTo(bridge, hostRoot, 'host');
      expect(a.reincarnated || b.reincarnated, isFalse);
      expect((await syncTo(hostOnly, hostRoot, 'host')).error, isNull);
    }
    expect(bridge.writerId, bridgeWriter);
    expect(expressionOf(await hostOnly.note(fromCloud)), '雪');
    expect(expressionOf(await cloudOnly.note(fromPhone)), '雨');
    // 之后的增量经转发接上。
    final String later = await addNote(cloudOnly, '霧');
    for (int round = 0; round < 3; round++) {
      await syncTo(cloudOnly, cloudRoot, 'cloud');
      await syncTo(bridge, cloudRoot, 'cloud');
      await syncTo(bridge, hostRoot, 'host');
      await syncTo(hostOnly, hostRoot, 'host');
    }
    expect(expressionOf(await hostOnly.note(later)), '霧');
  });

  test(
    '转发：已知事件只有 S 变小时才进发件箱（observeServerTimes / applyRemote，forward 开关）',
    () async {
      final SrsDbStore source = await device('source');
      final SrsDbStore relay = await device('relay');
      await addNote(source, '霜');
      expect((await syncTo(source, cloudRoot, 'cloud')).error, isNull);
      expect((await syncTo(relay, cloudRoot, 'cloud')).error, isNull);
      final Set<String> mine = <String>{
        for (final SrsEvent e in await relay.unpublishedEvents()) e.id,
      };
      final Map<String, int> known = await relay.exportServerTimes();
      final List<SrsEvent> remote = <SrsEvent>[
        for (final SrsEvent e in await relay.exportAll())
          if (!mine.contains(e.id) && known.containsKey(e.id)) e,
      ];
      expect(remote.length, greaterThanOrEqualTo(3));
      Future<Set<String>> outbox() async => <String>{
        for (final SrsEvent e in await relay.unpublishedEvents())
          if (!mine.contains(e.id)) e.id,
      };
      final SrsEvent a = remote[0], b = remote[1], c = remote[2];

      // S 不变 / 变大：不进发件箱（即使 forward）。
      await relay.observeServerTimes(<String, int>{
        a.id: known[a.id]!,
        b.id: known[b.id]! + 1000,
      }, forward: true);
      expect(await outbox(), isEmpty);
      // S 变小但没开 forward：只记 S，不进发件箱。
      await relay.observeServerTimes(<String, int>{a.id: known[a.id]! - 1000});
      expect(await outbox(), isEmpty);
      expect(
        (await relay.knownServerTimes(<String>[a.id]))[a.id],
        known[a.id]! - 1000,
      );
      // S 变小且 forward：进发件箱。
      await relay.observeServerTimes(<String, int>{
        b.id: known[b.id]! - 1000,
      }, forward: true);
      expect(await outbox(), <String>{b.id});
      // applyRemote：已在本机的事件，批次 S 更小且 forward 才转发；更大的不转发。
      await relay.applyRemote(
        <SrsEvent>[a],
        serverTimeMs: known[a.id]! + 5000,
        forward: true,
      );
      expect(await outbox(), <String>{b.id});
      await relay.applyRemote(
        <SrsEvent>[c],
        serverTimeMs: known[c.id]! - 1000,
        forward: true,
      );
      expect(await outbox(), <String>{b.id, c.id});
    },
  );

  test('按目录的进度与批次留存跨重新打开保留；两个目录都确认后不再留存', () async {
    final SrsStorage srsStorage = await openTestSrsStorage();
    SrsDbStore s = await device('a', storage: srsStorage);
    await syncTo(s, cloudRoot, 'cloud');
    await syncTo(s, hostRoot, 'host');
    await addNote(s, '雪');
    await syncTo(s, cloudRoot, 'cloud');
    final int no = (await s.loadSyncState()).nextBatchNo - 1;
    // host 目录同步过、还没确认这一批：留存着。
    expect(await s.sentBatch(s.writerId, no), isNotNull);

    s = await device('a', storage: srsStorage);
    final SrsSyncLocalState st = await s.loadSyncState();
    expect(st.directories.keys, unorderedEquals(<String>['cloud', 'host']));
    expect(st.directories['cloud']!.confirmedThrough, no);
    expect(st.directories['host']!.confirmedThrough, lessThan(no));
    expect(st.legacyDirectories, isFalse);

    final SrsSyncReport r = await syncTo(s, hostRoot, 'host');
    expect(r.reincarnated, isFalse);
    expect(r.snapshotWritten, isFalse, reason: '留存里有这一批，逐批补传');
    expect(await s.sentBatch(s.writerId, no), isNull, reason: '两个目录都已确认');
    final File inHost = File(
      <String>[
        hostRoot.path,
        kSrsSyncNamespace,
        kProfile,
        s.writerId,
        srsBatchName(no),
      ].join(Platform.pathSeparator),
    );
    expect(inHost.existsSync(), isTrue);
  });

  test('旧版本本机状态：冻结中的批次搬进留存表，同号同字节传出，next 越过它', () async {
    final SrsStorage srsStorage = await openTestSrsStorage();
    final SrsDbStore s = await device('old', storage: srsStorage);
    final String noteId = await addNote(s, '雪');
    // 造旧版本的现场：发件箱里的事件已冻结进第 1 批（标记为已发布），批次字节存在本机状态 JSON 里。
    final List<SrsEvent> pending = await s.unpublishedEvents();
    final Uint8List bytes = SrsBatch(
      writerId: s.writerId,
      no: 1,
      serverTimeMs: 1700000000000,
      events: pending,
    ).encode();
    await (srsStorage.db.update(srsStorage.db.srsEventLocal)
          ..where((t) => t.profileUid.equals(kProfile)))
        .write(const SrsEventLocalCompanion(outboxSeq: Value<int?>(null)));
    final SrsLocalStateRow row = await (srsStorage.db.select(
      srsStorage.db.srsLocalState,
    )..where((t) => t.profileUid.equals(kProfile))).getSingle();
    final Map<String, Object?> j = (jsonDecode(row.json) as Map)
        .cast<String, Object?>();
    j['sync'] = <String, Object?>{
      'next': 1,
      'cursors': <String, int>{},
      'frozen': base64Encode(bytes),
      'frozenIds': <String>[for (final SrsEvent e in pending) e.id],
      'snap': 0,
      'boot': false,
      'lastS': <String, int>{},
    };
    await srsStorage.db
        .into(srsStorage.db.srsLocalState)
        .insertOnConflictUpdate(
          SrsLocalStateCompanion.insert(
            profileUid: kProfile,
            json: jsonEncode(j),
          ),
        );

    // 旧版本已在这个目录建过本写入者目录（写过探针），上传第 1 批没等到确认就退出了。
    final Directory ownDir = Directory(
      <String>[
        cloudRoot.path,
        kSrsSyncNamespace,
        kProfile,
        s.writerId,
      ].join(Platform.pathSeparator),
    )..createSync(recursive: true);
    File(
      '${ownDir.path}${Platform.pathSeparator}$srsProbeName',
    ).writeAsBytesSync(<int>[1]);

    final SrsDbStore reopened = await device('old', storage: srsStorage);
    final SrsSyncLocalState st = await reopened.loadSyncState();
    expect(st.nextBatchNo, 2);
    expect(st.legacyDirectories, isTrue);
    expect(await reopened.sentBatch(reopened.writerId, 1), bytes);

    final SrsSyncReport r = await syncTo(reopened, cloudRoot, 'cloud');
    expect(r.error, isNull);
    expect(r.reincarnated, isFalse, reason: '目录里有本写入者：旧状态也不换化身');
    final File uploaded = File(
      <String>[
        cloudRoot.path,
        kSrsSyncNamespace,
        kProfile,
        reopened.writerId,
        srsBatchName(1),
      ].join(Platform.pathSeparator),
    );
    expect(uploaded.readAsBytesSync(), bytes);
    final SrsDbStore other = await device('other');
    await syncTo(other, cloudRoot, 'cloud');
    expect(expressionOf(await other.note(noteId)), '雪');
  });
}
