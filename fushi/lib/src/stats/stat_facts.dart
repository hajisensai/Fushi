import 'package:fushi_core/fushi_core.dart';

/// 一条学习统计事实的统一形状（v90 统计域重构）。
///
/// 读取侧只认这一种行：`study_segments`（v90 起唯一写入面）与四张 legacy 投影表
/// （`reading_statistics` / `video_watch_statistics` / `reading_hourly_logs` /
/// `video_hourly_logs`，v90 前的历史数据、冻结不再写）都映射到它。页面 / 首页 /
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

/// 一次加载得到的全部统计事实，分**两面**：
///  * [daily]：日总量 / per-media / 热力图 / 趋势用——legacy 日汇总行 + 全部段；
///  * [hourly]：今日按小时图用——legacy 小时行 + 全部段。
///
/// 同一个段在两面各出现一次；legacy 的日行与小时行是同一段时间的两个**不相交**投影
/// （一个有 title 没 hour，一个有 hour 没 title），所以绝不能并进同一列表求和——
/// 两面分列，读方按用途只挑一面，结构上杜绝双计。
class StatFacts {
  const StatFacts({
    required this.daily,
    required this.hourly,
    required this.segments,
    required this.legacyActivity,
    required this.epubRows,
  });

  static const StatFacts empty = StatFacts(
    daily: <StatFact>[],
    hourly: <StatFact>[],
    segments: <StudySegmentRow>[],
    legacyActivity: <ActivityEventRow>[],
    epubRows: <EpubBookRow>[],
  );

  final List<StatFact> daily;
  final List<StatFact> hourly;

  /// 原始段（活动流的 session 归并需要 startAt / endAt）。
  final List<StudySegmentRow> segments;

  /// legacy `activity_events` 行（v90 前的 read / watch / game 行 + 至今仍在写的
  /// `added` 导入事件）。活动流把它与 [segmentsAsActivityRows] 并集。
  final List<ActivityEventRow> legacyActivity;

  /// 加载 legacy 阅读行身份时顺带取的书表（页面复用：title→bookKey / format）。
  final List<EpubBookRow> epubRows;

  Iterable<StatFact> get dailyBooks => daily.where((StatFact f) => f.isBook);
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
  final Map<String, EpubBookRow> bookByTitle = <String, EpubBookRow>{
    for (final EpubBookRow r in epubRows) r.title: r,
  };
  final List<StatFact> daily = <StatFact>[];
  final List<StatFact> hourly = <StatFact>[];

  // legacy 日行：阅读按 title 反查库表补身份与 format（查不到 = 书已删，身份 ''、
  // format ''，按 title 分组、归普通书）；视频 v39 起自带 bookUid。
  for (final ReadingStatisticRow r in await db.getAllReadingStatistics()) {
    final EpubBookRow? book = bookByTitle[r.title];
    daily.add(StatFact(
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
    ));
  }
  for (final VideoWatchStatisticRow w in await db.getAllVideoWatchStatistics()) {
    daily.add(StatFact(
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
    ));
  }
  // legacy 小时行（无身份、无 title）。
  for (final ReadingHourlyLogRow h in await db.getAllReadingHourlyLogs()) {
    hourly.add(StatFact(
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
    ));
  }
  for (final VideoHourlyLogRow h in await db.getAllVideoHourlyLogs()) {
    hourly.add(StatFact(
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
    ));
  }
  // 游戏时长真相源 galgame_sessions（v55 起就是事实表）：按 (game, day) 进日面。
  for (final (String gameId, String dateKey, int seconds)
      in await db.getGalgameDailySecondsByGame()) {
    daily.add(StatFact(
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
    ));
  }
  // legacy 活动行：v90 前的游戏 hook 字数只存在这里（chars-only game 行）；
  // read / watch 行的时长 / 字数已在日投影里，**只**取 game 的字数进日面，
  // 时长一律不取（时长真相源是 galgame_sessions，取了就双计）。
  final List<ActivityEventRow> activity =
      await db.getRecentActivityEvents(limit: activityLimit);
  for (final ActivityEventRow e in await db.getRecentActivityEvents(
    limit: 1 << 31,
    eventTypes: const <String>[kActivityGame],
  )) {
    final int chars = e.charsDelta ?? 0;
    if (chars <= 0) continue;
    daily.add(StatFact(
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
    ));
  }
  // v90 段：两面各一份。
  final List<StudySegmentRow> segments = await db.getStudySegments();
  for (final StudySegmentRow s in segments) {
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
  return StatFacts(
    daily: daily,
    hourly: hourly,
    segments: segments,
    legacyActivity: activity,
    epubRows: epubRows,
  );
}

/// 把 v90 段映射成活动流行（id=0 哨兵，display-only 不落库——与互联远端行同一
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

/// 首页「今日目标」与阅读统计页共用的**同一条**口径：阅读域（普通书 + 漫画）当日
/// 字数。首页此前把书字 + 字幕字 + hook 字三种「字」相加当分子、统计页只算阅读域，
/// 两处共用一个目标偏好却永远对不上——现在只有这一个函数。
int readingGoalCharsForDay(Iterable<StatFact> daily, String dateKey) {
  int total = 0;
  for (final StatFact f in daily) {
    if (f.isBook && f.dateKey == dateKey) total += f.chars;
  }
  return total;
}
