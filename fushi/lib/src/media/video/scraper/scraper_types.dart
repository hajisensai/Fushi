/// 视频本地解析与历史刮削投影的共享数据契约。
///
/// 新的动画元数据网络链由 metadata 域的 AniDB 主源与 TMDB 补源负责。本文件只
/// 保留文件名解析、旧数据库读取和 sidecar 封面兼容所需的纯数据类型。
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
///
/// 历史持久化都按 **name** 走（`ScrapeSource.values.asNameMap()`，见 [CoverMeta]），
/// 不按 index。退休来源只作为兼容输入保留，不能据此重新装配网络 client。
enum ScrapeSource {
  local,
  anidb,
  offlineDb,
  bangumi,
  tmdb,
  anilist,
  jikan,
  manualUrl
}

// ─────────────────────────── 条目级元数据 ───────────────────────────

/// 条目标签（名字 + 打标人数，按热度降序）。
class ScrapeTag {
  const ScrapeTag({required this.name, this.count = 0});

  final String name;

  /// 打该标签的人数（来源不提供时为 0）。
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

/// infobox 一行（如 `导演` / `话数` / `别名`）。
///
/// 源里 `value` 可能是字符串，也可能是 `[{k,v},…]` 数组（如「别名」多条）；本类型
/// 只存**已摊平的展示字符串**；历史数据继续按该形态读取，展示层不再解析。
class ScrapeInfoboxEntry {
  const ScrapeInfoboxEntry({required this.key, required this.value});

  /// 原始字段名，不翻译、不映射。
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

/// 旧 `video_scrape_meta` 行的只读领域投影。
///
/// 退休 provider 写下的记录仍可展示或迁移，但此类型不再承担网络搜索或详情抓取。
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

  /// 源内条目 id。
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

/// 封面来源标记（落 `video_covers/cover_meta.json`）。
///
/// [scraped] / [autoScraped] / [userScraped] 是旧在线封面链写下的兼容值。当前本地
/// 服务只新增 [sidecar]；保留旧值是为了让历史覆盖策略仍能安全判定。
enum CoverOrigin {
  /// 导入时自动抽帧（默认占位图，批量匹配允许覆盖）。
  autoFrame,

  /// 用户手动设置（本地图片/粘贴/手动抽帧），批量匹配**永不覆盖**。
  manual,

  /// **存量记录专用**：旧版本写下的在线刮削标记，分不清是自动刮到的还是用户在
  /// 匹配弹窗里亲手选定的。新代码**不再写入**这个值（只在读旧 `cover_meta.json`
  /// 时出现）。
  scraped,

  /// 历史自动在线刮削所得。当前代码不再写入。
  autoScraped,

  /// 全量清理已为历史自动封面持久化内容摘要，但尚未完成文件与 DB 指针提交。
  /// 仅供崩溃恢复；正常完成后删除，发现同路径替换物时转成
  /// [cleanupReplacement]。
  cleanupPending,

  /// 清理隔离窗口内出现的同路径替换物。该来源永久按用户资产保护；单独枚举值也
  /// 让下一轮能安全识别并收走崩溃遗留的旧 quarantine，而不猜测普通 manual 文件。
  cleanupReplacement,

  /// 历史手动在线匹配所得，批量任务永不覆盖。当前代码不再写入。
  userScraped,

  /// 目录 sidecar（poster.jpg 等）识别所得：用户自己放进目录的资产，**永不覆盖**。
  sidecar,
}

/// 单本封面的元数据（`cover_meta.json` 里按 bookUid 存）。
class CoverMeta {
  const CoverMeta({
    required this.origin,
    this.source,
    this.entryId,
    this.contentSha256,
  });

  final CoverOrigin origin;

  /// 在线刮削来源（[CoverOrigin.autoScraped] / [CoverOrigin.userScraped]，以及
  /// 存量 [CoverOrigin.scraped]）时的来源与条目 id，其余为 null。
  final ScrapeSource? source;
  final String? entryId;

  /// 历史自动刮削封面的所有权摘要；进入 [CoverOrigin.cleanupPending] 后继续作为
  /// 崩溃恢复 CAS。旧 autoScraped 记录通常没有它，因此清理必须 fail closed。
  final String? contentSha256;

  Map<String, Object?> toJson() => <String, Object?>{
        // 新清理状态对旧版本降级成既有保护来源，避免旧客户端把未知枚举回退为
        // autoFrame 后覆盖替换物；新版本通过 cleanupState 无损恢复真实状态。
        'origin': switch (origin) {
          CoverOrigin.cleanupPending => CoverOrigin.scraped.name,
          CoverOrigin.cleanupReplacement => CoverOrigin.manual.name,
          _ => origin.name,
        },
        if (origin == CoverOrigin.cleanupPending)
          'cleanupState': 'pending',
        if (origin == CoverOrigin.cleanupReplacement)
          'cleanupState': 'replacement',
        if (source != null) 'source': source!.name,
        if (entryId != null) 'entryId': entryId,
        if (contentSha256 != null) 'contentSha256': contentSha256,
      };

  static CoverMeta fromJson(Map<String, Object?> json) {
    final CoverOrigin origin = switch (json['cleanupState']) {
      'pending' => CoverOrigin.cleanupPending,
      'replacement' => CoverOrigin.cleanupReplacement,
      _ => CoverOrigin.values.asNameMap()[json['origin']] ??
          CoverOrigin.autoFrame,
    };
    return CoverMeta(
      origin: origin,
      source: json['source'] is String
          ? ScrapeSource.values.asNameMap()[json['source']]
          : null,
      entryId: json['entryId'] as String?,
      contentSha256: json['contentSha256'] as String?,
    );
  }
}
