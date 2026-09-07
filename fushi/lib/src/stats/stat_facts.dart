import 'package:fushi_core/fushi_core.dart';

/// 一条学习统计事实的统一形状（v92 统计域重构）。
///
/// 读取侧只认这一种行：`study_segments`（v92 起唯一写入面）与四张 legacy 投影表
/// （`reading_statistics` / `video_watch_statistics` / `reading_hourly_logs` /
/// `video_hourly_logs`，v92 前的历史数据、冻结不再写）都映射到它。页面 / 首页 /
/// 活动流不再各自读表、各自累加。
///
/// 身份：[mediaKey] = 书 bookKey / 视频 bookUid / 游戏 galgames.id；legacy 行里
/// 没有身份的（视频 v39 前 NULL-uid 行、阅读行按 title 反查库表失败）为 ''，
/// 读取端按 [title] 回退分组（沿用 v76 的 [groupStatRowsByIdentity] 契约）。
class StatFact {
  const StatFact({
    required this.mediaKind,
    required this.mediaKey,
    required this.title,
    required this.format,
    required this.dateKey,
    required this.hour,
    required this.ms,
    required this.chars,
    required this.pages,
    required this.lastActiveMs,
  });

  /// 'book' | 'video' | 'game'（[ActivityMediaKind.dbValue]）。
  final String mediaKind;

  /// 稳定媒体身份；'' = legacy 无身份行。
  final String mediaKey;

  /// 展示快照 / 无身份行的回退分组键。
  final String title;

  /// 'epub' | 'pdf' | 'manga' | ''（非书面或 legacy 未区分）。
  final String format;

  final String dateKey;

  /// 本地小时；日面事实（legacy 日行）为 -1。
  final int hour;

  final int ms;
  final int chars;
  final int pages;

  /// 该事实最后活跃时刻（epoch 毫秒；legacy 日行取 lastModified，段取 endAt），
  /// 「最近阅读 / 观看」排序用。
  final int lastActiveMs;

  bool get isBook => mediaKind == kActivityMediaBook;
  bool get isVideo => mediaKind == kActivityMediaVideo;
  bool get isGame => mediaKind == kActivityMediaGame;
  bool get isManga => format == BookFormat.manga.dbValue;

  /// 分组键：有身份用身份，否则 title（legacy 回退）。
  String get identityKey => mediaKey.isNotEmpty ? mediaKey : title;
}

/// 库表按 title 分桶（BUG-2216：legacy 阅读行只有 title，反查库表补身份时同名
/// ≥2 本不能贴给任意一本——宁可留成无身份组也不错贴）。
Map<String, List<EpubBookRow>> _booksByTitle(Iterable<EpubBookRow> rows) {
  final Map<String, List<EpubBookRow>> out = <String, List<EpubBookRow>>{};
  for (final EpubBookRow r in rows) {
    out.putIfAbsent(r.title, () => <EpubBookRow>[]).add(r);
  }
  return out;
}

/// title → bookKey 的**唯一**反查表：库里恰好一本叫这个名字才进表。页面给 legacy
/// 无身份行 / 无身份 tile 反查 bookKey（合集归属、override 书名、删除）都只许用它。
Map<String, String> uniqueBookKeyByTitle(Iterable<EpubBookRow> rows) =>
    <String, String>{
      for (final MapEntry<String, List<EpubBookRow>> e in _booksByTitle(
        rows,
      ).entries)
        if (e.value.length == 1) e.key: e.value.single.bookKey,
    };

/// 库里同名 ≥2 本的 title 集合：喂 `groupStatFactsByIdentity` 的吸收否决（与视频域
/// `computeVideoStats(ambiguousTitles:)` 同判据——库表判同名时，legacy 无身份行不许
/// 吸进任何身份组）。
Set<String> ambiguousBookTitles(Iterable<EpubBookRow> rows) => <String>{
  for (final MapEntry<String, List<EpubBookRow>> e in _booksByTitle(
    rows,
  ).entries)
    if (e.value.length >= 2) e.key,
};

/// 一次加载得到的全部统计事实，分**两面**：
///  * [daily]：日总量 / per-media / 热力图 / 趋势用——legacy 日汇总行 + 全部段；
///  * [hourly]：今日按小时图用——legacy 小时行 + 全部段。
///
/// 同一个段在两面各出现一次；legacy 的日行与小时行是同一段时间的两个**不相交**投影
/// （一个有 title 没 hour，一个有 hour 没 title），所以绝不能并进同一列表求和——
/// 两面分列，读方按用途只挑一面，结构上杜绝双计。
/// 某条阅读域事实是否属于这本书：有身份看 mediaKey，legacy 无身份行按 title 回退
/// （与阅读统计页按书分组同一规则）。唯一判据，别在页面里再拼一遍。
bool statFactBelongsToBook(
  StatFact f, {
  required String bookKey,
  String? title,
}) {
  if (f.mediaKey.isNotEmpty) return f.mediaKey == bookKey;
  return title != null && title.isNotEmpty && f.title == title;
}

