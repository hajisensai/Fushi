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
/// `tmdb_client.dart` / `sidecar_scanner.dart` / `poster_scraper_service.dart`。
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

/// 封面来源标记（落 `video_covers/cover_meta.json`，批量匹配只碰 autoFrame）。
enum CoverOrigin {
  /// 导入时自动抽帧（默认，批量匹配允许覆盖）。
  autoFrame,

  /// 用户手动设置（本地图片/粘贴/手动抽帧），批量匹配**永不覆盖**。
  manual,

  /// 在线刮削所得（记录 entryId 以便重刮/纠错）。
  scraped,

  /// 目录 sidecar（poster.jpg 等）识别所得。
  sidecar,
}

/// 单本封面的元数据（`cover_meta.json` 里按 bookUid 存）。
class CoverMeta {
  const CoverMeta({
    required this.origin,
    this.source,
    this.entryId,
  });

  final CoverOrigin origin;

  /// [CoverOrigin.scraped] 时的来源与条目 id，其余为 null。
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
