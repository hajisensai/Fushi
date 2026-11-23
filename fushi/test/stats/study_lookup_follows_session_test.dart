import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi/src/stats/study_lookup_recorder.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:test/test.dart';

// 拍板台 4KOWK3c2mn 方案 b（2026-11-23）：查词与字数 / 时长同一小时粒度，编辑会话
// 改日期时查词随会话一起挪。
//
// 契约（从真库出发、走页面同一条读写路径）：
//  * 查词归属的媒体有在跑的 StudyClock 时，查词记进它的当前段（`study_segments.lookups`），
//    不再写按天计数表；时钟停着 / 无书查词照旧记 `lookup_mining_counters`（互斥、不双计）；
//  * 空闲门刚封段时查词记回同一统计日最近封的段（否则 0 时长段不进会话流、挪不走）；
//  * 统计读取面（`loadStatFacts(includeCounters)`）把两处相加；
//  * `applyStudySessionEdit` 改日期后，这次会话的查词落到新日期；删会话随段写零；
//  * 同步 wire 带上 `lookups`（additive，0 不发）。

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// 起一只写真库的书时钟（时刻可控）。
StudyClock _clock(
  FushiDatabase db,
  DateTime Function() now, {
  String key = 'b1',
  Duration? idleTimeout,
}) {
  final StudyClock clock = StudyClock(
    database: db,
    mediaKind: kActivityMediaBook,
    mediaKey: key,
    title: 'T',
    format: 'epub',
    idleTimeout: idleTimeout,
    deviceId: () async => 'dev',
    now: now,
  );
  addTearDown(clock.stop);
  return clock;
}

Future<int> _counterLookups(FushiDatabase db) async {
  int total = 0;
  for (final LookupMiningCounterRow r
      in await db.getAllLookupMiningCounters()) {
    total += r.lookupCount;
  }
  return total;
}

Map<String, int> _lookupsByDay(StatCounterFacts counters) {
  final Map<String, int> out = <String, int>{};
  for (final (String day, int n) in counters.lookupEvents()) {
    out[day] = (out[day] ?? 0) + n;
  }
  return out;
}

Future<void> _lookup(FushiDatabase db, String? key, DateTime at) =>
    recordStudyLookup(
      db,
      bookKey: key,
      title: key == null ? '' : 'T',
      sourceType: kStatSourceBook,
      at: at,
    );

