/// 视频海报刮削流水线的共享数据契约。
///
/// 五层流水线（成功率从高到低逐层兜底）：
/// ① sidecar 识别（poster.jpg / tvshow.nfo，零网络）
/// ② 文件名/目录名解析（anitomy 式规则，产出 [ParsedMediaName]）
/// ③ 标题归一化（繁简/全半角/罗马数字季度/副标题拆分）
/// ④ 匹配（离线别名库 → Bangumi → TMDB，产出 [ScrapeCandidate]）
/// ⑤ 打分校验（[MatchScorer] 产出 [MatchDecision]，置信度分级）
///
/// 本文件只放跨模块共享的纯数据类型，**不放任何实现逻辑**；
/// 各层实现见同目录 `filename_parser.dart` / `title_normalizer.dart` /
/// `offline_index.dart` / `match_scorer.dart` / `bangumi_client.dart` /
/// `tmdb_client.dart` / `sidecar_scanner.dart` / `cover_scraper_service.dart`。
library;

/// 从文件名/目录名解析出的结构化信息（解析层输出）。
class ParsedMediaName {
  const ParsedMediaName({
    required this.title,
    this.secondaryTitle,
    this.episode,
    this.season,
    this.year,
    this.releaseGroup,
    this.resolution,
    this.isMovieHint = false,
  });

  /// 主标题（已剥离括号块/集数/分辨率等噪音，未做归一化）。
  final String title;

  /// 副标题（`～xxx～` / `-xxx-` 等装饰分隔出的部分），可能为空。
  final String? secondaryTitle;

  /// 集数（`- 04` / `第04话` / `E04` / `[04]`），解析不出为 null。
  final int? episode;

  /// 季度（`第三季` / `S3` / `Ⅲ` / `2nd Season` / `Part 2`），解析不出为 null。
  final int? season;

  /// 年份（`(2026)` / `[2026]`），解析不出为 null。
  final int? year;

  /// 字幕组/发布组（首个 `[xxx]` 块，被分类为组名的）。
  final String? releaseGroup;

  /// 分辨率标签（`1080p` / `1920x1080` 等，原文保留）。
  final String? resolution;

  /// 是否疑似电影（`剧场版` / `Movie` / `映画` 等关键词）。
  final bool isMovieHint;
}

/// 候选条目来源。
enum ScrapeSource { offlineDb, bangumi, tmdb, manualUrl }

/// 条目类型（用于打分时与 [ParsedMediaName.isMovieHint] 互验）。
enum ScrapeEntryType { tv, movie, ova, special, unknown }

/// 一个可用的匹配候选（匹配层输出，来自离线库或在线 API）。
class ScrapeCandidate {
  const ScrapeCandidate({
    required this.source,
    required this.entryId,
    required this.title,
    this.aliases = const <String>[],
    this.year,
    this.type = ScrapeEntryType.unknown,
    this.episodeCount,
    required this.posterUrl,
    this.detailUrl,
    this.ratingText,
  });

  final ScrapeSource source;

  /// 源内唯一 id（Bangumi subject id / TMDB id / 离线库 anime 索引等），字符串化存储。
  final String entryId;

  /// 展示用主标题（优先中文）。
  final String title;

  /// 全部别名/异语言标题（打分时参与相似度计算）。
  final List<String> aliases;

  final int? year;
  final ScrapeEntryType type;

  /// 总集数（离线库/API 提供时），用于集数一致性校验。
  final int? episodeCount;

  /// 海报图 URL（下载层负责落地到 video_covers/）。
  final String posterUrl;

  /// 条目详情页 URL（UI「查看条目」用），可为 null。
  final String? detailUrl;

  /// 评分展示文本（如 `Bangumi 8.1`），可为 null。
  final String? ratingText;
}

// ─────────────────────── 条目级元数据（「抄 Bangumi」）───────────────────────

/// 条目标签（Bangumi `tags`：名字 + 打标人数，按热度降序）。
class ScrapeTag {
  const ScrapeTag({required this.name, this.count = 0});

  final String name;

  /// 打该标签的人数（Bangumi 提供；无则 0）。
  final int count;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        if (count > 0) 'count': count,
      };

  static ScrapeTag? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final Object? count = json['count'];
    return ScrapeTag(
      name: name.trim(),
      count: count is num ? count.toInt() : 0,
    );
  }
}

