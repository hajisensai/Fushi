// 统计域：阅读 / 视频 / 活动事件 / 游戏库 / 收藏 / 制卡 / 计数（God 类拆分 2026-08：part+mixin，仓库 reader_fushi
// part 先例；mixin 是真类成员——可被测试子类 override、虚分派正常
// （extension 方案在此翻车过）；私有 mixin 不进公共 API 面。
part of 'database.dart';

mixin _FushiDbStatistics
    on _$FushiDatabase, _FushiDbContentMisc, _FushiDbTagsSync {
  // ── reading statistics ──────────────────────────────────────────
  /// OVERWRITE semantics: sets the row for (title, dateKey) to the absolute
  /// values in [stat]. Use this when the caller already holds the final total
  /// (e.g. sync merge). For incremental session deltas use
  /// [addReadingStatistic], which accumulates. Passing a delta here would
  /// silently reset the totals.
  /// 绝对值覆盖（同步/备份合并用）。**刻意不写 `pagesRead`**：页数是 v60 新增的本机
  /// 维度，跨设备 wire 契约不带它（[StatBucket] 要求两端字段集一致）。冲突更新只覆盖
  /// 三个老列，本地已记的页数不会被对端的「没有页数」抹成 0。
  Future<void> setReadingStatistic(ReadingStatisticsCompanion stat) =>
      into(readingStatistics).insert(
        stat,
        onConflict: DoUpdate(
          (old) => ReadingStatisticsCompanion(
            charactersRead: stat.charactersRead,
            readingTimeMs: stat.readingTimeMs,
            lastStatisticModified: stat.lastStatisticModified,
          ),
          target: [readingStatistics.title, readingStatistics.dateKey],
        ),
      );

  /// ACCUMULATE semantics: adds [charsRead]/[timeMs] to the existing totals
  /// for (title, dateKey). Use for reading-session deltas. For setting an
  /// absolute total (e.g. sync merge) use [setReadingStatistic].
  /// 累加一条当日阅读统计。[pagesRead] 是 v60 的页数维度（漫画/PDF 传真实翻过的
  /// 页数，EPUB 不传即 0），与 [charsRead] 各自独立累加，互不顶替。
  Future<void> addReadingStatistic({
    required String title,
    required String dateKey,
    required int charsRead,
    required int timeMs,
    int pagesRead = 0,
  }) =>
      transaction(() async {
        final existing = await (select(readingStatistics)
              ..where((t) => t.title.equals(title) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingStatisticsCompanion(
            charactersRead: Value(existing.charactersRead + charsRead),
            readingTimeMs: Value(existing.readingTimeMs + timeMs),
            pagesRead: Value(existing.pagesRead + pagesRead),
            lastStatisticModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(readingStatistics).insert(
            ReadingStatisticsCompanion.insert(
              title: title,
              dateKey: dateKey,
              charactersRead: charsRead,
              readingTimeMs: timeMs,
              pagesRead: Value(pagesRead),
              lastStatisticModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          // 首次为该书当日建统计行 = 用户重新读它：清其统计删除墓碑（若有），让
          // 该书统计重新参与云同步 / 备份合并（TODO-1204 后续）。
          await clearStatisticsTombstone(title, FushiDatabase.statSourceBook);
        }
      });

  Future<List<ReadingStatisticRow>> getAllReadingStatistics() =>
      select(readingStatistics).get();

  // ── reading hourly logs ─────────────────────────────────────────
  /// ACCUMULATE：把 [deltaMs] 累加进 (dateKey, hour, format) 桶。[format] 是写入
  /// 面身份（EPUB / PDF / 漫画阅读器各报各的），v67 起时段数据按它可拆。
  Future<void> addHourlyReadingTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
    required BookFormat format,
  }) =>
      _addHourlyReadingTimeRaw(
        dateKey: dateKey,
        hour: hour,
        deltaMs: deltaMs,
        format: format.dbValue,
      );

  /// 云聚合同步专用：把旧端（不带 format 的 wire 快照）贡献的、无法归因到任何
  /// 写入面的逐时差额累加进 `''`（未区分）桶。普通写入面一律走带 [BookFormat]
  /// 的 [addHourlyReadingTime]，不得用本方法制造新的未区分数据。
  Future<void> addUnattributedHourlyReadingTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      _addHourlyReadingTimeRaw(
        dateKey: dateKey,
        hour: hour,
        deltaMs: deltaMs,
        format: '',
      );

  Future<void> _addHourlyReadingTimeRaw({
    required String dateKey,
    required int hour,
    required int deltaMs,
    required String format,
  }) =>
      transaction(() async {
        final existing = await (select(readingHourlyLogs)
              ..where((t) =>
                  t.dateKey.equals(dateKey) &
                  t.hour.equals(hour) &
                  t.format.equals(format)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(readingHourlyLogs)
                ..where((t) => t.id.equals(existing.id)))
              .write(ReadingHourlyLogsCompanion(
            readingTimeMs: Value(existing.readingTimeMs + deltaMs),
          ));
        } else {
          await into(readingHourlyLogs).insert(
            ReadingHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              readingTimeMs: deltaMs,
              format: Value(format),
            ),
          );
        }
      });

  Future<List<ReadingHourlyLogRow>> getHourlyLogsForDate(String dateKey) =>
      (select(readingHourlyLogs)..where((t) => t.dateKey.equals(dateKey)))
          .get();

  /// 逐行读取全部阅读小时日志，供云聚合同步 materialize 快照（TODO-1056 phase B）。
  Future<List<ReadingHourlyLogRow>> getAllReadingHourlyLogs() =>
      select(readingHourlyLogs).get();

  /// OVERWRITE 语义：把 (dateKey, hour, format) 桶设为绝对值 [readingTimeMs]。
  /// 云聚合合并已在 Dart 侧算好 MAX，这里直接落绝对值（对照
  /// [addHourlyReadingTime] 的累加）。[format] 收裸串而非 [BookFormat]：wire 快照
  /// 可能来自带未来新格式值的新版本端，本方法逐字节保存、不得折叠成已知枚举。
  Future<void> setReadingHourlyLog({
    required String dateKey,
    required int hour,
    required int readingTimeMs,
    required String format,
  }) =>
      into(readingHourlyLogs).insert(
        ReadingHourlyLogsCompanion.insert(
          dateKey: dateKey,
          hour: hour,
          readingTimeMs: readingTimeMs,
          format: Value(format),
        ),
        onConflict: DoUpdate(
          (_) =>
              ReadingHourlyLogsCompanion(readingTimeMs: Value(readingTimeMs)),
          target: [
            readingHourlyLogs.dateKey,
            readingHourlyLogs.hour,
            readingHourlyLogs.format,
          ],
        ),
      );

  // ── video watch statistics ──────────────────────────────────────
  /// ACCUMULATE：把 [subtitleChars]/[watchTimeMs] 累加到 (title, dateKey) 现有
  /// 总量。对照 [addReadingStatistic]，但视频专用、与阅读统计隔离。
  Future<void> addVideoWatchStatistic({
    required String title,
    required String dateKey,
    required int subtitleChars,
    required int watchTimeMs,
    String? bookUid,
  }) =>
      transaction(() async {
        // v39：有 bookUid（当前所有真实写入方）按 (bookUid,dateKey) 键控，同名
        // 不同视频各自累计；无 bookUid（兼容旧调用）按旧 (title,dateKey) 且只命中
        // 无身份行，不污染新键控行。无身份判定 NULL 与 '' 都算（review3-9：与
        // 删除/展示层同一判据，防 '' 编码漂移把无身份统计裂成两行）。
        final List<VideoWatchStatisticRow> candidates =
            await (select(videoWatchStatistics)
                  ..where((t) => bookUid != null
                      ? (t.bookUid.equals(bookUid) & t.dateKey.equals(dateKey))
                      : (t.title.equals(title) &
                          t.dateKey.equals(dateKey) &
                          (t.bookUid.isNull() | t.bookUid.equals('')))))
                .get();
        final VideoWatchStatisticRow? existing =
            candidates.isEmpty ? null : candidates.first;
        if (existing != null) {
          await (update(videoWatchStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(VideoWatchStatisticsCompanion(
            subtitleChars: Value(existing.subtitleChars + subtitleChars),
            watchTimeMs: Value(existing.watchTimeMs + watchTimeMs),
            lastModified: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        } else {
          await into(videoWatchStatistics).insert(
            VideoWatchStatisticsCompanion.insert(
              bookUid: Value(bookUid),
              title: title,
              dateKey: dateKey,
              subtitleChars: subtitleChars,
              watchTimeMs: watchTimeMs,
              lastModified: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          // 重新观看该视频：清其统计删除墓碑（TODO-1204 后续）。
          await clearStatisticsTombstone(title, FushiDatabase.statSourceVideo);
        }
      });

  Future<List<VideoWatchStatisticRow>> getAllVideoWatchStatistics() =>
      select(videoWatchStatistics).get();

  // ── activity events (v49) ───────────────────────────────────────
  /// 追加一条活动事件（每次阅读/观看 session 结束或导入完成时写一行）。纯追加，
  /// 不去重、不累加——同书同日多次 session = 多行，读取端按需分组/计数。
  /// 统计日分组键（本地时区 `yyyy-MM-dd`）。与 app 层 `statDateKey` /
  /// fushi_audio 的小时桶 dateKey 同构——[recordReadingSession] 在 DB 层派生
  /// dateKey 的单一来源，别再让调用方自算一份传进来。
  static String statDateKeyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// P4 写侧收敛（2026-08 数据层重构）：一次阅读 session 的**唯一落库入口**。
  ///
  /// 同一事务写活动事实行（activity_events，精确时刻的 session 事实）并从
  /// **同一份数字**派生日聚合投影（reading_statistics 经 [addReadingStatistic]，
  /// 含清统计墓碑语义）。此前三个阅读面（EPUB/漫画/PDF）各自按顺序散调两个
  /// DAO、事实与投影的 chars/timeMs/dateKey 各传一遍——传得不一致没有任何
  /// 东西拦（结构性漂移面）；收敛后数字与时刻只进一次。
  ///
  /// 小时桶（reading_hourly_logs）**刻意不在此**：它是 ReadingTimeTracker 的
  /// tick 粒度账本（60s 窗口 + 连续性守卫 + 跨时/日边界拆桶，BUG-892/1052），
  /// 与 session 粒度不同构。视频侧同理不设 session 复合入口：
  /// video_watch_statistics 的 flush 是**桶粒度**（dateKey 按各桶归属，跨午夜
  /// 正确性依赖于此），与 activity 的 session 总量数值天然不同，强行统一会
  /// 引入跨午夜归属 bug——见 video_fushi_page 的 VideoWatchTracker 接线注释。
  Future<void> recordReadingSession({
    required String title,
    required String mediaKey,
    required int charsRead,
    required int timeMs,
    int pagesRead = 0,
    required DateTime at,
  }) =>
      transaction(() async {
        final String dateKey = _FushiDbStatistics.statDateKeyOf(at);
        await addActivityEvent(
          eventType: 'read',
          mediaType: 'book',
          title: title,
          mediaKey: mediaKey,
          dateKey: dateKey,
          timestampMs: at.millisecondsSinceEpoch,
          durationMs: timeMs,
          charsDelta: charsRead,
        );
        await addReadingStatistic(
          title: title,
          dateKey: dateKey,
          charsRead: charsRead,
          timeMs: timeMs,
          pagesRead: pagesRead,
        );
      });

  Future<void> addActivityEvent({
    required String eventType,
    required String mediaType,
    required String title,
    required String dateKey,
    required int timestampMs,
    String? mediaKey,
    int? durationMs,
    int? charsDelta,
  }) =>
      into(activityEvents).insert(
        ActivityEventsCompanion.insert(
          eventType: eventType,
          mediaType: mediaType,
          title: title,
          dateKey: dateKey,
          timestampMs: timestampMs,
          mediaKey: Value(mediaKey),
          durationMs: Value(durationMs),
          charsDelta: Value(charsDelta),
        ),
      );

  /// 取最近 [limit] 条活动事件，按精确时刻倒序（首页 Activity 面板消费）。
  /// [eventTypes] 非空时只取这些类别（如只看 'read'），null = 全部类别。
  Future<List<ActivityEventRow>> getRecentActivityEvents({
    int limit = 200,
    List<String>? eventTypes,
  }) {
    final SimpleSelectStatement<$ActivityEventsTable, ActivityEventRow> query =
        select(activityEvents)
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.timestampMs,
                  mode: OrderingMode.desc,
                ),
          ])
          ..limit(limit);
    if (eventTypes != null && eventTypes.isNotEmpty) {
      query.where((t) => t.eventType.isIn(eventTypes));
    }
    return query.get();
  }

  /// 按 date_key 聚合某类活动（首页热力图/趋势按天消费）：返回每天的字符增量与
  /// 时长合计，`chars_delta` / `duration_ms` 为 null 记 0。在 SQL 侧先聚合，避免把
  /// 整表活动行拉进内存再分组。
  Future<List<(String dateKey, int charsDelta, int durationMs)>>
      getActivityDailyTotals(String eventType) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT date_key, '
      'COALESCE(SUM(chars_delta), 0) AS chars_total, '
      'COALESCE(SUM(duration_ms), 0) AS duration_total '
      'FROM activity_events WHERE event_type = ? GROUP BY date_key',
      variables: [Variable.withString(eventType)],
    ).get();
    return [
      for (final QueryRow row in rows)
        (
          row.read<String>('date_key'),
          row.read<int>('chars_total'),
          row.read<int>('duration_total'),
        ),
    ];
  }

  /// 某日某类活动按 title 聚合（首页某天详情消费）：返回每个标题的字符/时长合计，
  /// 按时长（duration_ms 合计）降序。null 记 0。
  Future<List<(String title, int charsDelta, int durationMs)>>
      getActivityTitleTotalsForDay(String eventType, String dateKey) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT title, '
      'COALESCE(SUM(chars_delta), 0) AS chars_total, '
      'COALESCE(SUM(duration_ms), 0) AS duration_total '
      'FROM activity_events WHERE event_type = ? AND date_key = ? '
      'GROUP BY title ORDER BY duration_total DESC',
      variables: [
        Variable.withString(eventType),
        Variable.withString(dateKey),
      ],
    ).get();
    return [
      for (final QueryRow row in rows)
        (
          row.read<String>('title'),
          row.read<int>('chars_total'),
          row.read<int>('duration_total'),
        ),
    ];
  }

  // ── 活动事件的删除对称性(P4 B2,2026-08-10 用户拍板) ──────────────
  // 决策:活动时间轴是**历史事实日志**,不是现存库的视图——删书/删视频
  // **不**连带删其活动事件("我上个月读过什么"的历史不随删库改写)。
  // 下面两个清理函数因此**刻意零生产调用**,不是漏接线;保留是给将来
  // 可能的显式清理入口(用户主动"清除活动历史")备用,勿在删除路径接线。

  /// 删除某标题的全部活动事件。刻意无生产调用方(见上方决策注释)。
  Future<int> deleteActivityEventsForTitle(String title) =>
      (delete(activityEvents)..where((t) => t.title.equals(title))).go();

  /// 清空全部活动事件。刻意无生产调用方(见上方决策注释)。
  Future<int> clearAllActivityEvents() => delete(activityEvents).go();

  // ── galgames / galgame_sources / galgame_sessions (v55 游戏库) ──────
  //
  // 设计见 `docs/design/galgame-library-reina-parity.md`。这里刻意没有统计投影表：
  // 时长/次数/最后游玩全部现算 GROUP BY（见下面聚合方法），一次消掉「投影与
  // 事实表不一致」的整类 bug。单机规模是几百游戏 × 几千会话，SQLite 毫秒级。

  /// 全部游戏，按添加时间升序（与旧 JSON 列表的天然顺序一致，Never break userspace）。
  Future<List<GalgameRow>> getAllGalgames() =>
      (select(galgames)..orderBy([(t) => OrderingTerm.asc(t.addedAt)])).get();

  /// 监听全部游戏（库页实时刷新）。
  Stream<List<GalgameRow>> watchAllGalgames() =>
      (select(galgames)..orderBy([(t) => OrderingTerm.asc(t.addedAt)])).watch();

  Future<GalgameRow?> getGalgame(String id) =>
      (select(galgames)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 新增或整行覆盖一条游戏。
  Future<void> upsertGalgame(GalgamesCompanion entry) =>
      into(galgames).insertOnConflictUpdate(entry);

  /// 删除一条游戏。`galgame_sources` / `galgame_sessions` 经 FK cascade 连带清理；
  /// 标签映射 v77 起是逻辑外键，同事务显式清。
  Future<int> deleteGalgame(String id) => transaction(() async {
        await deleteTagAssignmentsForHost(TagHostKind.game, id);
        return (delete(galgames)..where((t) => t.id.equals(id))).go();
      });

  /// 只改游玩状态（0=未设置 / 1=想玩 / 2=玩过 / 3=在玩 / 4=搁置 / 5=弃坑）。
  Future<int> setGalgamePlayStatus(String id, int status) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(playStatus: Value<int>(status)));

  /// 只改用户覆盖层 JSON（null = 清空全部自定义，展示回落到刮削值/本地默认名）。
  Future<int> setGalgameCustomData(String id, String? json) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(customDataJson: Value<String?>(json)));

  /// 只改本地封面路径（null = 回落默认手柄图标）。
  Future<int> setGalgameCoverPath(String id, String? path) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(coverPath: Value<String?>(path)));

  /// 只改该游戏的窗口超分档位（'auto' / 'installed_only' / 'off'；空串 = 未设置，
  /// 解析层回落到关闭）。列非空，所以清空是写空串而不是写 null。
  Future<int> setGalgameUpscalingMode(String id, String modeKey) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(upscalingMode: Value<String>(modeKey)));

  /// 只改该游戏的日语区域（转区）档位（'auto' / 'on' / 'off'；空串 = 未设置，
  /// 解析层回落 auto）。列非空，所以清空是写空串而不是写 null。
  Future<int> setGalgameJapaneseLocaleMode(String id, String modeKey) =>
      (update(galgames)..where((t) => t.id.equals(id)))
          .write(GalgamesCompanion(japaneseLocaleMode: Value<String>(modeKey)));

  /// 刮削成功后回写主显示源与发行日（发行日上提成列是为了 SQL 排序）。
  Future<int> setGalgameScrapeResult(
    String id, {
    required String? primarySource,
    required String? releaseDate,
  }) =>
      (update(galgames)..where((t) => t.id.equals(id))).write(
        GalgamesCompanion(
          primarySource: Value<String?>(primarySource),
          releaseDate: Value<String?>(releaseDate),
        ),
      );

  /// 某游戏的全部元数据源快照。
  Future<List<GalgameSourceRow>> getGalgameSources(String gameId) =>
      (select(galgameSources)..where((t) => t.gameId.equals(gameId))).get();

  /// 全库元数据源快照，按 gameId 分组（库页一次取全量，避免 N+1）。
  Future<Map<String, List<GalgameSourceRow>>> getAllGalgameSources() async {
    final List<GalgameSourceRow> rows = await select(galgameSources).get();
    final Map<String, List<GalgameSourceRow>> out =
        <String, List<GalgameSourceRow>>{};
    for (final GalgameSourceRow row in rows) {
      (out[row.gameId] ??= <GalgameSourceRow>[]).add(row);
    }
    return out;
  }

  /// 写入/刷新一个源的快照（同 `(gameId, source)` 覆盖）。
  Future<void> upsertGalgameSource(GalgameSourcesCompanion entry) =>
      into(galgameSources).insertOnConflictUpdate(entry);

  /// 移除某游戏的某个源（「换数据源」时清掉旧源）。
  Future<int> deleteGalgameSource(String gameId, String source) =>
      (delete(galgameSources)
            ..where((t) => t.gameId.equals(gameId) & t.source.equals(source)))
          .go();

  /// 落一条游玩会话。返回自增 id。
  Future<int> insertGalgameSession(GalgameSessionsCompanion entry) =>
      into(galgameSessions).insert(entry);

  /// 某游戏的会话流水，按起始时间倒序（详情页时间线，支持分页）。
  Future<List<GalgameSessionRow>> getGalgameSessions(
    String gameId, {
    int limit = 50,
    int offset = 0,
  }) =>
      (select(galgameSessions)
            ..where((t) => t.gameId.equals(gameId))
            ..orderBy([(t) => OrderingTerm.desc(t.startMs)])
            ..limit(limit, offset: offset))
          .get();

  /// 删除单条会话（详情页「删掉这次记录」）。
  Future<int> deleteGalgameSession(int id) =>
      (delete(galgameSessions)..where((t) => t.id.equals(id))).go();

  /// 清空游戏统计，只删除游玩会话事实。
  ///
  /// 游戏库（[galgames]）与首页活动时间线（[activityEvents]）是独立用户数据，
  /// 不能因统计页的「清空」操作被连带删除。
  Future<int> clearAllGalgameStatistics() => delete(galgameSessions).go();

  /// 全库每个游戏的时长合计（秒）+ 会话次数 + 最后游玩毫秒戳。
  ///
  /// 库页排序（按总时长 / 按最后游玩）与详情页 KPI 都吃这一个查询，取代上游的
  /// `game_statistics` 投影表。
  Future<Map<String, (int totalSeconds, int sessionCount, int lastPlayedMs)>>
      getGalgamePlayTotals() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT game_id, '
      'COALESCE(SUM(duration_seconds), 0) AS total_seconds, '
      'COUNT(*) AS session_count, '
      'COALESCE(MAX(end_ms), 0) AS last_played_ms '
      'FROM galgame_sessions GROUP BY game_id',
      readsFrom: {galgameSessions},
    ).get();
    return <String, (int, int, int)>{
      for (final QueryRow row in rows)
        row.read<String>('game_id'): (
          row.read<int>('total_seconds'),
          row.read<int>('session_count'),
          row.read<int>('last_played_ms'),
        ),
    };
  }

  /// 某游戏按天的时长合计（秒），供详情页每日柱状图。
  /// [fromDateKey] / [toDateKey] 是闭区间的 'YYYY-MM-DD'（字典序即时间序）。
  Future<Map<String, int>> getGalgameDailySeconds(
    String gameId, {
    required String fromDateKey,
    required String toDateKey,
  }) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT date_key, COALESCE(SUM(duration_seconds), 0) AS total_seconds '
      'FROM galgame_sessions '
      'WHERE game_id = ? AND date_key >= ? AND date_key <= ? '
      'GROUP BY date_key',
      variables: [
        Variable.withString(gameId),
        Variable.withString(fromDateKey),
        Variable.withString(toDateKey),
      ],
      readsFrom: {galgameSessions},
    ).get();
    return <String, int>{
      for (final QueryRow row in rows)
        row.read<String>('date_key'): row.read<int>('total_seconds'),
    };
  }

  /// 全部游戏按天的游玩时长（秒）与会话数。
  ///
  /// 游戏统计页与首页汇总只认 [galgameSessions] 事实表；`activity_events` 是时间线，
  /// 不能反过来充当时长统计投影。返回全部历史日期，读取端按今日/周/月窗口筛选。
  Future<Map<String, (int totalSeconds, int sessionCount)>>
      getAllGalgameDailyTotals() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT date_key, '
      'COALESCE(SUM(duration_seconds), 0) AS total_seconds, '
      'COUNT(*) AS session_count '
      'FROM galgame_sessions GROUP BY date_key',
      readsFrom: {galgameSessions},
    ).get();
    return <String, (int, int)>{
      for (final QueryRow row in rows)
        row.read<String>('date_key'): (
          row.read<int>('total_seconds'),
          row.read<int>('session_count'),
        ),
    };
  }

  /// 某天全部游戏的时长合计（秒），供首页「今日游戏时长」。
  Future<int> getGalgameSecondsForDay(String dateKey) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT COALESCE(SUM(duration_seconds), 0) AS total_seconds '
      'FROM galgame_sessions WHERE date_key = ?',
      variables: [Variable.withString(dateKey)],
      readsFrom: {galgameSessions},
    ).get();
    return rows.isEmpty ? 0 : rows.first.read<int>('total_seconds');
  }

  /// 首页仪表盘的「数据变了」信号：activity_events / reading_statistics /
  /// video_watch_statistics / video_books 任一表变更即 emit（不带数据，消费方自行
  /// 重查聚合）。首页据此在阅读/观看/导入落库后**自动刷新**热力图 + 时长 + 活动
  /// 时间轴——否则首页在 pushed 阅读器路由下不重建，读完回来仍是旧数据（用户报
  /// 「打开一本书 Activity 还是空的」）。
  ///
  /// 用手动 [StreamController] + [tableUpdates]，**不用** drift keyed `.watch()`：
  /// 后者取消订阅会遗留缓存保留 `Timer.run`，触发 flutter_test `!timersPending`
  /// 让 flutter_tester 永不退出（BUG-834，见 [watchVideoBookUids] 详注）。
  /// tableUpdates 流取消时不安排该 Timer，widget 测试可正常收敛。
  Stream<void> watchDashboardDataChanges() {
    late final StreamController<void> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<void>(
      onListen: () {
        updatesSub = tableUpdates(
          TableUpdateQuery
              .onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
            activityEvents,
            readingStatistics,
            videoWatchStatistics,
            videoBooks,
          ]),
        ).listen((_) {
          if (!controller.isClosed) controller.add(null);
        });
      },
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// OVERWRITE 语义：把 (title, dateKey) 桶设为绝对值（对照 [setReadingStatistic]，
  /// 供云聚合合并写回；[addVideoWatchStatistic] 是累加，云合并禁用会重复计数）。
  Future<void> setVideoWatchStatistic(VideoWatchStatisticsCompanion stat) =>
      transaction(() async {
        // v39：本地行按 bookUid 键控，但互通聚合线协议仍是 title 粒度。OVERWRITE
        // 语义 =「删该 (title,dateKey) 全部行（含 per-uid 行）→ 写单一 NULL-uid
        // 权威行」——沿用旧“每 (title,date) 一行”语义、避免与 per-uid 行叠加双计；
        // 代价是启用互通统计同步的库该日行退化回 title 粒度（协议升级 per-uid 前
        // 的已知限制，见 UI v2 计划文档）。
        //
        // v76（review3-5，与 setLookupCount 的 review-5 守卫同律）：wire 值不超过
        // 本地全部行之和 → 完全 no-op。物化端按 title 求和上行（_foldVideoStatRows）
        // 后，sync 自回声恒等 → 不塌缩，per-uid 行不再被每轮同步周期性抹掉（塌缩
        // 还会顺带毁掉按 bookUid 收历史 title 的删除墓碑考古）。塌缩只发生在 wire
        // 真知道更多时。
        final List<VideoWatchStatisticRow> rows =
            await (select(videoWatchStatistics)
                  ..where((t) =>
                      t.title.equals(stat.title.value) &
                      t.dateKey.equals(stat.dateKey.value)))
                .get();
        int sumChars = 0, sumMs = 0;
        for (final VideoWatchStatisticRow r in rows) {
          sumChars += r.subtitleChars;
          sumMs += r.watchTimeMs;
        }
        final int wireChars =
            stat.subtitleChars.present ? stat.subtitleChars.value : 0;
        final int wireMs =
            stat.watchTimeMs.present ? stat.watchTimeMs.value : 0;
        if (rows.isNotEmpty && wireChars <= sumChars && wireMs <= sumMs) {
          return;
        }
        // 塌缩时逐列取 max(wire, 本地和)（review4-2）：守卫是两列 AND，单列超出
        // 就整体塌缩——若照抄 wire 值，另一列在「物化→往返→应用」窗口里的本地
        // 新增（还没上过行）会被砍掉，违反 MAX-union 单调。lastModified 同取 max。
        int maxLastModified =
            stat.lastModified.present ? stat.lastModified.value : 0;
        for (final VideoWatchStatisticRow r in rows) {
          if (r.lastModified > maxLastModified) {
            maxLastModified = r.lastModified;
          }
        }
        await (delete(videoWatchStatistics)
              ..where((t) =>
                  t.title.equals(stat.title.value) &
                  t.dateKey.equals(stat.dateKey.value)))
            .go();
        await into(videoWatchStatistics).insert(
          VideoWatchStatisticsCompanion.insert(
            title: stat.title.value,
            bookUid: stat.bookUid,
            dateKey: stat.dateKey.value,
            subtitleChars: wireChars > sumChars ? wireChars : sumChars,
            watchTimeMs: wireMs > sumMs ? wireMs : sumMs,
            lastModified: maxLastModified,
          ),
        );
      });

  // ── video hourly logs ───────────────────────────────────────────
  Future<void> addVideoHourlyWatchTime({
    required String dateKey,
    required int hour,
    required int deltaMs,
  }) =>
      transaction(() async {
        final existing = await (select(videoHourlyLogs)
              ..where((t) => t.dateKey.equals(dateKey) & t.hour.equals(hour)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(videoHourlyLogs)
                ..where((t) => t.id.equals(existing.id)))
              .write(VideoHourlyLogsCompanion(
            watchTimeMs: Value(existing.watchTimeMs + deltaMs),
          ));
        } else {
          await into(videoHourlyLogs).insert(
            VideoHourlyLogsCompanion.insert(
              dateKey: dateKey,
              hour: hour,
              watchTimeMs: deltaMs,
            ),
          );
        }
      });

  /// P4 写侧收敛（2026-08 数据层重构）：视频观看统计**累加写的唯一落库入口**
  /// （tick/桶粒度，供 VideoWatchTracker 的 flush 与字幕字数路径）。
  ///
  /// 同一事务内逐桶写小时账本（[addVideoHourlyWatchTime]）与日聚合投影
  /// （[addVideoWatchStatistic]），**桶归属零改动**——dateKey/hour 由调用方按各桶
  /// 自身时刻拆好（splitWatchTime），跨午夜正确归两天依赖于此。此前接线是同一次
  /// flush 两次独立 await 各自 fail-open，hourly 与 daily 可能不同步丢；收敛后
  /// 两表同一事务、要么都落要么都不落。
  ///
  /// [subtitleChars] > 0 时把字幕字数按 [subtitleCharsDateKey]（调用方按 cue 时刻
  /// 派生）累加进日聚合投影；字幕字数不进小时账本（它只记观看时长）。
  ///
  /// activity 行（addActivityEvent, watch）**刻意不在此**：它是 session 事件
  /// （stop 时刻 dateKey + session 总量），与本入口的桶粒度天然不同构——跨午夜时
  /// activity 全额归 stop 日、桶各归各日，两边数字与 dateKey 的口径差是**故意的**
  /// （ed2f36443f）。不得从桶派生 activity 行，也不得「顺手统一」两边 dateKey，
  /// 否则引入跨午夜归属 bug。
  Future<void> recordWatchFlush({
    required String title,
    required String bookUid,
    List<(String dateKey, int hour, int watchMs)> buckets = const <(
      String,
      int,
      int
    )>[],
    int subtitleChars = 0,
    String? subtitleCharsDateKey,
  }) {
    if (subtitleChars > 0 && subtitleCharsDateKey == null) {
      throw ArgumentError(
          'recordWatchFlush: subtitleChars > 0 需要 subtitleCharsDateKey');
    }
    return transaction(() async {
      for (final (String dateKey, int hour, int watchMs) in buckets) {
        await addVideoHourlyWatchTime(
            dateKey: dateKey, hour: hour, deltaMs: watchMs);
        // 逐桶配各自 dateKey：跨午夜正确归两天。
        await addVideoWatchStatistic(
          title: title,
          dateKey: dateKey,
          subtitleChars: 0,
          watchTimeMs: watchMs,
          bookUid: bookUid,
        );
      }
      if (subtitleChars > 0) {
        await addVideoWatchStatistic(
          title: title,
          dateKey: subtitleCharsDateKey!,
          subtitleChars: subtitleChars,
          watchTimeMs: 0,
          bookUid: bookUid,
        );
      }
    });
  }

  Future<List<VideoHourlyLogRow>> getVideoHourlyLogsForDate(String dateKey) =>
      (select(videoHourlyLogs)..where((t) => t.dateKey.equals(dateKey))).get();

  /// 逐行读取全部视频小时日志，供云聚合同步 materialize 快照（TODO-1056 phase B）。
  Future<List<VideoHourlyLogRow>> getAllVideoHourlyLogs() =>
      select(videoHourlyLogs).get();

  /// OVERWRITE 语义：把 (dateKey, hour) 桶设为绝对值 [watchTimeMs]（对照
  /// [addVideoHourlyWatchTime] 的累加）。云聚合合并已在 Dart 侧算好 MAX。
  Future<void> setVideoHourlyLog({
    required String dateKey,
    required int hour,
    required int watchTimeMs,
  }) =>
      into(videoHourlyLogs).insert(
        VideoHourlyLogsCompanion.insert(
          dateKey: dateKey,
          hour: hour,
          watchTimeMs: watchTimeMs,
        ),
        onConflict: DoUpdate(
          (_) => VideoHourlyLogsCompanion(watchTimeMs: Value(watchTimeMs)),
          target: [videoHourlyLogs.dateKey, videoHourlyLogs.hour],
        ),
      );

  /// 仅当当前 completed_at 为 null 时写入（幂等首次完成；重看不覆盖）。
  Future<void> markVideoCompleted(String bookUid, DateTime completedAt) =>
      (update(videoBooks)
            ..where((t) => t.bookUid.equals(bookUid) & t.completedAt.isNull()))
          .write(VideoBooksCompanion(completedAt: Value(completedAt)));

  // ── favorite words ──────────────────────────────────────────────
  /// 收藏一个词条（幂等：(expression, reading, sourceType) 已存在则跳过）。
  /// 返回 true 表示这次新增了收藏，false 表示已收藏过。
  Future<bool> addFavoriteWord({
    required String expression,
    required String reading,
    required String glossary,
    required String sourceType,
    required String dateKey,
    String? bookKey,
    String title = '',
  }) =>
      transaction(() async {
        final existing = await (select(favoriteWords)
              ..where((t) =>
                  t.expression.equals(expression) &
                  t.reading.equals(reading) &
                  t.sourceType.equals(sourceType)))
            .getSingleOrNull();
        if (existing != null) return false;
        // 删除传播：重新收藏同 (expression,reading,sourceType) → 清其 sync 删除墓碑，
        // 防「取消了又收藏、墓碑还在」被 aggregate 抑制或跨端误删（范式仿插书清碑）。
        await clearSyncDeletionTombstone(SyncTombstoneKind.favoriteword.dbValue,
            FushiDatabase.favoriteWordItemKey(expression, reading, sourceType));
        // TODO-1252：[bookKey] / [title] 记「首次收藏归属书」——收藏时若在阅读器 / 视频
        // 页有书上下文则传入，供 per-book/video tile 聚合；无书来源保持 null / ''（只进
        // 汇总）。uniqueKey 仍 {expression, reading, sourceType} 全局去重，归属标签是新增
        // 旁路信息，不改去重 / 汇总 / 同步语义。
        await into(favoriteWords).insert(
          FavoriteWordsCompanion.insert(
            expression: expression,
            reading: Value(reading),
            glossary: Value(glossary),
            sourceType: sourceType,
            bookKey: Value(bookKey),
            title: Value(title),
            dateKey: dateKey,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        return true;
      });

  /// 取消收藏（按 (expression, reading, sourceType) 删除）。返回删除的行数。
  ///
  /// [propagateDeletion]（默认 true）：收藏是跨设备 aggregate 并集同步的集合，取消收藏
  /// 若不记墓碑，下次同步会被 peer 快照并回（复活）。故默认写一条 `favoriteword` sync
  /// 删除墓碑——既供 aggregate 消费端抑制并集复活（[AggregateSyncService.applySnapshotToLocal]
  /// 跳过有墓碑的收藏），也发布到远端标记让其他设备逐条确认后也删。消费端删除时传 false 亦可
  /// （幂等：墓碑已存在），此处保留参数以备内部非用户删除路径按需关闭。
  Future<int> removeFavoriteWord({
    required String expression,
    required String reading,
    required String sourceType,
    bool propagateDeletion = true,
  }) async {
    final int removed = await (delete(favoriteWords)
          ..where((t) =>
              t.expression.equals(expression) &
              t.reading.equals(reading) &
              t.sourceType.equals(sourceType)))
        .go();
    if (removed > 0 && propagateDeletion) {
      await writeSyncDeletionTombstone(
          SyncTombstoneKind.favoriteword.dbValue,
          FushiDatabase.favoriteWordItemKey(expression, reading, sourceType),
          DateTime.now().millisecondsSinceEpoch);
    }
    return removed;
  }

  Future<bool> isFavoriteWord({
    required String expression,
    required String reading,
    required String sourceType,
  }) async {
    final row = await (select(favoriteWords)
          ..where((t) =>
              t.expression.equals(expression) &
              t.reading.equals(reading) &
              t.sourceType.equals(sourceType)))
        .getSingleOrNull();
    return row != null;
  }

  /// 取某来源（'book' / 'video'）的全部收藏行，供统计页按 dateKey 分桶计数。
  Future<List<FavoriteWordRow>> getFavoriteWordsBySource(String sourceType) =>
      (select(favoriteWords)..where((t) => t.sourceType.equals(sourceType)))
          .get();

  /// 取全部收藏词，按 createdAt 倒序（最近在前），供收藏夹导出（TODO-829）。
  /// 纯 select，不动 schema。
  Future<List<FavoriteWordRow>> getAllFavoriteWords() =>
      (select(favoriteWords)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  // ── mining statistics ───────────────────────────────────────────
  /// 制卡成功计数 +[delta]：累加到 (sourceType, dateKey) 现有计数。
  Future<void> addMiningCount({
    required String sourceType,
    required String dateKey,
    int delta = 1,
  }) =>
      transaction(() async {
        final existing = await (select(miningStatistics)
              ..where((t) =>
                  t.sourceType.equals(sourceType) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(miningStatistics)
                ..where((t) => t.id.equals(existing.id)))
              .write(MiningStatisticsCompanion(
            count: Value(existing.count + delta),
          ));
        } else {
          await into(miningStatistics).insert(
            MiningStatisticsCompanion.insert(
              sourceType: sourceType,
              dateKey: dateKey,
              count: Value(delta),
            ),
          );
        }
      });

  /// MAX-union semantics: sets the (sourceType, dateKey) bucket to
  /// `max(existing, count)` rather than accumulating. Use this for backup-merge
  /// import — accumulating with [addMiningCount] would double-count on a
  /// re-import of the same backup, breaking the "merge is idempotent" invariant
  /// (mirrors [setReadingStatistic]'s absolute / `mergeStatistics` max
  /// semantics).
  Future<void> setMiningCount({
    required String sourceType,
    required String dateKey,
    required int count,
  }) =>
      transaction(() async {
        final existing = await (select(miningStatistics)
              ..where((t) =>
                  t.sourceType.equals(sourceType) & t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          if (count > existing.count) {
            await (update(miningStatistics)
                  ..where((t) => t.id.equals(existing.id)))
                .write(MiningStatisticsCompanion(count: Value(count)));
          }
        } else {
          await into(miningStatistics).insert(
            MiningStatisticsCompanion.insert(
              sourceType: sourceType,
              dateKey: dateKey,
              count: Value(count),
            ),
          );
        }
      });

  /// 取某来源（'book' / 'video'）的全部制卡计数行，供统计页按 dateKey 分桶。
  Future<List<MiningStatisticRow>> getMiningStatisticsBySource(
          String sourceType) =>
      (select(miningStatistics)..where((t) => t.sourceType.equals(sourceType)))
          .get();

  /// 逐行读取全部制卡计数行（所有来源），供云聚合同步 materialize 快照
  /// （TODO-1056 phase B）。写回用 [setMiningCount]（MAX 语义、幂等）。
  Future<List<MiningStatisticRow>> getAllMiningStatistics() =>
      select(miningStatistics).get();

  // ── lookup / mining per-book counters (TODO-1204) ────────────────
  /// 查词计数 +[delta]：累加到 (title, sourceType, dateKey) 现有行的 [lookupCount]。
  /// 无书查词（首页 / 独立窗 / 歌词）传 [bookKey] = null、[title] = ''（只进全局汇总）。
  /// [bookKey] 仅首次 insert 时落库（供将来同步 / 展示书身份），后续累加不覆盖。
  Future<void> addLookupCount({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    int delta = 1,
  }) =>
      transaction(() async {
        // v76：匹配键含身份（null 归一 ''）——同名不同视频各记各行，不再互串。
        // 遗留 '' 行与新带身份行并存时各自独立累加，读取端按身份分组归并
        // （v39 的 NULL 遗留行共存语义，见 stat_shared）。
        final String identity = bookKey ?? '';
        final existing = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.bookKey.equals(identity) &
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(lookupMiningCounters)
                ..where((t) => t.id.equals(existing.id)))
              .write(LookupMiningCountersCompanion(
            lookupCount: Value(existing.lookupCount + delta),
          ));
        } else {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(identity),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              lookupCount: Value(delta),
            ),
          );
          // 重新查该书/视频的词 = 新活动：清其统计删除墓碑（无书查词 title='' 不立碑
          // 也无碑可清，跳过；TODO-1204 后续）。
          if (title.isNotEmpty) {
            await clearStatisticsTombstone(title, sourceType);
          }
        }
      });

  /// 制卡计数 +[delta]（per-book）：累加到 (title, sourceType, dateKey) 现有行的
  /// [mineCount]。与全局 [addMiningCount] **并行**写（后者不动），只算成功制卡。
  Future<void> addMineCountPerBook({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    int delta = 1,
  }) =>
      transaction(() async {
        // v76：匹配键含身份（同 [addLookupCount]）。
        final String identity = bookKey ?? '';
        final existing = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.bookKey.equals(identity) &
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .getSingleOrNull();
        if (existing != null) {
          await (update(lookupMiningCounters)
                ..where((t) => t.id.equals(existing.id)))
              .write(LookupMiningCountersCompanion(
            mineCount: Value(existing.mineCount + delta),
          ));
        } else {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(identity),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              mineCount: Value(delta),
            ),
          );
          // 重新在该书/视频制卡 = 新活动：清其统计删除墓碑（TODO-1204 后续）。
          if (title.isNotEmpty) {
            await clearStatisticsTombstone(title, sourceType);
          }
        }
      });

  /// P4 写侧收敛（2026-08 数据层重构）：一次成功制卡的**唯一记账入口**。
  ///
  /// 同一事务写全局按日汇总（mining_statistics 经 [addMiningCount]）与 per-book
  /// 计数（lookup_mining_counters 经 [addMineCountPerBook]），dateKey 从 [at]
  /// 经 [statDateKeyOf] 派生一次。此前各制卡面两表各自 await、各自吞异常（半写
  /// 即让恒等式 `MiningStatistics.count == Σ mineCount` 漂移），另有 PDF/漫画
  /// 只写全局漏 per-book（确定性单边偏差）——收敛后数字与时刻只进一次，新写入
  /// 下恒等式结构性成立（存量删除不对称属 B 组议题，不在此修）。
  ///
  /// [bookKey]/[title] 身份键域同 [addMineCountPerBook]（v76 per-identity）：
  /// 无书来源传 null/''，只进全局汇总桶。[title] 是统计聚合键，**恒 raw**
  /// （书行原始 title），不得过 display-title 门面——否则改名前后计数分叉两桶。
  Future<void> recordMiningEvent({
    String? bookKey,
    String title = '',
    required String sourceType,
    required DateTime at,
  }) =>
      transaction(() async {
        final String dateKey = _FushiDbStatistics.statDateKeyOf(at);
        await addMiningCount(sourceType: sourceType, dateKey: dateKey);
        await addMineCountPerBook(
          bookKey: bookKey,
          title: title,
          sourceType: sourceType,
          dateKey: dateKey,
        );
      });

  /// MAX-union 语义（非累加）：把 (title, sourceType, dateKey) 行的 [lookupCount]
  /// 设为 `max(existing, count)`。为将来备份合并 / 云聚合幂等重导留口（本期 sync
  /// 不接；与 [setMiningCount] 同范式）。
  Future<void> setLookupCount({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    required int count,
  }) =>
      transaction(() async {
        // v76：wire 协议冻结在 title 粒度（LookupMiningRecord 的合并键不含
        // bookKey），本地行 v76 起 per-identity 可多行。分支（review-5 /
        // review3-4 后的现行为，注意与 v76 前**不**逐字节一致）：
        //  - 无行：落单行（带 wire metadata 身份，peer-only 桶保住身份）；
        //  - wire 值 ≤ 本地和：完全 no-op（不塌缩，防 sync 自回声周期性抹掉
        //    per-identity 行）；
        //  - 单行且身份与 wire 一致：行内抬升，身份保留；
        //  - 其余（身份错配 / 多行）：塌成单一 '' 权威行——归因不可判，''
        //    如实标未归因。启用同步的库该日行退化回 title 粒度，与视频统计
        //    同为已知限制。
        final rows = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .get();
        if (rows.isEmpty) {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(bookKey ?? ''),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              lookupCount: Value(count),
            ),
          );
          return;
        }
        int sumLookup = 0, sumMine = 0;
        for (final LookupMiningCounterRow r in rows) {
          sumLookup += r.lookupCount;
          sumMine += r.mineCount;
        }
        // wire 值不超过本地和：MAX-union 无可抬升，**完全 no-op**——否则每轮
        // sync 应用都会把 per-identity 行塌回 '' 行，v76 的分身份修复被周期性
        // 回退、tile 数字震荡（review-5）。塌缩只发生在 wire 真的知道更多时。
        if (count <= sumLookup) return;
        // 单行且身份与 wire 一致（review3-4）：行内抬升、身份保留。身份错配
        // （如本地只有 uid-2 行、wire 是混桶 null）不许行内抬——那会把别的视频
        // 的查词记到 uid-2 头上；走下面的 '' 塌缩，如实标未归因。
        final String wireIdentity = bookKey ?? '';
        if (rows.length == 1 && rows.single.bookKey == wireIdentity) {
          await (update(lookupMiningCounters)
                ..where((t) => t.id.equals(rows.single.id)))
              .write(LookupMiningCountersCompanion(lookupCount: Value(count)));
          return;
        }
        await (delete(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .go();
        await into(lookupMiningCounters).insert(
          LookupMiningCountersCompanion.insert(
            bookKey: const Value(''),
            title: Value(title),
            sourceType: sourceType,
            dateKey: dateKey,
            lookupCount: Value(count),
            mineCount: Value(sumMine),
          ),
        );
      });

  /// MAX-union 语义（非累加）：把 (title, sourceType, dateKey) 行的 [mineCount]
  /// 设为 `max(existing, count)`。备份合并 / 云聚合幂等留口（本期 sync 不接）。
  Future<void> setMineCountPerBook({
    String? bookKey,
    String title = '',
    required String sourceType,
    required String dateKey,
    required int count,
  }) =>
      transaction(() async {
        // v76：三分支与 [setLookupCount] 对称，注释见彼处。
        final rows = await (select(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .get();
        if (rows.isEmpty) {
          await into(lookupMiningCounters).insert(
            LookupMiningCountersCompanion.insert(
              bookKey: Value(bookKey ?? ''),
              title: Value(title),
              sourceType: sourceType,
              dateKey: dateKey,
              mineCount: Value(count),
            ),
          );
          return;
        }
        int sumLookup = 0, sumMine = 0;
        for (final LookupMiningCounterRow r in rows) {
          sumLookup += r.lookupCount;
          sumMine += r.mineCount;
        }
        // 与 [setLookupCount] 三分支完全对称（review-5 / review3-4 注释见彼处）。
        if (count <= sumMine) return;
        final String wireIdentity = bookKey ?? '';
        if (rows.length == 1 && rows.single.bookKey == wireIdentity) {
          await (update(lookupMiningCounters)
                ..where((t) => t.id.equals(rows.single.id)))
              .write(LookupMiningCountersCompanion(mineCount: Value(count)));
          return;
        }
        await (delete(lookupMiningCounters)
              ..where((t) =>
                  t.title.equals(title) &
                  t.sourceType.equals(sourceType) &
                  t.dateKey.equals(dateKey)))
            .go();
        await into(lookupMiningCounters).insert(
          LookupMiningCountersCompanion.insert(
            bookKey: const Value(''),
            title: Value(title),
            sourceType: sourceType,
            dateKey: dateKey,
            lookupCount: Value(sumLookup),
            mineCount: Value(count),
          ),
        );
      });

  /// 取某来源（'book' / 'video'）的全部查词/制卡计数行，供统计页汇总 + per-book
  /// tile 按 title 聚合。
  Future<List<LookupMiningCounterRow>> getLookupMiningCountersBySource(
          String sourceType) =>
      (select(lookupMiningCounters)
            ..where((t) => t.sourceType.equals(sourceType)))
          .get();

  /// 逐行读取全部查词/制卡计数行（所有来源），供将来云聚合同步 materialize 快照。
  /// 写回用 [setLookupCount] / [setMineCountPerBook]（MAX 语义、幂等）。
  Future<List<LookupMiningCounterRow>> getAllLookupMiningCounters() =>
      select(lookupMiningCounters).get();

  // ── mined sentences ──────────────────────────────────────────────

  /// 记录一次成功制卡：插入一条历史，并在事务内 trim 掉超额的最旧行。
  /// 定位列（[bookKey]/[sectionIndex]/[normCharOffset]/[normCharLength]）按来源可空——
  /// 独立查词页 / 首页词典制卡无书无章，传 null（展示为不可跳转条目）。
  Future<void> addMinedSentence({
    required String source,
    required String dateKey,
    String expression = '',
    String reading = '',
    String glossary = '',
    String sentence = '',
    String? documentTitle,
    String? chapterLabel,
    String? bookKey,
    int? sectionIndex,
    int? normCharOffset,
    int? normCharLength,
    int? noteId,
  }) =>
      transaction(() async {
        await into(minedSentences).insert(
          MinedSentencesCompanion.insert(
            source: source,
            dateKey: dateKey,
            expression: Value(expression),
            reading: Value(reading),
            glossary: Value(glossary),
            sentence: Value(sentence),
            documentTitle: Value(documentTitle),
            chapterLabel: Value(chapterLabel),
            bookKey: Value(bookKey),
            sectionIndex: Value(sectionIndex),
            normCharOffset: Value(normCharOffset),
            normCharLength: Value(normCharLength),
            noteId: Value(noteId),
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await _trimMinedSentences();
      });

  /// 取全部制卡历史，按 createdAt 倒序（最近在前），供收藏夹页展示。
  Future<List<MinedSentenceRow>> getAllMinedSentences() =>
      (select(minedSentences)..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  /// 删除一条制卡历史（按 id）。返回删除的行数。
  Future<int> removeMinedSentence(int id) =>
      (delete(minedSentences)..where((t) => t.id.equals(id))).go();

  /// 清空全部制卡历史。返回删除的行数。
  Future<int> clearMinedSentences() => delete(minedSentences).go();

  /// 清空全部收藏词（FavoriteWords 表）。返回删除的行数。收藏夹「清空」面板的
  /// 收藏词范围走这里，与 [clearMinedSentences] 对称，仅删本表不触碰其它收藏。
  Future<int> clearAllFavoriteWords() => delete(favoriteWords).go();

  /// 事务内 trim：超过 [FushiDatabase.kMinedSentenceHistoryLimit] 时按 id 升序删除最旧的超额行。
  Future<void> _trimMinedSentences() async {
    final int total = await minedSentences.count().getSingle();
    final int excess = total - FushiDatabase.kMinedSentenceHistoryLimit;
    if (excess <= 0) return;
    final List<MinedSentenceRow> oldest = await (select(minedSentences)
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(excess))
        .get();
    final List<int> ids = oldest.map((r) => r.id).toList(growable: false);
    if (ids.isEmpty) return;
    await (delete(minedSentences)..where((t) => t.id.isIn(ids))).go();
  }
}
