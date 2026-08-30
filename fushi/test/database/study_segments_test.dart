import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

// v92 统计域重构：study_segments 是学习统计的唯一事实表。本测试锁定 DAO 契约：
// 按 uid 幂等 upsert（绝对值覆盖，永不 +=）、窗口查询、按身份删除 + 墓碑、按种类清空。
Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

StudySegmentsCompanion _seg(
  String uid, {
  String kind = kActivityMediaBook,
  String key = 'b1',
  String dateKey = '2026-08-29',
  int hour = 12,
  int ms = 60000,
  int chars = 0,
  int pages = 0,
  int updatedAt = 1000,
  int endAt = 2000,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kind,
  mediaKey: key,
  title: 'T',
  startAt: 1000,
  endAt: endAt,
  dateKey: dateKey,
  hour: hour,
  durationMs: Value(ms),
  chars: Value(chars),
  pages: Value(pages),
  updatedAt: updatedAt,
);

void main() {
  test('upsertStudySegment 按 uid 幂等：同 uid 两次写 = 一行，取后一次的绝对值', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertStudySegment(_seg('u1', ms: 30000, chars: 10));
    await db.upsertStudySegment(_seg('u1', ms: 30000, chars: 10));
    await db.upsertStudySegment(_seg('u1', ms: 90000, chars: 25));
    final List<StudySegmentRow> rows = await db.getStudySegments();
    expect(rows, hasLength(1));
    expect(rows.single.durationMs, 90000, reason: '绝对值覆盖，不是 30000×3');
    expect(rows.single.chars, 25);
  });

  test('getStudySegments 闭区间按 dateKey 过滤，任一端 null 不设界', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertStudySegment(_seg('a', dateKey: '2026-08-01'));
    await db.upsertStudySegment(_seg('b', dateKey: '2026-08-15'));
    await db.upsertStudySegment(_seg('c', dateKey: '2026-08-31'));
    expect(
      (await db.getStudySegments(
        fromDateKey: '2026-08-15',
        toDateKey: '2026-08-31',
      )).map((r) => r.uid),
      <String>['b', 'c'],
    );
    expect((await db.getStudySegments(toDateKey: '2026-08-01')).length, 1);
    expect((await db.getStudySegments()).length, 3);
  });

  test('deleteStudySegmentsForMedia 只删该身份、同一事务立按身份墓碑', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertStudySegment(_seg('a', key: 'b1'));
    await db.upsertStudySegment(_seg('b', key: 'b1'));
    await db.upsertStudySegment(_seg('c', key: 'b2'));
    final int removed = await db.deleteStudySegmentsForMedia(
      mediaKind: kActivityMediaBook,
      mediaKey: 'b1',
    );
    expect(removed, 2);
    expect(
      (await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
      )).isEmpty,
      isTrue,
    );
    expect((await db.getStudySegments()).single.uid, 'c', reason: '同名不同身份不连坐');
    final List<StudySegmentTombstoneRow> tombs = await db
        .getStudySegmentTombstones();
    expect(tombs.single.mediaKey, 'b1');
    expect(tombs.single.mediaKind, kActivityMediaBook);
  });

  test('clearStudySegments 只清该种类，不立碑', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertStudySegment(_seg('a', kind: kActivityMediaBook));
    await db.upsertStudySegment(_seg('b', kind: kActivityMediaVideo, key: 'v'));
    await db.clearStudySegments(kActivityMediaBook);
    expect((await db.getStudySegments()).single.uid, 'b');
    expect(await db.getStudySegmentTombstones(), isEmpty);
  });

  test('getLatestStudyEndAtByMedia 每身份取最大 end_at', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertStudySegment(
      _seg('a', kind: kActivityMediaVideo, key: 'v1', endAt: 5000),
    );
    await db.upsertStudySegment(
      _seg('b', kind: kActivityMediaVideo, key: 'v1', endAt: 9000),
    );
    await db.upsertStudySegment(
      _seg('c', kind: kActivityMediaVideo, key: 'v2', endAt: 7000),
    );
    await db.upsertStudySegment(_seg('d', kind: kActivityMediaBook, endAt: 99));
    expect(
      await db.getLatestStudyEndAtByMedia(kActivityMediaVideo),
      <String, int>{'v1': 9000, 'v2': 7000},
    );
  });

  test('getOrCreateStudyDeviceId 首次生成后持久、与 sync_device_id 同键', () async {
    final FushiDatabase db = await _openDb();
    final String id = await db.getOrCreateStudyDeviceId();
    expect(id, hasLength(32));
    expect(await db.getOrCreateStudyDeviceId(), id);
    expect(await db.getPref(FushiDatabase.studyDeviceIdPrefKey), id);
  });

  test('newStudySegmentUid 32 位 hex 且不重复', () {
    final Set<String> uids = <String>{
      for (int i = 0; i < 200; i++) FushiDatabase.newStudySegmentUid(),
    };
    expect(uids, hasLength(200));
    expect(uids.every((u) => RegExp(r'^[0-9a-f]{32}$').hasMatch(u)), isTrue);
  });

  test('getGalgameDailySecondsByGame 按 (game, day) 聚合', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'G',
        exePath: 'g.exe',
        workdir: '.',
        addedAt: 0,
      ),
    );
    for (final (int start, int secs, String day) in <(int, int, String)>[
      (1, 600, '2026-08-29'),
      (2, 300, '2026-08-29'),
      (3, 120, '2026-08-30'),
    ]) {
      await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: start,
          endMs: start + secs * 1000,
          durationSeconds: secs,
          dateKey: day,
        ),
      );
    }
    final List<(String, String, int)> rows = await db
        .getGalgameDailySecondsByGame();
    expect(rows.toSet(), <(String, String, int)>{
      ('g1', '2026-08-29', 900),
      ('g1', '2026-08-30', 120),
    });
  });

  test('watchDashboardDataChanges 在写入 study_segments 时 emit', () async {
    final FushiDatabase db = await _openDb();
    final List<void> emitted = <void>[];
    final sub = db.watchDashboardDataChanges().listen(emitted.add);
    addTearDown(sub.cancel);
    await db.upsertStudySegment(_seg('a'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(emitted, isNotEmpty);
  });
}
