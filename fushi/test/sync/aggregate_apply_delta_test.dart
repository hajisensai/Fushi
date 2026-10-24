import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';

// 聚合同步写回只落「真正变化的行」：
//  * 合并结果与本地内容相等（与 PUT 侧指纹同一「顺序无关」口径）→ 不进写回锁、
//    不发任何写 SQL；
//  * 远端只多一条段 → 只写那一条（一条批量语句、一个参数组），其它家族零写入；
//  * 收藏族应用有跨行副作用（墓碑删本地行），变化时仍整族下发，删除照常生效。

/// 记录每条写语句（含批量语句的每组参数）。
class _WriteLog extends QueryInterceptor {
  final List<String> writes = <String>[];
  int batchedArgs = 0;
  bool on = false;

  void reset() {
    writes.clear();
    batchedArgs = 0;
  }

  @override
  Future<int> runInsert(QueryExecutor e, String s, List<Object?> a) {
    if (on) writes.add(s);
    return e.runInsert(s, a);
  }

  @override
  Future<int> runUpdate(QueryExecutor e, String s, List<Object?> a) {
    if (on) writes.add(s);
    return e.runUpdate(s, a);
  }

  @override
  Future<int> runDelete(QueryExecutor e, String s, List<Object?> a) {
    if (on) writes.add(s);
    return e.runDelete(s, a);
  }

  @override
  Future<void> runBatched(QueryExecutor e, BatchedStatements b) {
    if (on) {
      writes.addAll(b.statements);
      batchedArgs += b.arguments.length;
    }
    return e.runBatched(b);
  }
}

StudySegmentsCompanion _seg(String uid, {String key = 'v1', int at = 1000}) =>
    StudySegmentsCompanion.insert(
      uid: uid,
      deviceId: 'dev',
      mediaKind: kActivityMediaVideo,
      mediaKey: key,
      title: 'T',
      startAt: at,
      endAt: at + 100,
      dateKey: '2026-08-29',
      hour: 12,
      durationMs: const Value(60000),
      updatedAt: at + 100,
    );

Future<(FushiDatabase, _WriteLog)> _seededDb() async {
  final _WriteLog log = _WriteLog();
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory().interceptWith(log)),
  );
  addTearDown(db.close);
  final int id = await db.insertProfile(
    ProfilesCompanion.insert(name: 'Default', createdAt: 1, updatedAt: 1),
  );
  await db.setPref(kActiveProfileIdPrefKey, id.toString());
  for (int i = 0; i < 20; i++) {
    await db.upsertStudySegment(_seg('s$i', key: 'v${i % 3}', at: 1000 + i));
  }
  await db.upsertStudySegmentTombstone(
    mediaKind: kActivityMediaVideo,
    mediaKey: 'gone',
    deletedAt: 500,
  );
  await db.setReadingStatistic(
    ReadingStatisticsCompanion.insert(
      title: 'Book',
      dateKey: '2026-08-29',
      charactersRead: 100,
      readingTimeMs: 1000,
      lastStatisticModified: 1,
    ),
  );
  await db.setMiningCount(sourceType: 'book', dateKey: '2026-08-29', count: 3);
  await db.setLookupCount(
    bookKey: 'b1',
    title: 'Book',
    sourceType: 'book',
    dateKey: '2026-08-29',
    count: 7,
  );
  await db.addFavoriteWord(
    expression: 'w',
    reading: 'r',
    glossary: 'g',
    sourceType: 'book',
    dateKey: '2026-08-29',
  );
  return (db, log);
}

/// 把 JSON 里各家族列表倒序：模拟对端数据库查出来的行序不同。
Map<String, Object?> _reversed(Map<String, Object?> json) => <String, Object?>{
  for (final MapEntry<String, Object?> e in json.entries)
    e.key: e.value is List ? (e.value as List).reversed.toList() : e.value,
};

