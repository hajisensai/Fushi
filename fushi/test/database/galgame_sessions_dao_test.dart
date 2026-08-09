import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v54 游玩会话表的聚合查询。
///
/// 这几个 GROUP BY 是**刻意用来取代上游 ReinaManager 的 `game_statistics` 投影表**的
/// （设计取舍见 `docs/design/galgame-library-reina-parity.md` §1.4）：没有投影就没有
/// 「投影与事实表不一致」的一整类 bug，代价只是每次现算。所以这些聚合的正确性就是
/// 全部统计 UI 的正确性，必须钉死。
void main() {
  Future<FushiDatabase> openDb() async {
    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<void> addGame(FushiDatabase db, String id) => db.upsertGalgame(
        GalgamesCompanion.insert(
          id: id,
          name: id,
          exePath: '/games/$id/$id.exe',
          workdir: '/games/$id',
          addedAt: 0,
        ),
      );

  Future<void> addSession(
    FushiDatabase db,
    String gameId, {
    required int startMs,
    required int endMs,
    required int durationSeconds,
    required String dateKey,
  }) =>
      db.insertGalgameSession(
        GalgameSessionsCompanion.insert(
          gameId: gameId,
          startMs: startMs,
          endMs: endMs,
          durationSeconds: durationSeconds,
          dateKey: dateKey,
        ),
      );

  test('getGalgamePlayTotals：按游戏聚合总时长/次数/最后游玩', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addGame(db, 'b');
    await addGame(db, 'c'); // 一次都没玩过

    await addSession(db, 'a',
        startMs: 1000,
        endMs: 601000,
        durationSeconds: 600,
        dateKey: '2026-07-20');
    await addSession(db, 'a',
        startMs: 700000,
        endMs: 1000000,
        durationSeconds: 300,
        dateKey: '2026-07-21');
    await addSession(db, 'b',
        startMs: 5000,
        endMs: 65000,
        durationSeconds: 60,
        dateKey: '2026-07-21');

    final Map<String, (int, int, int)> totals = await db.getGalgamePlayTotals();

    expect(totals['a']?.$1, 900); // 600 + 300 秒
    expect(totals['a']?.$2, 2); // 两次会话
    expect(totals['a']?.$3, 1000000); // MAX(end_ms)

    expect(totals['b']?.$1, 60);
    expect(totals['b']?.$2, 1);
    expect(totals['b']?.$3, 65000);

    // 没玩过的游戏根本不出现在结果里——消费方按 null 回落成 0，别指望有零值行。
    expect(totals.containsKey('c'), isFalse);
  });

  test('getGalgamePlayTotals：空表返回空 map 而不是抛异常', () async {
    final FushiDatabase db = await openDb();
    expect(await db.getGalgamePlayTotals(), isEmpty);
  });

  test('getGalgameDailySeconds：按天聚合且闭区间过滤', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addGame(db, 'b');

    // 同一天两段，应合并。
    await addSession(db, 'a',
        startMs: 1, endMs: 2, durationSeconds: 100, dateKey: '2026-07-20');
    await addSession(db, 'a',
        startMs: 3, endMs: 4, durationSeconds: 200, dateKey: '2026-07-20');
    await addSession(db, 'a',
        startMs: 5, endMs: 6, durationSeconds: 50, dateKey: '2026-07-22');
    // 区间外。
    await addSession(db, 'a',
        startMs: 7, endMs: 8, durationSeconds: 999, dateKey: '2026-07-25');
    // 别的游戏，不该混进来。
    await addSession(db, 'b',
        startMs: 9, endMs: 10, durationSeconds: 777, dateKey: '2026-07-20');

    final Map<String, int> daily = await db.getGalgameDailySeconds(
      'a',
      fromDateKey: '2026-07-20',
      toDateKey: '2026-07-22',
    );

    expect(daily, <String, int>{'2026-07-20': 300, '2026-07-22': 50});
    // 边界是闭区间：起止当天都算在内。
    expect(daily.containsKey('2026-07-25'), isFalse);
  });

  test('getGalgameDailySeconds：边界日包含在闭区间内', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addSession(db, 'a',
        startMs: 1, endMs: 2, durationSeconds: 10, dateKey: '2026-07-01');
    await addSession(db, 'a',
        startMs: 3, endMs: 4, durationSeconds: 20, dateKey: '2026-07-31');

    final Map<String, int> daily = await db.getGalgameDailySeconds(
      'a',
      fromDateKey: '2026-07-01',
      toDateKey: '2026-07-31',
    );
    expect(daily, <String, int>{'2026-07-01': 10, '2026-07-31': 20});
  });

  test('getGalgameSecondsForDay：跨全部游戏聚合某一天', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addGame(db, 'b');

    await addSession(db, 'a',
        startMs: 1, endMs: 2, durationSeconds: 100, dateKey: '2026-07-24');
    await addSession(db, 'b',
        startMs: 3, endMs: 4, durationSeconds: 250, dateKey: '2026-07-24');
    await addSession(db, 'a',
        startMs: 5, endMs: 6, durationSeconds: 999, dateKey: '2026-07-23');

    expect(await db.getGalgameSecondsForDay('2026-07-24'), 350);
    expect(await db.getGalgameSecondsForDay('2026-07-23'), 999);
    // 没有任何会话的一天返回 0（COALESCE），不是 null、不抛。
    expect(await db.getGalgameSecondsForDay('2026-07-25'), 0);
  });

  test('getAllGalgameDailyTotals：跨游戏按天聚合时长与会话数', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addGame(db, 'b');

    await addSession(db, 'a',
        startMs: 1, endMs: 2, durationSeconds: 100, dateKey: '2026-07-24');
    await addSession(db, 'b',
        startMs: 3, endMs: 4, durationSeconds: 250, dateKey: '2026-07-24');
    await addSession(db, 'a',
        startMs: 5, endMs: 6, durationSeconds: 999, dateKey: '2026-07-23');

    final Map<String, (int, int)> totals = await db.getAllGalgameDailyTotals();
    expect(totals['2026-07-24'], (350, 2));
    expect(totals['2026-07-23'], (999, 1));
  });

  test('getGalgameSessions：按起始时间倒序并支持分页', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    for (int i = 0; i < 5; i++) {
      await addSession(db, 'a',
          startMs: i * 1000,
          endMs: i * 1000 + 500,
          durationSeconds: 60 + i,
          dateKey: '2026-07-2$i');
    }

    final List<GalgameSessionRow> firstPage =
        await db.getGalgameSessions('a', limit: 2);
    expect(firstPage, hasLength(2));
    expect(firstPage[0].startMs, 4000); // 倒序：最新在前
    expect(firstPage[1].startMs, 3000);

    final List<GalgameSessionRow> secondPage =
        await db.getGalgameSessions('a', limit: 2, offset: 2);
    expect(
        secondPage.map((GalgameSessionRow r) => r.startMs), <int>[2000, 1000]);
  });

  test('deleteGalgameSession：删单条后聚合值同步变化（无投影表可失配）', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addSession(db, 'a',
        startMs: 1000,
        endMs: 2000,
        durationSeconds: 600,
        dateKey: '2026-07-20');
    await addSession(db, 'a',
        startMs: 3000,
        endMs: 4000,
        durationSeconds: 300,
        dateKey: '2026-07-20');

    expect((await db.getGalgamePlayTotals())['a']?.$1, 900);

    // 注意 getGalgameSessions 是 startMs **倒序**，first = 最新那条（300 秒）。
    final List<GalgameSessionRow> sessions = await db.getGalgameSessions('a');
    expect(sessions.first.durationSeconds, 300);
    await db.deleteGalgameSession(sessions.first.id);

    // 这正是不建投影表的价值：删一条流水，总时长立刻正确，无需增量更新或重算。
    final Map<String, (int, int, int)> after = await db.getGalgamePlayTotals();
    expect(after['a']?.$1, 600); // 只剩最早那条 600 秒
    expect(after['a']?.$2, 1);
    expect(after['a']?.$3, 2000); // 最后游玩回退到剩下那条的 end_ms
  });

  test('clearAllGalgameStatistics：只清会话，保留游戏库与活动时间线', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addSession(
      db,
      'a',
      startMs: 1000,
      endMs: 2000,
      durationSeconds: 600,
      dateKey: '2026-07-20',
    );
    await db.addActivityEvent(
      eventType: kActivityGame,
      mediaType: kActivityMediaGame,
      title: 'a',
      mediaKey: 'a',
      dateKey: '2026-07-20',
      timestampMs: 2000,
      durationMs: 600000,
      charsDelta: 100,
    );

    expect(await db.clearAllGalgameStatistics(), 1);

    expect(await db.getGalgameSessions('a'), isEmpty);
    expect(await db.getAllGalgameDailyTotals(), isEmpty);
    expect(await db.getGalgame('a'), isNotNull);
    final List<ActivityEventRow> activities =
        await db.getRecentActivityEvents();
    expect(activities, hasLength(1));
    expect(activities.single.eventType, kActivityGame);
  });

  test('galgame_sources：同 (gameId, source) 覆盖而不是插重复行', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');

    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'a',
        source: 'bgm',
        dataJson: '{"name":"old"}',
        fetchedAt: 1,
      ),
    );
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'a',
        source: 'bgm',
        dataJson: '{"name":"new"}',
        fetchedAt: 2,
      ),
    );
    // 不同源共存。
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: 'a',
        source: 'vndb',
        dataJson: '{"name":"v"}',
        fetchedAt: 3,
      ),
    );

    final List<GalgameSourceRow> sources = await db.getGalgameSources('a');
    expect(sources, hasLength(2));
    final GalgameSourceRow bgm =
        sources.firstWhere((GalgameSourceRow r) => r.source == 'bgm');
    expect(bgm.dataJson, '{"name":"new"}');
    expect(bgm.fetchedAt, 2);

    await db.deleteGalgameSource('a', 'bgm');
    expect(await db.getGalgameSources('a'), hasLength(1));
  });

  test('getAllGalgameSources：按 gameId 分组，避免库页 N+1', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');
    await addGame(db, 'b');
    await db.upsertGalgameSource(GalgameSourcesCompanion.insert(
        gameId: 'a', source: 'bgm', dataJson: '{}', fetchedAt: 1));
    await db.upsertGalgameSource(GalgameSourcesCompanion.insert(
        gameId: 'a', source: 'vndb', dataJson: '{}', fetchedAt: 1));
    await db.upsertGalgameSource(GalgameSourcesCompanion.insert(
        gameId: 'b', source: 'bgm', dataJson: '{}', fetchedAt: 1));

    final Map<String, List<GalgameSourceRow>> grouped =
        await db.getAllGalgameSources();
    expect(grouped['a'], hasLength(2));
    expect(grouped['b'], hasLength(1));
  });

  test('playStatus / customData / cover / 刮削结果的定点更新互不干扰', () async {
    final FushiDatabase db = await openDb();
    await addGame(db, 'a');

    await db.setGalgamePlayStatus('a', 3); // 在玩
    await db.setGalgameCustomData('a', '{"userRating":8.5}');
    await db.setGalgameCoverPath('a', '/covers/a.png');
    await db.setGalgameScrapeResult('a',
        primarySource: 'bgm', releaseDate: '2020-01-31');

    final GalgameRow? row = await db.getGalgame('a');
    expect(row, isNotNull);
    expect(row!.playStatus, 3);
    expect(row.customDataJson, '{"userRating":8.5}');
    expect(row.coverPath, '/covers/a.png');
    expect(row.primarySource, 'bgm');
    expect(row.releaseDate, '2020-01-31');
    // 本地字段没被这些定点更新踩坏。
    expect(row.name, 'a');
    expect(row.exePath, '/games/a/a.exe');

    // 清空自定义数据回落 null（展示回落到刮削值/本地默认名）。
    await db.setGalgameCustomData('a', null);
    expect((await db.getGalgame('a'))!.customDataJson, isNull);
  });
}