void main() {
  setUp(() {
    debugClearRetiredStudySegmentUids();
    debugClearRunningStudyClocks();
  });
  tearDown(() {
    debugClearRetiredStudySegmentUids();
    debugClearRunningStudyClocks();
  });

  test('时钟在跑：查词记进当前段，不写按天计数表', () async {
    final FushiDatabase db = await _openDb();
    DateTime now = DateTime(2026, 9, 8, 10);
    final StudyClock clock = _clock(db, () => now)..start();
    now = now.add(const Duration(minutes: 5));
    await _lookup(db, 'b1', now);
    await _lookup(db, 'b1', now);
    await clock.stop();

    final List<StudySegmentRow> segs = await db.getStudySegments();
    expect(segs, hasLength(1));
    expect(segs.single.lookups, 2);
    expect(await _counterLookups(db), 0, reason: '两处互斥，段里记了计数表就不记');
  });

  test('时钟停着 / 别的媒体在跑 / 无书查词：照旧记按天计数表', () async {
    final FushiDatabase db = await _openDb();
    final DateTime now = DateTime(2026, 9, 8, 10);
    final StudyClock stopped = _clock(db, () => now);
    expect(stopped.isRunning, isFalse);
    _clock(db, () => now, key: 'other').start();

    await _lookup(db, 'b1', now);
    await _lookup(db, null, now);
    expect(await _counterLookups(db), 2);
    expect(
      (await db.getStudySegments()).where((StudySegmentRow r) => r.lookups > 0),
      isEmpty,
    );
  });

  test('空闲门封段后查词记回同一统计日最近封的段，不另开 0 时长段', () async {
    final FushiDatabase db = await _openDb();
    DateTime now = DateTime(2026, 9, 8, 10);
    final StudyClock clock = _clock(
      db,
      () => now,
      idleTimeout: const Duration(minutes: 1),
    )..start();
    now = now.add(const Duration(seconds: 30));
    await clock.flushNow();
    // 停在这一页 5 分钟没有输入（查词不喂空闲门）：段在空闲到期点被封。
    now = now.add(const Duration(minutes: 5));
    expect(clock.addLookup(), isTrue);
    await clock.stop();

    final List<StudySegmentRow> segs = await db.getStudySegments();
    expect(segs, hasLength(1), reason: '查词并进被封的段，不多出一条 0 时长段');
    expect(segs.single.lookups, 1);
    expect(segs.single.durationMs, greaterThan(0));
  });

  test('写穿：查词当场落库，不等下一 tick / flush', () async {
    final FushiDatabase db = await _openDb();
    DateTime now = DateTime(2026, 9, 8, 10);
    final StudyClock clock = _clock(db, () => now)..start();
    now = now.add(const Duration(minutes: 2));
    await _lookup(db, 'b1', now);
    await pumpEventQueue();

    final List<StudySegmentRow> segs = await db.getStudySegments();
    expect(segs, hasLength(1), reason: '统计侧栏随查随见；进程被杀也不丢');
    expect(segs.single.lookups, 1);
    expect(clock.isRunning, isTrue);
  });

  test('空闲封掉的段已随会话删除退役：查词不记进它（会被丢弃），另开新段', () async {
    final FushiDatabase db = await _openDb();
    DateTime now = DateTime(2026, 9, 8, 10);
    final StudyClock clock = _clock(
      db,
      () => now,
      idleTimeout: const Duration(minutes: 1),
    )..start();
    now = now.add(const Duration(seconds: 30));
    await clock.flushNow();
    now = now.add(const Duration(minutes: 5));
    await clock.flushNow();
    final String sealedUid = (await db.getStudySegments()).single.uid;
    retireStudySegmentUids(<String>[sealedUid]);

    expect(clock.addLookup(), isTrue);
    await clock.stop();

    final List<StudySegmentRow> segs = await db.getStudySegments();
    expect(
      segs.firstWhere((StudySegmentRow r) => r.uid == sealedUid).lookups,
      0,
    );
    expect(
      segs.where((StudySegmentRow r) => r.uid != sealedUid).single.lookups,
      1,
      reason: '退役段的写会被丢弃，查词必须落到别的段上',
    );
  });

  test('编辑会话改日期：查词随会话挪到新日期；读取面两处相加', () async {
    final FushiDatabase db = await _openDb();
    DateTime now = DateTime(2026, 9, 8, 10);
    final StudyClock clock = _clock(db, () => now)..start();
    now = now.add(const Duration(minutes: 10));
    await _lookup(db, 'b1', now);
    clock.addChars(300);
    now = now.add(const Duration(minutes: 10));
    await clock.stop();
    // 同一天另有一次时钟没在跑时的查词（按天计数表，不随会话挪）。
    await _lookup(db, 'b1', now);

    final String from = FushiDatabase.statDateKeyOf(DateTime(2026, 9, 8, 10));
    final String to = FushiDatabase.statDateKeyOf(DateTime(2026, 9, 1, 10));
    StatFacts facts = await loadStatFacts(db, includeCounters: true);
    expect(_lookupsByDay(facts.counters), <String, int>{from: 2});

    final StudySession session = facts.sessions.single;
    await applyStudySessionEdit(
      db,
      session,
      StudySessionEdit(date: DateTime(2026, 9, 1)),
    );

    facts = await loadStatFacts(db, includeCounters: true);
    expect(_lookupsByDay(facts.counters), <String, int>{
      from: 1,
      to: 1,
    }, reason: '会话里的那次查词跟着字数 / 时长挪到 9/1，时钟外那次留在原日');
  });

  test('删会话：段里的查词随段写零', () async {
    final FushiDatabase db = await _openDb();
    DateTime now = DateTime(2026, 9, 8, 10);
    final StudyClock clock = _clock(db, () => now)..start();
    // 窗口都在 120s 断档门以内（真实时钟每 60s 一个 tick），段有时长、进会话流。
    now = now.add(const Duration(seconds: 50));
    expect(clock.addLookup(), isTrue);
    now = now.add(const Duration(seconds: 50));
    await clock.stop();

    final StatFacts facts = await loadStatFacts(db, includeCounters: true);
    await deleteStudySession(db, facts.sessions.single);
    expect(await db.getStudySegmentLookupCounters(), isEmpty);
    expect((await db.getStudySegments()).single.lookups, 0);
  });

  test('同步 wire：lookups 随段往返，0 不发（无查词段 JSON 不变）', () {
    StudySegmentRecord rec(int lookups) => StudySegmentRecord(
      uid: 'u',
      deviceId: 'd',
      mediaKind: kActivityMediaBook,
      mediaKey: 'b1',
      format: 'epub',
      title: 'T',
      startAt: 1,
      endAt: 2,
      dateKey: '2026-09-08',
      hour: 10,
      durationMs: 1000,
      chars: 0,
      pages: 0,
      updatedAt: 3,
      lookups: lookups,
    );
    expect(rec(0).toJson().containsKey('lookups'), isFalse);
    expect(rec(4).toJson()['lookups'], 4);
    expect(StudySegmentRecord.fromJson(rec(4).toJson())!.lookups, 4);
    expect(
      StudySegmentRecord.fromJson(rec(0).toJson())!.lookups,
      0,
      reason: '旧端不发 = 0',
    );
  });

  test('段带 lookups 落库聚合成计数同形行；按天写零时一并清零', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: 's1',
        deviceId: 'dev',
        mediaKind: kActivityMediaVideo,
        mediaKey: 'v1',
        title: 'V',
        startAt: DateTime(2026, 9, 8, 10).millisecondsSinceEpoch,
        endAt: DateTime(2026, 9, 8, 10, 5).millisecondsSinceEpoch,
        dateKey: '2026-09-08',
        hour: 10,
        durationMs: const Value(300000),
        lookups: const Value(3),
        updatedAt: 1,
      ),
    );
    final List<LookupMiningCounterRow> rows = await db
        .getStudySegmentLookupCounters();
    expect(rows.single.sourceType, kStatSourceVideo);
    expect(rows.single.bookKey, 'v1');
    expect(rows.single.dateKey, '2026-09-08');
    expect(rows.single.lookupCount, 3);
    expect(rows.single.mineCount, 0);
    expect(await db.getStudySegmentLookupCounters(mediaKey: 'other'), isEmpty);

    await db.zeroStudySegmentsOnDays(
      mediaKind: kActivityMediaVideo,
      mediaKey: 'v1',
      dateKeys: <String>{'2026-09-08'},
    );
    expect(await db.getStudySegmentLookupCounters(), isEmpty);
  });
}
