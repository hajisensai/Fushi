import 'dart:convert';

import 'package:fushi/src/media/video/anilist_client.dart';

/// 放送日历缓存（TODO-2487）：内存 + 偏好 JSON 两层，TTL 数小时。**不建
/// Drift 表**（v65 被并行线程占用），偏好键 `airing_calendar_cache` 已在
/// profile_keys.dart 按前缀排除出 Profile 快照（设备缓存，不随 Profile 走）。

/// 偏好键（单键存最近一次成功拉取；签名不匹配视为未命中）。
const String kAiringCalendarCachePrefKey = 'airing_calendar_cache';

/// 缓存有效期。放送表一天内基本不变，几小时足够新鲜且远离 AniList rate limit。
const Duration kAiringCalendarCacheTtl = Duration(hours: 3);

/// 一次成功拉取的完整周窗口结果。
class AiringScheduleCache {
  const AiringScheduleCache({
    required this.fetchedAtMs,
    required this.signature,
    required this.episodes,
  });

  /// 拉取完成时刻（epoch 毫秒），TTL 判定用。
  final int fetchedAtMs;

  /// 缓存身份，见 [airingCacheSignature]。
  final String signature;

  final List<AniListAiringEpisode> episodes;
}

/// 组缓存签名（纯函数）：`<weekStart epoch 秒>|all` 或
/// `<weekStart>|ids:<升序逗号 id>`。绑定集/订阅集变化 → 签名变化 → 未命中。
String airingCacheSignature({
  required int weekStartEpochSeconds,
  required List<int>? mediaIds,
}) {
  if (mediaIds == null) return '$weekStartEpochSeconds|all';
  final List<int> sorted = List<int>.of(mediaIds)..sort();
  return '$weekStartEpochSeconds|ids:${sorted.join(',')}';
}

/// 编码成偏好 JSON 字符串（与 [decodeAiringScheduleCache] 往返，纯函数）。
String encodeAiringScheduleCache(AiringScheduleCache cache) {
  return jsonEncode(<String, dynamic>{
    'fetchedAtMs': cache.fetchedAtMs,
    'signature': cache.signature,
    'episodes': <Map<String, dynamic>>[
      for (final AniListAiringEpisode e in cache.episodes)
        <String, dynamic>{
          'mediaId': e.mediaId,
          'episode': e.episode,
          'airingAt': e.airingAtSeconds,
          if (e.media.romaji != null) 'romaji': e.media.romaji,
          if (e.media.english != null) 'english': e.media.english,
          if (e.media.native != null) 'native': e.media.native,
          if (e.media.coverUrl != null) 'cover': e.media.coverUrl,
        },
    ],
  });
}

/// 解码偏好 JSON。结构不符 / 签名不匹配 / 超 TTL → null（当无缓存）。纯函数，
/// [nowMs] 由调用方注入便于单测。
AiringScheduleCache? decodeAiringScheduleCache(
  String raw, {
  required String signature,
  required int nowMs,
  Duration ttl = kAiringCalendarCacheTtl,
}) {
  if (raw.isEmpty) return null;
  try {
    final dynamic json = jsonDecode(raw);
    if (json is! Map) return null;
    final dynamic fetchedAtMs = json['fetchedAtMs'];
    if (fetchedAtMs is! int) return null;
    if (json['signature'] != signature) return null;
    if (nowMs - fetchedAtMs > ttl.inMilliseconds) return null;
    final dynamic episodes = json['episodes'];
    if (episodes is! List) return null;
    final List<AniListAiringEpisode> out = <AniListAiringEpisode>[];
    for (final dynamic e in episodes) {
      if (e is! Map) continue;
      final dynamic mediaId = e['mediaId'];
      final dynamic episode = e['episode'];
      final dynamic airingAt = e['airingAt'];
      if (mediaId is! int || episode is! int || airingAt is! int) continue;
      out.add(AniListAiringEpisode(
        mediaId: mediaId,
        episode: episode,
        airingAtSeconds: airingAt,
        media: AniListMedia(
          id: mediaId,
          romaji: e['romaji'] as String?,
          english: e['english'] as String?,
          native: e['native'] as String?,
          coverUrl: e['cover'] as String?,
        ),
      ));
    }
    return AiringScheduleCache(
      fetchedAtMs: fetchedAtMs,
      signature: signature,
      episodes: out,
    );
  } catch (_) {
    return null;
  }
}

/// 进程内内存缓存（跨页面开关存活；app 重启后由偏好层兜底）。
class AiringMemoryCache {
  AiringMemoryCache._();

  static AiringScheduleCache? _latest;

  /// 命中条件与偏好层同口径：签名一致且未过 TTL。
  static AiringScheduleCache? get(
    String signature, {
    required int nowMs,
    Duration ttl = kAiringCalendarCacheTtl,
  }) {
    final AiringScheduleCache? cache = _latest;
    if (cache == null) return null;
    if (cache.signature != signature) return null;
    if (nowMs - cache.fetchedAtMs > ttl.inMilliseconds) return null;
    return cache;
  }

  static void put(AiringScheduleCache cache) => _latest = cache;

  /// 测试隔离用。
  static void reset() => _latest = null;
}