void main() {
  test('稳态（两端内容一致、行序不同）：不进写回锁、零写 SQL、不 PUT', () async {
    final (FushiDatabase db, _WriteLog log) = await _seededDb();
    int lockCalls = 0;
    final AggregateSyncService svc = AggregateSyncService(
      db,
      localApplyLock: (Future<void> Function() body) {
        lockCalls++;
        return body();
      },
    );
    final Map<String, Object?> remote = _reversed(
      (await svc.materializeLocalSnapshot()).toJson(),
    );

    int pushes = 0;
    log.on = true;
    await svc.syncOverClient(
      fetchRemote: () async => remote,
      pushMerged: (Object _) async => pushes++,
    );
    await svc.syncOverClient(
      fetchRemote: () async => remote,
      pushMerged: (Object _) async => pushes++,
    );
    log.on = false;

    expect(lockCalls, 0);
    expect(log.writes, isEmpty);
    expect(pushes, 0);
  });

  test('host 侧 foldIntoLocal 收到与本地等价的快照：零写 SQL', () async {
    final (FushiDatabase db, _WriteLog log) = await _seededDb();
    final AggregateSyncService svc = AggregateSyncService(db);
    final AggregateSnapshot same = AggregateSnapshot.fromJson(
      _reversed((await svc.materializeLocalSnapshot()).toJson()),
    );
    log.on = true;
    await svc.foldIntoLocal(same);
    log.on = false;
    expect(log.writes, isEmpty);
  });

  test('远端只多一条新段：只写那一条，其它统计家族零写入，结果正确', () async {
    final (FushiDatabase db, _WriteLog log) = await _seededDb();
    int lockCalls = 0;
    final AggregateSyncService svc = AggregateSyncService(
      db,
      localApplyLock: (Future<void> Function() body) {
        lockCalls++;
        return body();
      },
    );
    final AggregateSnapshot local = await svc.materializeLocalSnapshot();
    final StudySegmentRecord template = local.studySegments.first;
    final Map<String, Object?> newSeg = template.toJson()
      ..['uid'] = 'remote-new'
      ..['deviceId'] = 'peer'
      ..['startAt'] = 5000
      ..['endAt'] = 5100
      ..['updatedAt'] = 5100;
    final Map<String, Object?> remote = local.toJson()
      ..['studySegments'] = <Object?>[
        ...local.toJson()['studySegments']! as List<Object?>,
        newSeg,
      ];

    final List<Object> pushed = <Object>[];
    log.on = true;
    await svc.syncOverClient(
      fetchRemote: () async => remote,
      pushMerged: (Object j) async => pushed.add(j),
    );
    log.on = false;

    expect(lockCalls, 1);
    final List<String> segmentWrites = <String>[
      for (final String s in log.writes)
        if (s.startsWith('INSERT') && s.contains('"study_segments"')) s,
    ];
    expect(segmentWrites, hasLength(1), reason: log.writes.join('\n'));
    expect(log.batchedArgs, 1);
    for (final String table in <String>[
      'reading_statistics',
      'mining_statistics',
      'lookup_mining_counters',
      'favorite_words',
      'video_watch_statistics',
      'reading_hourly_logs',
      'video_hourly_logs',
    ]) {
      expect(
        log.writes.where((String s) => s.contains('"$table"')),
        isEmpty,
        reason: table,
      );
    }

    final List<StudySegmentRow> rows = await db.getStudySegments(
      allProfiles: true,
    );
    expect(rows, hasLength(21));
    final StudySegmentRow landed = rows.singleWhere(
      (StudySegmentRow r) => r.uid == 'remote-new',
    );
    expect(landed.deviceId, 'peer');
    expect(landed.startAt, 5000);
    expect(landed.durationMs, 60000);
    // 远端已含本地全部 + 新段 = merged，按指纹跳过 PUT。
    expect(pushed, isEmpty);

    // 下一轮回到稳态：不再写。
    log
      ..reset()
      ..on = true;
    await svc.syncOverClient(
      fetchRemote: () async => remote,
      pushMerged: (Object j) async => pushed.add(j),
    );
    log.on = false;
    expect(lockCalls, 1);
    expect(log.writes, isEmpty);
  });

  test('被墓碑压住的段不因增量写回漏判（批量 upsert 仍按碑跳过）', () async {
    final (FushiDatabase db, _WriteLog _) = await _seededDb();
    final AggregateSyncService svc = AggregateSyncService(db);
    final AggregateSnapshot local = await svc.materializeLocalSnapshot();
    final Map<String, Object?> base = local.studySegments.first.toJson();
    AggregateSnapshot incomingWith(String uid, int startAt) =>
        AggregateSnapshot(
          studySegments: <StudySegmentRecord>[
            StudySegmentRecord.fromJson(<String, Object?>{
              ...base,
              'uid': uid,
              'mediaKey': 'gone',
              'startAt': startAt,
              'endAt': startAt + 10,
              'updatedAt': startAt + 10,
            })!,
          ],
        );
    // 碑 deletedAt=500：startAt 400 被压、600 存活（BUG-2214 语义不变）。
    await svc.foldIntoLocal(incomingWith('old', 400));
    await svc.foldIntoLocal(incomingWith('new', 600));
    final Set<String> uids = <String>{
      for (final StudySegmentRow r in await db.getStudySegments(
        allProfiles: true,
      ))
        r.uid,
    };
    expect(uids.contains('old'), isFalse);
    expect(uids.contains('new'), isTrue);
  });

  test('收藏族有变化时整族下发：本地被墓碑压制的收藏词照常被删', () async {
    final (FushiDatabase db, _WriteLog _) = await _seededDb();
    final FavoriteWordRow word = (await db.getAllFavoriteWords()).single;
    // 墓碑严格新于收藏（绕过 addFavoriteWord 的清碑，构造「本地自相矛盾」态）。
    await db.writeSyncDeletionTombstone(
      SyncTombstoneKind.favoriteword.dbValue,
      FushiDatabase.favoriteWordItemKey(
        word.expression,
        word.reading,
        word.sourceType,
      ),
      word.createdAt + 1,
    );
    final AggregateSyncService svc = AggregateSyncService(db);
    // 与收藏无关的一条入站数据（foldIntoLocal 对空快照早退）。
    await svc.foldIntoLocal(
      const AggregateSnapshot(
        miningStats: <MiningRecord>[
          MiningRecord(sourceType: 'video', dateKey: '2026-08-30', count: 1),
        ],
      ),
    );
    expect(await db.getAllFavoriteWords(), isEmpty);
  });

  test('localDelta 与 PUT 侧指纹同口径：指纹相等 ⇔ 无增量', () async {
    final (FushiDatabase db, _WriteLog _) = await _seededDb();
    final AggregateSyncService svc = AggregateSyncService(db);
    final AggregateSnapshot local = await svc.materializeLocalSnapshot();
    final AggregateSnapshot reordered = AggregateSnapshot.fromJson(
      _reversed(local.toJson()),
    );
    expect(
      AggregateSyncService.unorderedSnapshotFingerprint(reordered.toJson()),
      AggregateSyncService.unorderedSnapshotFingerprint(local.toJson()),
    );
    expect(AggregateSyncService.localDelta(reordered, local), isNull);

    final AggregateSnapshot bumped = AggregateSnapshot.fromJson(
      local.toJson()
        ..['miningStats'] = <Object?>[
          const MiningRecord(
            sourceType: 'book',
            dateKey: '2026-08-29',
            count: 9,
          ).toJson(),
        ],
    );
    expect(
      AggregateSyncService.unorderedSnapshotFingerprint(bumped.toJson()),
      isNot(AggregateSyncService.unorderedSnapshotFingerprint(local.toJson())),
    );
    final AggregateSnapshot? delta = AggregateSyncService.localDelta(
      bumped,
      local,
    );
    expect(delta, isNotNull);
    expect(delta!.miningStats.single.count, 9);
    expect(delta.studySegments, isEmpty);
    expect(delta.readingStats, isEmpty);
    expect(delta.favoriteWords, isEmpty);
  });
}
