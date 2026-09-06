import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/stat_facts.dart';
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
}) =>
    StudySegmentsCompanion.insert(
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
  group('用户按日删统计（BUG-2108：时段明细长按删一条）', () {
    test('zeroStudySegmentsOnDays：命中 (身份, 日) 的段写零且 updatedAt 推进，其余不动',
        () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(
          _seg('a', kind: 'video', key: 'v1', dateKey: '2026-09-01', ms: 5000));
      await db.upsertStudySegment(
          _seg('b', kind: 'video', key: 'v1', dateKey: '2026-09-02', chars: 7));
      await db.upsertStudySegment(
          _seg('c', kind: 'video', key: 'v1', dateKey: '2026-09-03', ms: 9000));
      await db.upsertStudySegment(
          _seg('d', kind: 'video', key: 'v2', dateKey: '2026-09-01', ms: 1000));
      final int changed = await db.zeroStudySegmentsOnDays(
        mediaKind: 'video',
        mediaKey: 'v1',
        dateKeys: <String>{'2026-09-01', '2026-09-02'},
      );
      expect(changed, 2);
      final Map<String, StudySegmentRow> rows = <String, StudySegmentRow>{
        for (final StudySegmentRow r in await db.getStudySegments()) r.uid: r,
      };
      expect(rows['a']!.durationMs, 0);
      expect(rows['b']!.chars, 0);
      expect(rows['a']!.updatedAt, greaterThan(1000),
          reason: 'LWW 用新 updatedAt 传播');
      expect(rows['c']!.durationMs, 9000, reason: '不在日集内不动');
      expect(rows['d']!.durationMs, 1000, reason: '别的身份不动');
      expect(rows, hasLength(4), reason: '写零不删行');
    });

    test('写零的段不进 StatFacts：删掉的那条不会以「0 字」原地复活', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(
          _seg('a', kind: 'video', key: 'v1', dateKey: '2026-09-01', ms: 5000));
      await db.upsertStudySegment(
          _seg('b', kind: 'video', key: 'v2', dateKey: '2026-09-01', ms: 7000));
      await db.zeroStudySegmentsOnDays(
        mediaKind: 'video',
        mediaKey: 'v1',
        dateKeys: <String>{'2026-09-01'},
      );

      final StatFacts facts = await loadStatFacts(db);
      // 写零而不删行是**同步语义要求**：真删行会被对端旧数据按 LWW 复活。于是过滤
      // 责任落在读侧——不过滤的话，时段明细里长按删掉的那条会以「0 字」原地回来
      // （sheet 对任何命中该 dateKey 的 fact 都建 entry，ms==0 走 formatStatChars(0)），
      // 而且零行还会污染排行 / 热力图等所有吃 StatFacts.daily 的消费方。
      expect(
        facts.daily.where((StatFact f) => f.mediaKey == 'v1'),
        isEmpty,
        reason: '被删的那条不该再出现在日面',
      );
      expect(
        facts.hourly.where((StatFact f) => f.mediaKey == 'v1'),
        isEmpty,
        reason: '小时面同理（热力图气泡）',
      );
      expect(
        facts.daily.where((StatFact f) => f.mediaKey == 'v2').single.ms,
        7000,
        reason: '没被删的照常在',
      );
    });

    test('零行不是「最近看过」：getLatestStudyEndAtByMedia 排除', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(_seg('old',
          kind: 'video',
          key: 'v1',
          dateKey: '2026-09-01',
          ms: 5000,
          endAt: 100));
      await db.upsertStudySegment(_seg('new',
          kind: 'video',
          key: 'v1',
          dateKey: '2026-09-02',
          ms: 5000,
          endAt: 900));
      await db.zeroStudySegmentsOnDays(
        mediaKind: 'video',
        mediaKey: 'v1',
        dateKeys: <String>{'2026-09-02'},
      );
      expect((await db.getLatestStudyEndAtByMedia('video'))['v1'], 100);
    });

    test('deleteStatFactsOnDays（视频）：段写零 + legacy 日行按 bookUid 删；空日集 no-op',
        () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(
          _seg('a', kind: 'video', key: 'v1', dateKey: '2026-09-01', ms: 5000));
      // 直插 per-uid legacy 行（setVideoWatchStatistic 是 wire 落地口，会塌成 NULL-uid）。
      for (final String day in <String>['2026-09-01', '2026-08-20']) {
        await db.into(db.videoWatchStatistics).insert(
              VideoWatchStatisticsCompanion.insert(
                title: 'EP1',
                bookUid: const Value('v1'),
                dateKey: day,
                subtitleChars: 0,
                watchTimeMs: 60000,
                lastModified: 1,
              ),
            );
      }
      await db.deleteStatFactsOnDays(
        mediaKind: 'video',
        mediaKey: 'v1',
        title: 'EP1',
        dateKeys: const <String>{},
      );
      expect((await db.getAllVideoWatchStatistics()), hasLength(2),
          reason: '空日集是 no-op');
      await db.deleteStatFactsOnDays(
        mediaKind: 'video',
        mediaKey: 'v1',
        title: 'EP1',
        dateKeys: <String>{'2026-09-01'},
      );
      final List<VideoWatchStatisticRow> legacy =
          await db.getAllVideoWatchStatistics();
      expect(legacy.map((r) => r.dateKey), <String>['2026-08-20']);
      expect((await db.getStudySegments()).single.durationMs, 0);
    });
  });

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
      ))
          .map((r) => r.uid),
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
      ))
          .isEmpty,
      isTrue,
    );
    expect((await db.getStudySegments()).single.uid, 'c', reason: '同名不同身份不连坐');
    final List<StudySegmentTombstoneRow> tombs =
        await db.getStudySegmentTombstones();
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
    final List<(String, String, int)> rows =
        await db.getGalgameDailySecondsByGame();
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