class StatFacts {
  const StatFacts({
    required this.daily,
    required this.hourly,
    required this.segments,
    required this.legacyActivity,
    required this.epubRows,
    this.recentGameSessions = const <GalgameSessionRow>[],
    this.gameNamesById = const <String, String>{},
    this.activityLimit = 200,
  });

  static const StatFacts empty = StatFacts(
    daily: <StatFact>[],
    hourly: <StatFact>[],
    segments: <StudySegmentRow>[],
    legacyActivity: <ActivityEventRow>[],
    epubRows: <EpubBookRow>[],
  );

  /// 最近的游玩会话（v92 起游玩只写 galgame_sessions，活动流从这里合成）。
  final List<GalgameSessionRow> recentGameSessions;

  /// galgames.id → 显示名（合成游玩事件的 title 快照）。
  final Map<String, String> gameNamesById;

  /// [activityRows] 的条数上限（与 legacy 行的取数上限同值）。
  final int activityLimit;

  /// **活动流的唯一数据源**：legacy 活动行 ∪ 段合成行 ∪ 游玩会话合成行，按精确
  /// 时刻倒序、截到 [activityLimit]。首页时间轴与游戏首页时间线都只吃它。
  List<ActivityEventRow> get activityRows {
    final List<ActivityEventRow> all =
        <ActivityEventRow>[
          ...legacyActivity,
          ...segmentsAsActivityRows(segments),
          ...galgameSessionsAsActivityRows(recentGameSessions, gameNamesById),
        ]..sort(
          (ActivityEventRow a, ActivityEventRow b) =>
              b.timestampMs.compareTo(a.timestampMs),
        );
    return all.length <= activityLimit ? all : all.sublist(0, activityLimit);
  }

  final List<StatFact> daily;
  final List<StatFact> hourly;

  /// 原始段（活动流的 session 归并需要 startAt / endAt）。
  final List<StudySegmentRow> segments;

  /// legacy `activity_events` 行（v92 前的 read / watch / game 行 + 至今仍在写的
  /// `added` 导入事件）。活动流把它与 [segmentsAsActivityRows] 并集。
  final List<ActivityEventRow> legacyActivity;

  /// 加载 legacy 阅读行身份时顺带取的书表（页面复用：title→bookKey / format）。
  final List<EpubBookRow> epubRows;

  Iterable<StatFact> get dailyBooks => daily.where((StatFact f) => f.isBook);

  /// 阅读域日面里属于某本书的行（阅读器内统计浮层 / 按书切片共用）：身份优先
  /// `mediaKey == bookKey`，legacy 无身份行按 title 回退——判据见 [statFactBelongsToBook]。
  Iterable<StatFact> dailyBooksFor({required String bookKey, String? title}) =>
      dailyBooks.where(
        (StatFact f) =>
            statFactBelongsToBook(f, bookKey: bookKey, title: title),
      );
  Iterable<StatFact> get dailyVideos => daily.where((StatFact f) => f.isVideo);
  Iterable<StatFact> get dailyGames => daily.where((StatFact f) => f.isGame);
}