/// infobox 一行（Bangumi 条目页右侧资料表：`导演` / `话数` / `别名` …）。
///
/// 源里 `value` 可能是字符串，也可能是 `[{k,v},…]` 数组（如「别名」多条）；本类型
/// 只存**已摊平的展示字符串**，摊平规则见 `bangumi_client.dart`，展示层不再解析。
class ScrapeInfoboxEntry {
  const ScrapeInfoboxEntry({required this.key, required this.value});

  /// 原始字段名（Bangumi 的 key 本就是中文，不翻译不映射）。
  final String key;

  /// 摊平后的值（多值以 ` / ` 连接）。
  final String value;

  Map<String, Object?> toJson() =>
      <String, Object?>{'key': key, 'value': value};

  static ScrapeInfoboxEntry? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? key = json['key'];
    final Object? value = json['value'];
    if (key is! String || value is! String) return null;
    if (key.trim().isEmpty || value.trim().isEmpty) return null;
    return ScrapeInfoboxEntry(key: key.trim(), value: value.trim());
  }
}

/// 条目级刮削资料（落 `video_scrape_meta` 表的领域对象）。
///
/// 与 [ScrapeCandidate] 的分工：候选是**匹配阶段**的轻量条目（标题/年份/海报，够
/// 打分即可），本类型是**匹配定案后**再拉一次详情得到的完整资料。分开是因为搜索
/// 端点不返回简介/标签/infobox，硬塞进候选会让每条搜索结果都背一份用不上的重负载。
class ScrapeMetadata {
  const ScrapeMetadata({
    required this.source,
    required this.subjectId,
    required this.title,
    this.originalTitle,
    this.summary,
    this.airDate,
    this.rating,
    this.ratingCount,
    this.episodeCount,
    this.tags = const <ScrapeTag>[],
    this.infobox = const <ScrapeInfoboxEntry>[],
    this.detailUrl,
  });

  final ScrapeSource source;

  /// 源内条目 id（Bangumi subject id）。
  final String subjectId;

  /// 主标题（中文优先）。
  final String title;

  /// 原名（日文原题）；与 [title] 相同或缺失时为 null。
  final String? originalTitle;

  final String? summary;

  /// 放送开始日期 `YYYY-MM-DD`（源常见残缺，原样保留字符串，不补月/日）。
  final String? airDate;

  /// 评分 0~10 与评分人数。
  final double? rating;
  final int? ratingCount;

  final int? episodeCount;

  /// 标签（按热度降序）。
  final List<ScrapeTag> tags;

  /// 资料表（导演/制作/原作 …）。
  final List<ScrapeInfoboxEntry> infobox;

  /// 条目详情页 URL。
  final String? detailUrl;
}

/// 打分置信度分级。
enum MatchConfidence {
  /// 达自动应用线：批量匹配直接落封面。
  high,

  /// 中间带：进人工确认队列。
  medium,

  /// 低于取用线：宁可不配，保留抽帧。
  low,
}

/// 打分校验层输出：候选 + 置信度 + 明细分。
class MatchDecision {
  const MatchDecision({
    required this.candidate,
    required this.confidence,
    required this.titleScore,
    this.yearMatched,
    this.typeMatched,
    this.seasonMatched,
    this.episodeCountConsistent,
  });

  final ScrapeCandidate candidate;
  final MatchConfidence confidence;

  /// 归一化后标题相似度 [0,1]。
  final double titleScore;

  /// 三态：null = 无信息不参与打分。
  final bool? yearMatched;
  final bool? typeMatched;
  final bool? seasonMatched;
  final bool? episodeCountConsistent;
}

/// 封面来源标记（落 `video_covers/cover_meta.json`）。
///
/// 这个枚举回答的是**「这张封面是谁定的」**——批量刮削能不能覆盖它，完全由该问题
/// 决定（见 [CoverOriginBatchPolicy.batchOverwritePolicy]）。
///
/// 历史教训（BUG-1325）：用户在匹配弹窗里**亲手选定**的封面与后台**自动刮到**的
/// 封面曾经共用同一个 [scraped] 标记，系统事后分不出哪张是人选的，「全部刮削」开
/// 覆盖开关时就会把用户的纠正一并冲掉。所以在线刮削从此按决定者拆成
/// [autoScraped] / [userScraped] 两个值，[scraped] 只保留给读不出决定者的存量记录。
enum CoverOrigin {
  /// 导入时自动抽帧（默认占位图，批量匹配允许覆盖）。
  autoFrame,

