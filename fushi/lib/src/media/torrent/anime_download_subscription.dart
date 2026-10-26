/// 旧版（schema v78 之前）番剧订阅的 JSON 形状，**只为一次性迁移保留**。
///
/// 旧订阅服务按订阅里的查询词定时搜索种子站并自动推送；BT 内置搜索站已全部移除
/// （BT 搜索一律走用户添加的 RSS 搜索站 + Torznab，经 `VideoResourceRegistry`），
/// 这个服务随之删除。启动时 `VideoDownloadLegacyImporter` 把残留的
/// `anime_downloads/subscriptions/*.json` 迁成 `video_download_subscriptions` 行
/// （`resourceProvider` 冻结为旧 wire 值，引擎判成「来源已失效」）并归档原文件，
/// 本文件只剩那一步需要的模型与编解码。
library;

/// A durable "series + video release + optional Jimaku subtitle" subscription.
///
/// [startAfterEpisode] is the episode the user selected when subscribing.
/// Existing releases are deliberately not backfilled. [processedEpisodes]
/// records successfully queued later episodes, allowing an older missing
/// episode to arrive after a newer one without being skipped.
class AnimeDownloadSubscription {
  const AnimeDownloadSubscription({
    required this.id,
    required this.createdAtMs,
    required this.anilistId,
    required this.seriesTitle,
    required this.nyaaQuery,
    required this.category,
    required this.releaseGroup,
    required this.startAfterEpisode,
    this.coverUrl,
    this.resolution,
    this.jimakuEntryId,
    this.jimakuEntryName,
    this.jimakuLanguage,
    this.trustedOnly = false,
    this.enabled = true,
    this.processedEpisodes = const <int>{},
    this.lastCheckedAtMs,
    this.lastMatchedAtMs,
    this.lastError,
  });

  final String id;
  final int createdAtMs;
  final int anilistId;
  final String seriesTitle;
  final String? coverUrl;
  final String nyaaQuery;
  final String category;
  final bool trustedOnly;
  final String releaseGroup;
  final String? resolution;

  /// null = video-only subscription. A non-null id pins one explicit Jimaku
  /// entry; season packs are resolved inside that entry by episode number.
  final int? jimakuEntryId;
  final String? jimakuEntryName;
  final String? jimakuLanguage;

  final int startAfterEpisode;
  final Set<int> processedEpisodes;
  final bool enabled;
  final int? lastCheckedAtMs;
  final int? lastMatchedAtMs;
  final String? lastError;
}

Map<String, dynamic> encodeAnimeDownloadSubscription(
  AnimeDownloadSubscription subscription,
) {
  final List<int> processed = subscription.processedEpisodes.toList()..sort();
  return <String, dynamic>{
    'id': subscription.id,
    'createdAtMs': subscription.createdAtMs,
    'anilistId': subscription.anilistId,
    'seriesTitle': subscription.seriesTitle,
    'coverUrl': subscription.coverUrl,
    'nyaaQuery': subscription.nyaaQuery,
    'category': subscription.category,
    'trustedOnly': subscription.trustedOnly,
    'releaseGroup': subscription.releaseGroup,
    'resolution': subscription.resolution,
    'jimakuEntryId': subscription.jimakuEntryId,
    'jimakuEntryName': subscription.jimakuEntryName,
    'jimakuLanguage': subscription.jimakuLanguage,
    'startAfterEpisode': subscription.startAfterEpisode,
    'processedEpisodes': processed,
    'enabled': subscription.enabled,
    'lastCheckedAtMs': subscription.lastCheckedAtMs,
    'lastMatchedAtMs': subscription.lastMatchedAtMs,
    'lastError': subscription.lastError,
  };
}

AnimeDownloadSubscription? decodeAnimeDownloadSubscription(
  Map<dynamic, dynamic> raw,
) {
  try {
    final Object? id = raw['id'];
    final Object? anilistId = raw['anilistId'];
    final Object? title = raw['seriesTitle'];
    final Object? query = raw['nyaaQuery'];
    final Object? group = raw['releaseGroup'];
    final Object? anchor = raw['startAfterEpisode'];
    if (id is! String ||
        id.isEmpty ||
        anilistId is! int ||
        title is! String ||
        query is! String ||
        group is! String ||
        group.trim().isEmpty ||
        anchor is! int) {
      return null;
    }
    final Set<int> processed = <int>{};
    final Object? rawProcessed = raw['processedEpisodes'];
    if (rawProcessed is List) {
      processed.addAll(rawProcessed.whereType<int>().where((int e) => e > 0));
    }
    return AnimeDownloadSubscription(
      id: id,
      createdAtMs: raw['createdAtMs'] is int ? raw['createdAtMs'] as int : 0,
      anilistId: anilistId,
      seriesTitle: title,
      coverUrl: raw['coverUrl'] is String ? raw['coverUrl'] as String : null,
      nyaaQuery: query,
      category:
          raw['category'] is String &&
              (raw['category'] as String).trim().isNotEmpty
          ? raw['category'] as String
          : '1_0',
      trustedOnly: raw['trustedOnly'] == true,
      releaseGroup: group.trim(),
      resolution: raw['resolution'] is String
          ? raw['resolution'] as String
          : null,
      jimakuEntryId: raw['jimakuEntryId'] is int
          ? raw['jimakuEntryId'] as int
          : null,
      jimakuEntryName: raw['jimakuEntryName'] is String
          ? raw['jimakuEntryName'] as String
          : null,
      jimakuLanguage: raw['jimakuLanguage'] is String
          ? raw['jimakuLanguage'] as String
          : null,
      startAfterEpisode: anchor,
      processedEpisodes: processed,
      enabled: raw['enabled'] != false,
      lastCheckedAtMs: raw['lastCheckedAtMs'] is int
          ? raw['lastCheckedAtMs'] as int
          : null,
      lastMatchedAtMs: raw['lastMatchedAtMs'] is int
          ? raw['lastMatchedAtMs'] as int
          : null,
      lastError: raw['lastError'] is String ? raw['lastError'] as String : null,
    );
  } catch (_) {
    return null;
  }
}
