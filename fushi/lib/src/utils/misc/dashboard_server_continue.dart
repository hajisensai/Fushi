import 'package:flutter/widgets.dart' show BuildContext;
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart'
    show audiobookshelfProgressKey;
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

/// 首页「继续」行里「用户自配服务器」条目的来源。
enum ServerContinueSource {
  /// Jellyfin / Emby / Plex（视频模块）。
  mediaServer,

  /// Audiobookshelf（有声书，住在书模块的 ABS 标签页）。
  audiobookshelf,
}

/// 服务器上一条「在进行中」的条目，已归一成首页「继续」行能直接混排的形状。
///
/// 纯数据 + 一个打开闭包（由取数侧按条目类型接线），所以合并 / 映射逻辑可以脱离
/// 网络与页面单测（对照 `dashboard_remote_merge.dart` 的互联补位）。
class ServerContinueCandidate {
  const ServerContinueCandidate({
    required this.source,
    required this.serverId,
    required this.serverName,
    required this.itemId,
    required this.title,
    required this.recentMs,
    required this.open,
    this.collectionName,
    this.progress,
    this.badgeLabel,
    this.coverUrl,
    this.coverCacheKey,
    this.coverFetcher,
  });

  final ServerContinueSource source;

  /// 服务器身份（媒体服务器 = [MediaServerBrowser.serverId]，ABS = 配置 id）。
  final String serverId;
  final String serverName;
  final String itemId;
  final String title;

  /// 剧名 / 播客名；非 null 时卡片显示它，[title] 退为副标题（与本地合集同规则）。
  final String? collectionName;

  /// 最近播放时刻（epoch 毫秒）；NextUp 取所属剧的最近播放时刻；都不知道为 0
  /// （排在已知时刻之后）。
  final int recentMs;

  /// 0..1；未知为 null（不画进度条）。
  final double? progress;
  final String? badgeLabel;
  final String? coverUrl;
  final String? coverCacheKey;

  /// 封面取图器（媒体服务器的封面要走它带鉴权；null = 直接 HTTP 取图）。
  final RemoteCoverFetcher? coverFetcher;

  /// 点卡的落地：媒体服务器 = 起播，ABS = 条目详情页。
  final Future<void> Function(BuildContext context) open;

  bool get isVideo => source == ServerContinueSource.mediaServer;

  /// 跨来源唯一键（去重 / 与本地条目比对）。
  String get key => '${source.name}|$serverId|$itemId';
}

/// 媒体服务器条目在「已入库的本地视频」里的比对键（见 [mergeServerContinue]）。
String mediaServerItemKey(String serverId, String itemId) =>
    '$serverId|$itemId';

/// 一台媒体服务器的 Resume ∪ NextUp → 候选。
///
/// 口径与服务器首页「继续观看」行一致（`media_server_home_view`）：Resume 在前
/// （有断点的优先），NextUp 补没断点的下一集；只收可播叶子，同 id 去重，已看完
/// 的不收。排序时刻取服务器记的最近播放时刻；NextUp 的集本身没播过、服务器不报
/// 时刻，取所属剧的最近播放时刻 [seriesRecentMs]（见 [nextUpSeriesRecency]），
/// 否则「接下来看」永远沉到所有本地条目之后。仍不知道的落 0。
List<ServerContinueCandidate> mediaServerContinueCandidates({
  required String serverId,
  required String serverName,
  required Iterable<MediaServerItem> resume,
  required Iterable<MediaServerItem> nextUp,
  Map<String, int> seriesRecentMs = const <String, int>{},
  required String? Function(MediaServerItem item) coverUrlOf,
  required Future<void> Function(BuildContext context, MediaServerItem item)
  open,
  RemoteCoverFetcher? coverFetcher,
}) {
  final Set<String> seen = <String>{};
  final List<ServerContinueCandidate> out = <ServerContinueCandidate>[];
  for (final MediaServerItem item in resume.followedBy(nextUp)) {
    if (!item.isPlayable || item.played || !seen.add(item.id)) continue;
    final bool episode = item.type == MediaServerItemType.episode;
    final String? series = item.seriesName;
    final bool grouped = episode && series != null && series.isNotEmpty;
    final int? duration = item.durationMs;
    final double? fraction =
        item.positionMs > 0 && duration != null && duration > 0
        ? (item.positionMs / duration).clamp(0.0, 1.0)
        : null;
    final String code = item.episodeCode;
    out.add(
      ServerContinueCandidate(
        source: ServerContinueSource.mediaServer,
        serverId: serverId,
        serverName: serverName,
        itemId: item.id,
        title: grouped && code.isNotEmpty ? '$code ${item.name}' : item.name,
        collectionName: grouped ? series : null,
        recentMs: item.lastPlayedAtMs > 0
            ? item.lastPlayedAtMs
            : (seriesRecentMs[item.seriesId] ?? 0),
        progress: fraction,
        badgeLabel: code.isNotEmpty
            ? code
            : (fraction == null ? null : '${(fraction * 100).round()}%'),
        coverUrl: coverUrlOf(item),
        coverCacheKey: 'media-server:$serverId:${item.coverItem.id}',
        coverFetcher: coverFetcher,
        open: (BuildContext context) => open(context, item),
      ),
    );
  }
  return out;
}