/// 从 DB 加载统一事实面（**唯一**读取入口；阅读 / 视频 / 游戏统计页与首页都走它）。
///
/// [activityLimit] 是 legacy 活动行的条数上限（首页时间轴只看最近 200 条）；统计页
/// 不需要活动行可传 0。
Future<StatFacts> loadStatFacts(
  FushiDatabase db, {
  int activityLimit = 200,
}) async {
  final List<EpubBookRow> epubRows = await db.getAllEpubBooks();
  // BUG-2216：同名 ≥2 本时不反查（后者覆盖前者 = 把一本书的历史错贴给另一本）。
  final Map<String, EpubBookRow> bookByTitle = <String, EpubBookRow>{
    for (final MapEntry<String, List<EpubBookRow>> e in _booksByTitle(
      epubRows,
    ).entries)
      if (e.value.length == 1) e.key: e.value.single,
  };
  final List<StatFact> daily = <StatFact>[];
  final List<StatFact> hourly = <StatFact>[];

  // legacy 日行：阅读按 title 反查库表补身份与 format（查不到 = 书已删或同名歧义，
  // 身份 ''、format ''，读取端按 unique-title 吸收 / 无身份分组）；视频 v39 起自带
  // bookUid。
  for (final ReadingStatisticRow r in await db.getAllReadingStatistics()) {
    final EpubBookRow? book = bookByTitle[r.title];
    daily.add(
      StatFact(
        mediaKind: kActivityMediaBook,
        mediaKey: book?.bookKey ?? '',
        title: r.title,
        format: book?.format ?? '',
        dateKey: r.dateKey,
        hour: -1,
        ms: r.readingTimeMs,
        chars: r.charactersRead,
        pages: r.pagesRead,
        lastActiveMs: r.lastStatisticModified,
      ),
    );
  }
  for (final VideoWatchStatisticRow w
      in await db.getAllVideoWatchStatistics()) {
    daily.add(
      StatFact(
        mediaKind: kActivityMediaVideo,
        mediaKey: w.bookUid ?? '',
        title: w.title,
        format: '',
        dateKey: w.dateKey,
        hour: -1,
        ms: w.watchTimeMs,
        chars: w.subtitleChars,
        pages: 0,
        lastActiveMs: w.lastModified,
      ),
    );
  }
  // legacy 小时行（无身份、无 title）。
  for (final ReadingHourlyLogRow h in await db.getAllReadingHourlyLogs()) {
    hourly.add(
      StatFact(
        mediaKind: kActivityMediaBook,
        mediaKey: '',
        title: '',
        format: h.format,
        dateKey: h.dateKey,
        hour: h.hour,
        ms: h.readingTimeMs,
        chars: 0,
        pages: 0,
        lastActiveMs: 0,
      ),
    );
  }
  for (final VideoHourlyLogRow h in await db.getAllVideoHourlyLogs()) {
    hourly.add(
      StatFact(
        mediaKind: kActivityMediaVideo,
        mediaKey: '',
        title: '',
        format: '',
        dateKey: h.dateKey,
        hour: h.hour,
        ms: h.watchTimeMs,
        chars: 0,
        pages: 0,
        lastActiveMs: 0,
      ),
    );
  }
  // 游戏时长真相源 galgame_sessions（v55 起就是事实表）：按 (game, day) 进日面。
  for (final (String gameId, String dateKey, int seconds)
      in await db.getGalgameDailySecondsByGame()) {
    daily.add(
      StatFact(
        mediaKind: kActivityMediaGame,
        mediaKey: gameId,
        title: '',
        format: '',
        dateKey: dateKey,
        hour: -1,
        ms: seconds * 1000,
        chars: 0,
        pages: 0,
        lastActiveMs: 0,
      ),
    );
  }
  // legacy 活动行：v92 前的游戏 hook 字数只存在这里（chars-only game 行）；
  // read / watch 行的时长 / 字数已在日投影里，**只**取 game 的字数进日面，
  // 时长一律不取（时长真相源是 galgame_sessions，取了就双计）。
  final List<ActivityEventRow> activity = await db.getRecentActivityEvents(
    limit: activityLimit,
  );
  for (final ActivityEventRow e in await db.getRecentActivityEvents(
    limit: 1 << 31,
    eventTypes: const <String>[kActivityGame],
  )) {
    final int chars = e.charsDelta ?? 0;
    if (chars <= 0) continue;
    daily.add(
      StatFact(
        mediaKind: kActivityMediaGame,
        mediaKey: e.mediaKey ?? '',
        title: e.title,
        format: '',
        dateKey: e.dateKey,
        hour: -1,
        ms: 0,
        chars: chars,
        pages: 0,
        lastActiveMs: e.timestampMs,
      ),
    );
  }
  // v92 段：两面各一份。
  final List<StudySegmentRow> segments = await db.getStudySegments();
  for (final StudySegmentRow s in segments) {
    // **写零的段不进事实面**。`zeroStudySegmentsOnDays`（时段明细里长按删除走的那条）
    // 只把行写成零而不删行——必须删的是同步语义：真删行会被对端的旧数据按 LWW 复活，
    // 写零才能跨端传播「这段不算了」。
    //
    // 于是过滤责任落在读侧。不过滤的话，被删掉的那条会以「0 字」原地复活：sheet 聚合
    // 侧对任何命中该 dateKey 的 fact 都建 entry，渲染侧 ms==0 就走 formatStatChars(0)。
    // 用户看到的就是「删了、刷新、它又回来了」。零行同样会污染排行、热力图等所有吃
    // StatFacts.daily 的消费方。
    //
    // 判据与 [segmentsAsActivityRows] 逐字一致——**同一件事只能有一条判据**，
    // 两处分别写就是给「活动流干净、统计页脏」这种半修好状态留门。
    if (s.durationMs <= 0 && s.chars <= 0 && s.pages <= 0) continue;
    final StatFact fact = StatFact(
      mediaKind: s.mediaKind,
      mediaKey: s.mediaKey,
      title: s.title,
      format: s.format,
      dateKey: s.dateKey,
      hour: s.hour,
      ms: s.durationMs,
      chars: s.chars,
      pages: s.pages,
      lastActiveMs: s.endAt,
    );
    daily.add(fact);
    hourly.add(fact);
  }
  // 游玩会话（活动流合成「游玩」事件用；activityLimit 为 0 时不取）。
  final List<GalgameSessionRow> recentGameSessions = activityLimit <= 0
      ? const <GalgameSessionRow>[]
      : await db.getRecentGalgameSessions(limit: activityLimit);
  final Map<String, String> gameNamesById = recentGameSessions.isEmpty
      ? const <String, String>{}
      : <String, String>{
          for (final GalgameRow g in await db.getAllGalgames()) g.id: g.name,
        };
  return StatFacts(
    daily: daily,
    hourly: hourly,
    segments: segments,
    legacyActivity: activity,
    epubRows: epubRows,
    recentGameSessions: recentGameSessions,
    gameNamesById: gameNamesById,
    activityLimit: activityLimit,
  );
}