  /// 用户手动设置（本地图片/粘贴/手动抽帧），批量匹配**永不覆盖**。
  manual,

  /// **存量记录专用**：旧版本写下的在线刮削标记，分不清是自动刮到的还是用户在
  /// 匹配弹窗里亲手选定的。新代码**不再写入**这个值（只在读旧 `cover_meta.json`
  /// 时出现），覆盖判据走保守口径 [CoverOverwritePolicy.legacyStrict]。
  scraped,

  /// 自动在线刮削所得（后台自动刮 / 整库刮削里无人值守应用），记录 entryId 以便
  /// 重刮/纠错。用户开「重刮已刮削的」时允许被覆盖。
  autoScraped,

  /// 用户在匹配弹窗里亲手点「使用」选定的条目，批量刮削**永不覆盖**（无论覆盖
  /// 开关是否打开）。
  userScraped,

  /// 目录 sidecar（poster.jpg 等）识别所得：用户自己放进目录的资产，**永不覆盖**。
  sidecar,
}

/// 批量刮削对一张**已有封面**的覆盖许可，由 [CoverOrigin] 唯一决定。
///
/// 把「能不能覆盖」收成一个枚举而不是散落的 `origin == X || origin == Y` 条件，
/// 是为了让新增来源时编译器逼着人做决定（switch 穷尽），不会有哪条来源默默落进
/// 「可覆盖」的默认分支。
enum CoverOverwritePolicy {
  /// 占位封面（导入抽帧）：批量随时可覆盖，不需要用户开开关。
  free,

  /// 自动刮削结果：只有用户显式要求「重刮已刮削的」时才覆盖。
  rescrapeOnly,

  /// 来源未知的**存量**刮削记录：即便用户要求重刮，也必须过「唯一归一化精确
  /// 标题」才允许覆盖——旧记录里混着用户亲手选定的封面，宁可少刮一本也不能改掉
  /// 人选的那张。
  legacyStrict,

  /// 用户亲自定的（手选本地图 / 弹窗选定 / 自己放的 sidecar）：**永不覆盖**。
  never,
}

/// [CoverOrigin] → 批量覆盖许可的唯一映射。
extension CoverOriginBatchPolicy on CoverOrigin {
  /// 批量刮削遇到这张封面时的覆盖许可。
  CoverOverwritePolicy get batchOverwritePolicy => switch (this) {
        CoverOrigin.autoFrame => CoverOverwritePolicy.free,
        CoverOrigin.autoScraped => CoverOverwritePolicy.rescrapeOnly,
        CoverOrigin.scraped => CoverOverwritePolicy.legacyStrict,
        CoverOrigin.manual ||
        CoverOrigin.userScraped ||
        CoverOrigin.sidecar =>
          CoverOverwritePolicy.never,
      };

  /// 这张封面是不是用户亲自定的（UI 判「要不要提示会被刮削改掉」用）。
  bool get isUserChosen => batchOverwritePolicy == CoverOverwritePolicy.never;
}

/// 单本封面的元数据（`cover_meta.json` 里按 bookUid 存）。
class CoverMeta {
  const CoverMeta({
    required this.origin,
    this.source,
    this.entryId,
  });

  final CoverOrigin origin;

  /// 在线刮削来源（[CoverOrigin.autoScraped] / [CoverOrigin.userScraped]，以及
  /// 存量 [CoverOrigin.scraped]）时的来源与条目 id，其余为 null。
  final ScrapeSource? source;
  final String? entryId;

  Map<String, Object?> toJson() => <String, Object?>{
        'origin': origin.name,
        if (source != null) 'source': source!.name,
        if (entryId != null) 'entryId': entryId,
      };

  static CoverMeta fromJson(Map<String, Object?> json) => CoverMeta(
        origin: CoverOrigin.values.asNameMap()[json['origin']] ??
            CoverOrigin.autoFrame,
        source: json['source'] is String
            ? ScrapeSource.values.asNameMap()[json['source']]
            : null,
        entryId: json['entryId'] as String?,
      );
}
