import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/stats/study_sessions.dart';
import 'package:fushi_core/fushi_core.dart';

// v92 统计域重构：study_segments 是学习统计的唯一事实表。本测试锁定 DAO 契约：
// 按 uid 幂等 upsert（绝对值覆盖，永不 +=）、窗口查询、按身份删除 + 墓碑、按种类清空。
// BUG-2214 / BUG-2220 / BUG-2215：墓碑语义 = 「删除 startAt < deletedAt 的段」，碑戳只增
// 不减、永不因后来的段退场；清空也逐身份立碑。
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
  int startAt = 1000,
  int endAt = 2000,
}) => StudySegmentsCompanion.insert(
  uid: uid,
  deviceId: 'dev',
  mediaKind: kind,
  mediaKey: key,
  title: 'T',
  startAt: startAt,
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
    test(
      'zeroStudySegmentsOnDays：命中 (身份, 日) 的段写零且 updatedAt 推进，其余不动',
      () async {
        final FushiDatabase db = await _openDb();
        await db.upsertStudySegment(
          _seg('a', kind: 'video', key: 'v1', dateKey: '2026-09-01', ms: 5000),
        );
        await db.upsertStudySegment(
          _seg('b', kind: 'video', key: 'v1', dateKey: '2026-09-02', chars: 7),
        );
        await db.upsertStudySegment(
          _seg('c', kind: 'video', key: 'v1', dateKey: '2026-09-03', ms: 9000),
        );
        await db.upsertStudySegment(
          _seg('d', kind: 'video', key: 'v2', dateKey: '2026-09-01', ms: 1000),
        );
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
        expect(
          rows['a']!.updatedAt,
          greaterThan(1000),
          reason: 'LWW 用新 updatedAt 传播',
        );
        expect(rows['c']!.durationMs, 9000, reason: '不在日集内不动');
        expect(rows['d']!.durationMs, 1000, reason: '别的身份不动');
        expect(rows, hasLength(4), reason: '写零不删行');
      },
    );

    test('写零的段不进 StatFacts：删掉的那条不会以「0 字」原地复活', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(
        _seg('a', kind: 'video', key: 'v1', dateKey: '2026-09-01', ms: 5000),
      );
      await db.upsertStudySegment(
        _seg('b', kind: 'video', key: 'v2', dateKey: '2026-09-01', ms: 7000),
      );
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
      await db.upsertStudySegment(
        _seg(
          'old',
          kind: 'video',
          key: 'v1',
          dateKey: '2026-09-01',
          ms: 5000,
          endAt: 100,
        ),
      );
      await db.upsertStudySegment(
        _seg(
          'new',
          kind: 'video',
          key: 'v1',
          dateKey: '2026-09-02',
          ms: 5000,
          endAt: 900,
        ),
      );
      await db.zeroStudySegmentsOnDays(
        mediaKind: 'video',
        mediaKey: 'v1',
        dateKeys: <String>{'2026-09-02'},
      );
      expect((await db.getLatestStudyEndAtByMedia('video'))['v1'], 100);
    });

    test(
      'deleteStatFactsOnDays（视频）：段写零 + legacy 日行按 bookUid 删；空日集 no-op',
      () async {
        final FushiDatabase db = await _openDb();
        await db.upsertStudySegment(
          _seg('a', kind: 'video', key: 'v1', dateKey: '2026-09-01', ms: 5000),
        );
        // 直插 per-uid legacy 行（setVideoWatchStatistic 是 wire 落地口，会塌成 NULL-uid）。
        for (final String day in <String>['2026-09-01', '2026-08-20']) {
          await db
              .into(db.videoWatchStatistics)
              .insert(
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
        expect(
          (await db.getAllVideoWatchStatistics()),
          hasLength(2),
          reason: '空日集是 no-op',
        );
        await db.deleteStatFactsOnDays(
          mediaKind: 'video',
          mediaKey: 'v1',
          title: 'EP1',
          dateKeys: <String>{'2026-09-01'},
        );
        final List<VideoWatchStatisticRow> legacy = await db
            .getAllVideoWatchStatistics();
        expect(legacy.map((r) => r.dateKey), <String>['2026-08-20']);
        expect((await db.getStudySegments()).single.durationMs, 0);
      },
    );
  });

  group('会话流删单次会话（用户 2026-09-08：能删误点的 0 分钟会话）', () {
    test('zeroStudySegmentsByUids：只写零命中的 uid，updatedAt 推进；空集 no-op', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(_seg('a', ms: 5000, chars: 100));
      await db.upsertStudySegment(_seg('b', ms: 7000));
      await db.upsertStudySegment(_seg('c', key: 'b2', ms: 9000));
      expect(await db.zeroStudySegmentsByUids(const <String>{}), 0);
      expect(await db.zeroStudySegmentsByUids(<String>{'a', 'b'}), 2);
      final Map<String, StudySegmentRow> rows = <String, StudySegmentRow>{
        for (final StudySegmentRow r in await db.getStudySegments()) r.uid: r,
      };
      expect(rows['a']!.durationMs, 0);
      expect(rows['a']!.chars, 0);
      expect(rows['a']!.updatedAt, greaterThan(1000), reason: '零值是新的绝对值写');
      expect(rows['b']!.durationMs, 0);
      expect(rows['c']!.durationMs, 9000, reason: '别的会话不动');
      expect(
        await db.getStudySegmentTombstones(),
        isEmpty,
        reason: '删单次会话不立按身份墓碑（那会压死这本书的全部历史）',
      );
    });

    test('deleteStudySession（游戏）：骨架行硬删 + 吸收的字数段写零，同一事务', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: 'g1',
          name: 'g1',
          exePath: '/g/g1.exe',
          workdir: '/g',
          addedAt: 0,
        ),
      );
      final int sid = await db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: 'g1',
          startMs: 0,
          endMs: 60000,
          durationSeconds: 60,
          dateKey: '2026-09-08',
        ),
      );
      await db.upsertStudySegment(
        _seg('h', kind: kActivityMediaGame, key: 'g1', chars: 300, ms: 0),
      );
      await db.deleteStudySession(
        segmentUids: <String>{'h'},
        gameSessionId: sid,
      );
      expect(await db.getGalgameSessions('g1'), isEmpty);
      expect((await db.getStudySegments()).single.chars, 0);
    });

    test('写零后的会话不再出现在 StatFacts.sessions', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(
        _seg('a', ms: 5000, chars: 10, startAt: 1000, endAt: 6000),
      );
      await db.upsertStudySegment(
        _seg('b', ms: 8000, startAt: 7200000, endAt: 7208000),
      );
      expect((await loadStatFacts(db, activityLimit: 0)).sessions, hasLength(2));
      await db.deleteStudySession(segmentUids: <String>{'a'});
      final List<StudySession> after =
          (await loadStatFacts(db, activityLimit: 0)).sessions;
      expect(after, hasLength(1));
      expect(after.single.segmentUids, <String>['b']);
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

  test('clearStudySegments 只清该种类，并对该种类每个身份立碑（BUG-2215）', () async {
    final FushiDatabase db = await _openDb();
    await db.upsertStudySegment(_seg('a', kind: kActivityMediaBook, key: 'b1'));
    await db.upsertStudySegment(
      _seg('a2', kind: kActivityMediaBook, key: 'b1'),
    );
    await db.upsertStudySegment(_seg('c', kind: kActivityMediaBook, key: 'b2'));
    await db.upsertStudySegment(_seg('b', kind: kActivityMediaVideo, key: 'v'));
    final int before = DateTime.now().millisecondsSinceEpoch;
    await db.clearStudySegments(kActivityMediaBook);
    expect((await db.getStudySegments()).single.uid, 'b');
    final List<StudySegmentTombstoneRow> tombs = await db
        .getStudySegmentTombstones();
    expect(
      tombs.map((t) => '${t.mediaKind}|${t.mediaKey}').toSet(),
      <String>{'book|b1', 'book|b2'},
      reason: '每个被清的身份一块碑；视频域不连坐',
    );
    for (final StudySegmentTombstoneRow t in tombs) {
      expect(t.deletedAt, greaterThanOrEqualTo(before));
    }
    // 清空之前开始的段回写被拒；清空之后开始的新段照常（身份不被「毒化」）。
    await db.upsertStudySegment(_seg('a', key: 'b1', startAt: before - 1));
    expect((await db.getStudySegments()).length, 1);
    final int later = DateTime.now().millisecondsSinceEpoch + 1;
    await db.upsertStudySegment(_seg('fresh', key: 'b1', startAt: later));
    expect((await db.getStudySegments()).map((r) => r.uid).toSet(), <String>{
      'b',
      'fresh',
    });
    expect((await db.getStudySegmentTombstones()).length, 2, reason: '碑仍在');
  });

  group('墓碑语义：删除 startAt < deletedAt 的段（BUG-2214 / BUG-2220）', () {
    test('删该媒体统计后，仍在跑的时钟对开放段（startAt 在删除前）的回写被静默丢弃', () async {
      final FushiDatabase db = await _openDb();
      // 时钟在 t=1000 开段并 tick 到 5000。
      await db.upsertStudySegment(
        _seg('open', key: 'b1', startAt: 1000, updatedAt: 5000, ms: 4000),
      );
      await db.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
      );
      expect(await db.getStudySegments(), isEmpty);
      final int deletedAt =
          (await db.getStudySegmentTombstones()).single.deletedAt;
      // 下一 tick：同 uid、updatedAt 已在 deletedAt 之后，但 startAt 在删除之前。
      await db.upsertStudySegment(
        _seg(
          'open',
          key: 'b1',
          startAt: 1000,
          updatedAt: deletedAt + 60000,
          ms: 64000,
        ),
      );
      expect(await db.getStudySegments(), isEmpty, reason: '开放段不得复活');
      expect(
        (await db.getStudySegmentTombstones()).single.deletedAt,
        deletedAt,
        reason: '碑不动',
      );
    });

    test('删除之后开的新段（startAt >= deletedAt）存活，碑仍在、不退场', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(_seg('old', key: 'b1', startAt: 1000));
      await db.deleteStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
      );
      final int deletedAt =
          (await db.getStudySegmentTombstones()).single.deletedAt;
      await db.upsertStudySegment(
        _seg('new', key: 'b1', startAt: deletedAt, updatedAt: deletedAt + 1),
      );
      await db.upsertStudySegment(
        _seg(
          'new',
          key: 'b1',
          startAt: deletedAt,
          updatedAt: deletedAt + 2,
          ms: 9,
        ),
      );
      final List<StudySegmentRow> rows = await db.getStudySegments();
      expect(rows.single.uid, 'new');
      expect(rows.single.durationMs, 9, reason: '同 uid 继续 tick 照常覆盖');
      expect(
        (await db.getStudySegmentTombstones()).single.deletedAt,
        deletedAt,
      );
    });

    test('applyStudySegmentTombstone 按 startAt 删、碑戳只增不减', () async {
      final FushiDatabase db = await _openDb();
      // updatedAt 早已越过 deletedAt 的开放段照样删（旧口径按 updatedAt 会放过它）。
      await db.upsertStudySegment(
        _seg('before', key: 'b1', startAt: 100, updatedAt: 9000),
      );
      await db.upsertStudySegment(
        _seg('after', key: 'b1', startAt: 5000, updatedAt: 5001),
      );
      await db.upsertStudySegment(_seg('other', key: 'b2', startAt: 100));
      await db.applyStudySegmentTombstone(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
        deletedAt: 5000,
      );
      expect((await db.getStudySegments()).map((r) => r.uid).toSet(), <String>{
        'after',
        'other',
      });
      // 更旧的碑到达：不降级、不删 after。
      await db.applyStudySegmentTombstone(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
        deletedAt: 3000,
      );
      expect((await db.getStudySegmentTombstones()).single.deletedAt, 5000);
      expect((await db.getStudySegments()).length, 2);
      // 更新的碑到达：抬高并把 after 也删掉。
      await db.applyStudySegmentTombstone(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
        deletedAt: 6000,
      );
      expect((await db.getStudySegmentTombstones()).single.deletedAt, 6000);
      expect((await db.getStudySegments()).single.uid, 'other');
    });

    test(
      'upsertStudySegmentTombstone / deleteStudySegmentsForMedia 不把碑戳倒退',
      () async {
        final FushiDatabase db = await _openDb();
        await db.upsertStudySegment(_seg('a', key: 'b1'));
        await db.deleteStudySegmentsForMedia(
          mediaKind: kActivityMediaBook,
          mediaKey: 'b1',
        );
        final int first =
            (await db.getStudySegmentTombstones()).single.deletedAt;
        await db.upsertStudySegmentTombstone(
          mediaKind: kActivityMediaBook,
          mediaKey: 'b1',
          deletedAt: first - 100000,
        );
        expect((await db.getStudySegmentTombstones()).single.deletedAt, first);
        await db.deleteStudySegmentsForMedia(
          mediaKind: kActivityMediaBook,
          mediaKey: 'b1',
        );
        expect(
          (await db.getStudySegmentTombstones()).single.deletedAt,
          greaterThanOrEqualTo(first),
        );
      },
    );

    test('upsertStudySegmentsIfNewer（同步落地）跳过被本地碑压制的行', () async {
      final FushiDatabase db = await _openDb();
      await db.applyStudySegmentTombstone(
        mediaKind: kActivityMediaBook,
        mediaKey: 'b1',
        deletedAt: 5000,
      );
      await db.upsertStudySegmentsIfNewer(<StudySegmentsCompanion>[
        _seg('dead', key: 'b1', startAt: 100, updatedAt: 9999),
        _seg('alive', key: 'b1', startAt: 5000, updatedAt: 5001),
        _seg('other', key: 'b2', startAt: 100),
      ]);
      expect((await db.getStudySegments()).map((r) => r.uid).toSet(), <String>{
        'alive',
        'other',
      });
    });
  });

  group('legacy 阅读行反查库表身份（BUG-2216）', () {
    EpubBooksCompanion book(String key, String title) =>
        EpubBooksCompanion.insert(
          bookKey: key,
          title: title,
          epubPath: '/tmp/$key.epub',
          extractDir: '/tmp/$key',
          chapterCount: 1,
          chaptersJson: '["c"]',
          importedAt: 1,
        );

    Future<void> legacyRow(FushiDatabase db, String title) =>
        db.setReadingStatistic(
          ReadingStatisticsCompanion.insert(
            title: title,
            dateKey: '2026-08-29',
            charactersRead: 100,
            readingTimeMs: 60000,
            lastStatisticModified: 1,
          ),
        );

    test('库里恰好一本同名 → 补 bookKey；同名两本 → 身份留空，不错贴给任意一本', () async {
      final FushiDatabase db = await _openDb();
      await db.insertEpubBook(book('k-solo', 'Solo'));
      await db.insertEpubBook(book('k-dup-1', 'Dup'));
      await db.insertEpubBook(book('k-dup-2', 'Dup'));
      await legacyRow(db, 'Solo');
      await legacyRow(db, 'Dup');
      final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
      final Map<String, String> keyByTitle = <String, String>{
        for (final StatFact f in facts.dailyBooks) f.title: f.mediaKey,
      };
      expect(keyByTitle['Solo'], 'k-solo');
      expect(keyByTitle['Dup'], '', reason: '同名歧义宁可分裂不要错贴');
      expect(uniqueBookKeyByTitle(facts.epubRows), <String, String>{
        'Solo': 'k-solo',
      });
      expect(ambiguousBookTitles(facts.epubRows), <String>{'Dup'});
    });
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

  // 用户 2026-09-10：会话行可编辑（日期 / 字数）+ 会话区块「清除全部会话」。三条新
  // DAO 原语的契约：读回段 / 批量清 / 逐段绝对值改写。语义层（分摊、平移、退役纪律）
  // 在 test/stats/study_session_edit_test.dart。
  group('会话编辑 / 批量清除的 DAO 原语', () {
    Future<int> putGame(FushiDatabase db, String id, {int start = 1000}) async {
      await db.upsertGalgame(
        GalgamesCompanion.insert(
          id: id,
          name: 'G',
          exePath: '$id.exe',
          workdir: '.',
          addedAt: 0,
        ),
      );
      return db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: id,
          startMs: start,
          endMs: start + 3600000,
          durationSeconds: 3600,
          dateKey: '2026-08-29',
        ),
      );
    }

    test('getStudySegmentsByUids：命中 / 空集 / 不存在的 uid', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(_seg('a', chars: 10));
      await db.upsertStudySegment(_seg('b', chars: 20));
      await db.upsertStudySegment(_seg('c', chars: 30));
      expect(
        (await db.getStudySegmentsByUids(<String>{'a', 'c'}))
            .map((r) => r.uid)
            .toSet(),
        <String>{'a', 'c'},
      );
      expect(
        await db.getStudySegmentsByUids(const <String>{}),
        isEmpty,
        reason: '空集不许退化成「取全表」',
      );
      expect(
        (await db.getStudySegmentsByUids(<String>{'a', 'nope'}))
            .map((r) => r.uid)
            .toSet(),
        <String>{'a'},
        reason: '不存在的 uid 不报错、不造行',
      );
    });

    test('deleteStudySessions：整批段写零 + 骨架行按 id 硬删 + 不立墓碑', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(_seg('a', ms: 5000, chars: 10, pages: 2));
      await db.upsertStudySegment(_seg('b', key: 'b2', ms: 7000, chars: 20));
      await db.upsertStudySegment(_seg('keep', key: 'b3', ms: 9000, chars: 30));
      final int g1 = await putGame(db, 'g1');
      final int g2 = await putGame(db, 'g2', start: 2000);
      final int gKeep = await putGame(db, 'g3', start: 3000);

      await db.deleteStudySessions(
        segmentUids: <String>{'a', 'b'},
        gameSessionIds: <int>[g1, g2],
      );

      final Map<String, StudySegmentRow> rows = <String, StudySegmentRow>{
        for (final StudySegmentRow r in await db.getStudySegments()) r.uid: r,
      };
      expect(rows, hasLength(3), reason: '写零不删行（同步语义要求）');
      for (final String uid in <String>['a', 'b']) {
        expect(rows[uid]!.durationMs, 0, reason: uid);
        expect(rows[uid]!.chars, 0, reason: uid);
        expect(rows[uid]!.pages, 0, reason: uid);
        expect(
          rows[uid]!.updatedAt,
          greaterThan(1000),
          reason: 'LWW 用新 updatedAt 传播这次删除',
        );
      }
      expect(rows['keep']!.durationMs, 9000, reason: '不在批次里的段不动');
      expect(
        (await db.getRecentGalgameSessions()).map((g) => g.id).toList(),
        <int>[gKeep],
        reason: '游戏骨架行硬删（游戏统计不出本机）',
      );
      expect(
        await db.getStudySegmentTombstones(),
        isEmpty,
        reason: '不立墓碑：按身份的碑会压死这本书的全部历史',
      );
    });

    test('updateStudySession：逐段绝对值写入 + insertSegments 建行 + 骨架行平移', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertStudySegment(
        _seg(
          'a',
          dateKey: '2026-08-29',
          hour: 12,
          ms: 5000,
          chars: 300,
          startAt: 1000,
          endAt: 2000,
          updatedAt: 1000,
        ),
      );
      await db.upsertStudySegment(_seg('other', key: 'b2', chars: 99));
      final int gid = await putGame(db, 'g1');

      await db.updateStudySession(
        segments: <StudySegmentsCompanion>[
          const StudySegmentsCompanion(
            uid: Value('a'),
            startAt: Value(90000),
            endAt: Value(91000),
            dateKey: Value('2026-09-01'),
            hour: Value(9),
            chars: Value(150),
            updatedAt: Value(4242),
          ),
        ],
        insertSegments: <StudySegmentsCompanion>[
          StudySegmentsCompanion.insert(
            uid: 'inserted',
            deviceId: 'dev',
            mediaKind: kActivityMediaGame,
            mediaKey: 'g1',
            title: 'G',
            startAt: 2000,
            endAt: 3600000,
            dateKey: '2026-09-01',
            hour: 9,
            chars: const Value(77),
            updatedAt: 4242,
          ),
        ],
        gameSessionId: gid,
        gameStartMs: 90000,
        gameEndMs: 94000,
        gameDateKey: '2026-09-01',
      );

      final Map<String, StudySegmentRow> rows = <String, StudySegmentRow>{
        for (final StudySegmentRow r in await db.getStudySegments()) r.uid: r,
      };
      expect(rows['a']!.startAt, 90000);
      expect(rows['a']!.endAt, 91000);
      expect(rows['a']!.dateKey, '2026-09-01');
      expect(rows['a']!.hour, 9);
      expect(rows['a']!.chars, 150);
      expect(rows['a']!.updatedAt, 4242);
      expect(rows['a']!.durationMs, 5000, reason: 'companion 没带的列不动');
      expect(rows['other']!.chars, 99, reason: '别的段不受牵连');
      expect(rows['inserted']!.chars, 77, reason: 'insertSegments 真建了行');
      expect(rows['inserted']!.mediaKind, kActivityMediaGame);
      final GalgameSessionRow game = (await db.getRecentGalgameSessions())
          .firstWhere((g) => g.id == gid);
      expect(game.startMs, 90000);
      expect(game.endMs, 94000);
      expect(game.dateKey, '2026-09-01');
    });
  });
}