/// 把游玩会话映射成活动流行（id=0 哨兵）：v92 前 `GalgamePlayTracker` 会在
/// galgame_sessions 之外再写一条带 durationMs 的 game 活动行（第二本账），现在
/// 只在读取时合成。title 取当前库内显示名（游戏已删则空串，展示层回退 mediaKey）。
List<ActivityEventRow> galgameSessionsAsActivityRows(
  List<GalgameSessionRow> sessions,
  Map<String, String> gameNamesById,
) {
  return <ActivityEventRow>[
    for (final GalgameSessionRow s in sessions)
      ActivityEventRow(
        id: 0,
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: gameNamesById[s.gameId] ?? '',
        mediaKey: s.gameId,
        dateKey: s.dateKey,
        timestampMs: s.endMs,
        durationMs: s.durationSeconds * 1000,
        charsDelta: null,
      ),
  ];
}

/// 把 v92 段映射成活动流行（id=0 哨兵，display-only 不落库——与互联远端行同一
/// 手法），喂既有 [aggregateActivityEvents]：同日同媒体多段按 30 分钟 gap 归并成
/// session 数，时长 / 字数求和。eventType 按 kind：book→read、video→watch、game→game。
List<ActivityEventRow> segmentsAsActivityRows(List<StudySegmentRow> segments) {
  return <ActivityEventRow>[
    for (final StudySegmentRow s in segments)
      if (s.durationMs > 0 || s.chars > 0 || s.pages > 0)
        ActivityEventRow(
          id: 0,
          eventType: switch (s.mediaKind) {
            kActivityMediaVideo => kActivityWatch,
            kActivityMediaGame => kActivityGame,
            _ => kActivityRead,
          },
          mediaType: s.mediaKind,
          title: s.title,
          mediaKey: s.mediaKey,
          dateKey: s.dateKey,
          timestampMs: s.endAt,
          durationMs: s.durationMs,
          charsDelta: s.chars,
        ),
  ];
}

/// 首页「今日目标」与阅读统计页目标卡共用的**同一条**口径：给定日面行的当日字数
/// 合计。目标概念是「每日学习目标」——传整张日面（[StatFacts.daily]）时覆盖阅读 +
/// 视频字幕 + 游戏 hook 三个来源，与热力图「全部」档同覆盖面；只算某一域时传对应
/// 切片（如 [StatFacts.dailyBooks]）。v92 曾把分子硬编码成只算阅读域，纯视频 /
/// 游戏日目标恒 0、与上方热力图对不上（BUG-1993）——现在函数只按 dateKey 求和，
/// 域由调用方传的行集决定，没有特殊情况。目标偏好键沿用 `readingGoalDailyChars`
/// （存量持久化名冻结，语义已是学习目标）。
int studyGoalCharsForDay(Iterable<StatFact> daily, String dateKey) {
  int total = 0;
  for (final StatFact f in daily) {
    if (f.dateKey == dateKey) total += f.chars;
  }
  return total;
}