/// NextUp 里没有自身播放时刻的集 → 所属剧的最近播放时刻（seriesId → epoch 毫秒）。
///
/// 先看同一台服务器 Resume ∪ NextUp 里同剧条目报的时刻（不发请求）；还不知道的剧，
/// 问这一集所在季的集清单（[MediaServerBrowser.listEpisodes]，一季一发），取其中
/// 最近一次播放——「接下来看」的上一集就在里面。季首集的上一集在上一季时这一季
/// 没有播放记录，落空（0）。单剧失败只丢这一剧，不影响其它。
Future<Map<String, int>> nextUpSeriesRecency({
  required MediaServerBrowser browser,
  required Iterable<MediaServerItem> resume,
  required Iterable<MediaServerItem> nextUp,
}) async {
  final Map<String, int> out = <String, int>{};
  for (final MediaServerItem item in resume.followedBy(nextUp)) {
    final String? series = item.seriesId;
    if (series == null || item.lastPlayedAtMs <= 0) continue;
    if (item.lastPlayedAtMs > (out[series] ?? 0)) {
      out[series] = item.lastPlayedAtMs;
    }
  }
  final Map<String, MediaServerItem> unknown = <String, MediaServerItem>{};
  for (final MediaServerItem item in nextUp) {
    final String? series = item.seriesId;
    if (series == null || item.lastPlayedAtMs > 0) continue;
    if (out.containsKey(series)) continue;
    unknown.putIfAbsent(series, () => item);
  }
  await Future.wait<void>(<Future<void>>[
    for (final MapEntry<String, MediaServerItem> e in unknown.entries)
      () async {
        try {
          final MediaServerPage page = await browser.listEpisodes(
            seriesId: e.key,
            seasonId: e.value.seasonId,
          );
          int latest = 0;
          for (final MediaServerItem ep in page.items) {
            if (ep.lastPlayedAtMs > latest) latest = ep.lastPlayedAtMs;
          }
          if (latest > 0) out[e.key] = latest;
        } on Object {
          // 这一剧问不到：留 0，排在已知时刻之后。
        }
      }(),
  ]);
  return out;
}

/// 一台 Audiobookshelf 服务器的「继续收听」→ 候选。
///
/// [progressByKey] 是 `allMediaProgress()` 的结果（取不到传空表即可：条目照出，
/// 只是没有进度条与排序时刻）。服务器标成已听完的不收。
List<ServerContinueCandidate> audiobookshelfContinueCandidates({
  required String serverId,
  required String serverName,
  required Iterable<AudiobookshelfInProgressEntry> entries,
  required Map<String, AudiobookshelfMediaProgress> progressByKey,
  required String? Function(AudiobookshelfItem item) coverUrlOf,
  required Future<void> Function(BuildContext context, AudiobookshelfItem item)
  open,
}) {
  final Set<String> seen = <String>{};
  final List<ServerContinueCandidate> out = <ServerContinueCandidate>[];
  for (final AudiobookshelfInProgressEntry entry in entries) {
    final AudiobookshelfItem item = entry.item;
    final String id = entry.episodeId == null
        ? item.id
        : '${item.id}/${entry.episodeId}';
    if (!seen.add(id)) continue;
    final AudiobookshelfMediaProgress? progress =
        progressByKey[audiobookshelfProgressKey(item.id, entry.episodeId)];
    if (progress?.isFinished ?? false) continue;
    final double? fraction = progress == null
        ? null
        : (progress.progress ??
                  (progress.durationSeconds > 0
                      ? progress.currentTimeSeconds / progress.durationSeconds
                      : 0))
              .clamp(0.0, 1.0);
    final bool podcastEpisode =
        entry.episodeTitle != null && entry.episodeTitle!.isNotEmpty;
    out.add(
      ServerContinueCandidate(
        source: ServerContinueSource.audiobookshelf,
        serverId: serverId,
        serverName: serverName,
        itemId: id,
        title: podcastEpisode ? entry.episodeTitle! : item.title,
        collectionName: podcastEpisode ? item.title : null,
        recentMs: progress?.lastUpdateMs ?? 0,
        progress: fraction != null && fraction > 0 ? fraction : null,
        badgeLabel: fraction != null && fraction > 0
            ? '${(fraction * 100).round()}%'
            : null,
        coverUrl: coverUrlOf(item),
        coverCacheKey: 'abs:$serverId:${item.id}',
        open: (BuildContext context) => open(context, item),
      ),
    );
  }
  return out;
}

/// 多台服务器的候选混成一份：跨来源 [ServerContinueCandidate.key] 去重（先到先
/// 得）、丢掉本机已入库的媒体服务器条目（[localMediaServerItemKeys]，键见
/// [mediaServerItemKey]——本地那张卡才是用户的真入口），再按最近播放时刻倒序。
/// 同时刻保持输入顺序（稳定排序）。
List<ServerContinueCandidate> mergeServerContinue(
  Iterable<Iterable<ServerContinueCandidate>> groups, {
  Set<String> localMediaServerItemKeys = const <String>{},
}) {
  final Set<String> seen = <String>{};
  final List<ServerContinueCandidate> merged = <ServerContinueCandidate>[];
  for (final Iterable<ServerContinueCandidate> group in groups) {
    for (final ServerContinueCandidate c in group) {
      if (c.isVideo &&
          localMediaServerItemKeys.contains(
            mediaServerItemKey(c.serverId, c.itemId),
          )) {
        continue;
      }
      if (seen.add(c.key)) merged.add(c);
    }
  }
  final Map<ServerContinueCandidate, int> order =
      <ServerContinueCandidate, int>{
        for (int i = 0; i < merged.length; i++) merged[i]: i,
      };
  merged.sort((ServerContinueCandidate a, ServerContinueCandidate b) {
    final int byTime = b.recentMs.compareTo(a.recentMs);
    return byTime != 0 ? byTime : order[a]!.compareTo(order[b]!);
  });
  return merged;
}
