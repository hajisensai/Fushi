// 「有列表上下文的在线 / 网页来源」接进播放器选集面板（拍板台 zGXhhMAglH）。
//
// 这里的每一集都是**一本独立的流媒体书**（`video/stream/…`，与「粘贴 URL 导入」同一身份）：
// 换集 = 换到那一本书的播放页，断点 / 观看统计 / 收藏 / 制卡身份天然跟着集走，与本地合集
// 「每集一行、换集换页」同一模型。列表来源两种：
//   * YouTube 播放列表（浏览器里从 `watch?v=…&list=…` 交给播放器、网页档里站内点进播放列表）：
//     条目在线拉取、按页增量到达（[YoutubePlaylistEpisodes]），书在用户真的换到那一集时才落；
//   * 库里的合集（成员是流媒体书：粘贴 URL / IPTV 频道 / 来源库网络视频 / 网页视频站）：
//     [loadCollectionStreamBookEpisodes]，与本地合集选集同一份合集快照。
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/media_cover_standalone_source.dart';
import 'package:fushi/src/media/video/url_stream_video.dart'
    show streamVideoBookUid;
import 'package:fushi/src/media/video/video_episode_rail.dart'
    show VideoEpisodeEntry;
import 'package:fushi/src/media/video/web_video_sites.dart'
    show ensureWebVideoEpisodeBook, refreshWebVideoEpisodeBook;
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/youtube_watch_page.dart'
    show youtubeCanonicalWatchUrl;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart'
    show parsedEpisodeNumbersOf;
import 'package:fushi_engine/media/video/youtube_playlist.dart';

/// 选集面板里的一集：一本（可能还没落库的）流媒体书。
@immutable
class StreamBookEpisode {
  const StreamBookEpisode({
    required this.bookUid,
    required this.url,
    required this.title,
    this.displayTitle,
    this.coverPath,
    this.coverUrl,
    this.coverCacheKey,
    this.episodeNumber,
    this.sectionKey,
    this.completed = false,
    this.started = false,
    this.positionMs = 0,
    this.progress,
  });

  /// 这一集的书身份（[streamVideoBookUid]；YouTube 条目在落书之前就确定）。
  final String bookUid;

  /// 这一集的播放地址（落书时就是 `video_books.videoPath`；合集成员是它的 videoPath，
  /// 可能是本机路径——混着本地文件的合集）。
  final String url;

  final String title;

  /// 面板展示名（合集成员的集级刮削集名）；null = 用 [title]。
  final String? displayTitle;

  /// 已落书且有封面时的本机封面。
  final String? coverPath;

  /// 没有本机封面时的远端封面（YouTube 缩略图）。
  final String? coverUrl;
  final String? coverCacheKey;

  /// 卡片角标集号：播放列表是列表顺位（标题里的数字不是集号）；null = 按路径 / 标题解析。
  final int? episodeNumber;

  /// 生效分栏键；null = 按路径 / 标题派生。
  final String? sectionKey;

  final bool completed;
  final bool started;
  final int positionMs;

  /// 观看进度 0..1（断点与时长都已知时）。
  final double? progress;
}

/// YouTube 缩略图（16:9，320×180）：按视频 id 直接拼，公开 CDN，不经 API。
String youtubeEpisodeThumbnailUrl(String videoId) =>
    'https://i.ytimg.com/vi/$videoId/mqdefault.jpg';

/// 播放列表条目 → 选集。[rows] 是已落书的那几集（按 bookUid），带进度角标与本机封面。
///
/// 分栏恒为同一栏：播放列表不是分季的剧，标题里的「第 2 季」「#2」按文件名规则派生会把
/// 一份列表拆成几条季 chip；集号同理取列表顺位。
List<StreamBookEpisode> youtubePlaylistBookEpisodes(
  List<YoutubePlaylistEntry> entries, {
  Map<String, VideoBookRow> rows = const <String, VideoBookRow>{},
}) {
  final String section = collectionSeasonGroupKey(season: 1, episode: 1);
  return <StreamBookEpisode>[
    for (int i = 0; i < entries.length; i++)
      _youtubeEpisode(entries[i], i + 1, section, rows),
  ];
}

StreamBookEpisode _youtubeEpisode(
  YoutubePlaylistEntry entry,
  int number,
  String section,
  Map<String, VideoBookRow> rows,
) {
  final String url = youtubeCanonicalWatchUrl(entry.videoId);
  final String uid = streamVideoBookUid(url);
  final VideoBookRow? row = rows[uid];
  final String? coverPath = row?.coverPath;
  final bool hasLocalCover = coverPath != null && coverPath.isNotEmpty;
  final int? durationMs = entry.durationMs;
  final int position = row?.lastPositionMs ?? 0;
  return StreamBookEpisode(
    bookUid: uid,
    url: url,
    title: entry.title,
    coverPath: hasLocalCover ? coverPath : null,
    coverUrl: hasLocalCover ? null : youtubeEpisodeThumbnailUrl(entry.videoId),
    coverCacheKey: 'youtube:${entry.videoId}',
    episodeNumber: number,
    sectionKey: section,
    completed: row?.completedAt != null,
    started: position > 0,
    positionMs: position,
    progress: durationMs != null && durationMs > 0 && position > 0
        ? (position / durationMs).clamp(0.0, 1.0)
        : null,
  );
}

/// 合集成员 → 选集（与本地合集选集面板同一份合集快照：集级刮削集名、生效分栏、进度）。
Future<List<StreamBookEpisode>> loadCollectionStreamBookEpisodes(
  VideoBookRepository repo,
  int collectionId,
) async {
  final CollectionPlaybackSnapshot snapshot = await repo
      .collectionPlaybackSnapshot(collectionId);
  final String? workTitle = snapshot.collectionMeta?.title.trim();
  return <StreamBookEpisode>[
    for (final VideoBookRow row in snapshot.episodes)
      StreamBookEpisode(
        bookUid: row.bookUid,
        url: row.videoPath,
        title: row.title,
        displayTitle: _scrapedEpisodeName(
          snapshot.episodeMeta[row.bookUid],
          workTitle,
        ),
        coverPath: row.coverPath,
        sectionKey: snapshot.sectionKeys[row.bookUid],
        completed: row.completedAt != null,
        started: row.lastPositionMs > 0,
        positionMs: row.lastPositionMs,
      ),
  ];
}

/// 集级刮削集名（集名缺失时刮削会把作品名回填进 title，那不是集名——与合集详情页
/// `_scrapedEpisodeTitle` 同判据）。
String? _scrapedEpisodeName(VideoScrapeMetaRow? meta, String? workTitle) {
  if (meta == null || meta.episodeNumber == null) return null;
  final String name = meta.title.trim();
  return name.isNotEmpty && name != workTitle ? name : null;
}

/// 把 [episode] 落成书（已有就原样用）并返回它的 bookUid；落不了（不是可落书的网页地址、
/// 写库失败）返回 null。YouTube 新落的书顺带补真名 / 封面（尽力而为，不挡换集）。
Future<String?> ensureStreamBookEpisode(
  VideoBookRepository repo,
  StreamBookEpisode episode,
) async {
  final VideoBookRow? existing = await repo.getByBookUid(episode.bookUid);
  if (existing != null) return existing.bookUid;
  final VideoBookRow? row = await ensureWebVideoEpisodeBook(
    repo,
    episodeUrl: episode.url,
    title: episode.title,
  );
  if (row == null) return null;
  unawaited(
    refreshWebVideoEpisodeBook(
      repo,
      row,
      videoTitle: episode.title,
      pageImage: episode.coverUrl ?? '',
    ).then<void>(
      (_) {},
      onError: (Object e, StackTrace st) =>
          ErrorLogService.instance.log('StreamBookEpisode.refresh', e, st),
    ),
  );
  return row.bookUid;
}

/// 选集 → 面板卡片（网页播放器页用；原生播放器页经自己的取图链）。集号缺省时整批按
/// 路径 / 标题解析（与本地合集同一解析器，BUG-2369）。
List<VideoEpisodeEntry> streamBookEpisodePanelEntries(
  List<StreamBookEpisode> episodes, {
  required RemoteCoverFetcher coverFetcher,
}) {
  final List<int?> parsed = parsedEpisodeNumbersOf(<String>[
    for (final StreamBookEpisode e in episodes) _numberKey(e),
  ]);
  return <VideoEpisodeEntry>[
    for (int i = 0; i < episodes.length; i++)
      VideoEpisodeEntry(
        title: episodes[i].displayTitle ?? episodes[i].title,
        // 单集没有书目（不走书的 override 缩略图链），直接用独立封面解析：
        // media_cover_source 为书目分支读 AppModel，接它会把本文件拖进 import 大环。
        cover: resolveStandaloneCoverImage(
          localPath: episodes[i].coverPath,
          remoteUrl: episodes[i].coverUrl,
          remoteFetcher: coverFetcher,
          remoteCacheKey: episodes[i].coverCacheKey,
        ),
        episodeNumber: episodes[i].episodeNumber ?? parsed[i],
        groupKey:
            episodes[i].sectionKey ??
            collectionGroupKeyForFilename(_numberKey(episodes[i])),
        completed: episodes[i].completed,
        started: episodes[i].started,
        progress: episodes[i].progress,
      ),
  ];
}

String _numberKey(StreamBookEpisode e) =>
    e.url.isNotEmpty && !_isHttp(e.url) ? e.url : e.title;

bool _isHttp(String url) {
  final String lower = url.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// 拉播放列表条目的函数（生产 [youtubePlaylistEntries]；测试注入假件）。
typedef YoutubePlaylistLoader =
    Stream<YoutubePlaylistEntry> Function(String playlistId);

/// 一份 YouTube 播放列表的条目（进程内按列表 id 共享：换集换页后新页直接拿到已拉好的
/// 列表，不重拉）。条目按页增量到达，每到一批通知一次；刷新（过期后再次取用）时旧列表
/// 留着，新列表拉完整再整体换上，面板不会先缩短再变长。
class YoutubePlaylistEpisodes extends ChangeNotifier {
  YoutubePlaylistEpisodes._(this.playlistId);

  /// 进程内最多记这么多份列表（最近取用的留下）。
  static const int _kCacheSize = 8;

  /// 列表多久算旧（再取用时后台重拉一次，用户在 YouTube 上增删了条目能跟上）。
  static const Duration _kStaleAfter = Duration(minutes: 30);

  /// 首批这么多条就先亮面板，之后每 [_kPublishEvery] 条通知一次。
  static const int _kFirstPublish = 25;
  static const int _kPublishEvery = 100;

  static final LinkedHashMap<String, YoutubePlaylistEpisodes> _cache =
      LinkedHashMap<String, YoutubePlaylistEpisodes>();

  /// 生产拉取器；测试换成假件。
  @visibleForTesting
  static YoutubePlaylistLoader loader = youtubePlaylistEntries;

  /// 测试用：清进程缓存、还原拉取器与时钟。
  @visibleForTesting
  static void debugReset() {
    _cache.clear();
    loader = youtubePlaylistEntries;
    clock = DateTime.now;
  }

  /// 测试可换的时钟（判过期）。
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// 取 [playlistId] 的列表（没有就建），并确保它在拉 / 已拉好且不旧。
  static YoutubePlaylistEpisodes forPlaylist(String playlistId) {
    YoutubePlaylistEpisodes? list = _cache.remove(playlistId);
    list ??= YoutubePlaylistEpisodes._(playlistId);
    _cache[playlistId] = list;
    while (_cache.length > _kCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    list._ensureFresh();
    return list;
  }

  final String playlistId;

  List<YoutubePlaylistEntry> _entries = const <YoutubePlaylistEntry>[];

  /// 已到达的条目（按列表顺序；整体替换，从不原地改）。
  List<YoutubePlaylistEntry> get entries => _entries;

  bool _loading = false;
  bool get loading => _loading;

  DateTime? _completedAt;

  /// 最近一次拉取失败的原因（成功拉完后清掉）。
  Object? _error;
  Object? get error => _error;

  void _ensureFresh() {
    if (_loading) return;
    final DateTime? done = _completedAt;
    if (done != null && clock().difference(done) < _kStaleAfter) return;
    unawaited(_load());
  }

  Future<void> _load() async {
    _loading = true;
    // 刷新时旧列表留着，新列表拉完整才换上；第一次拉才按批亮出来。
    final bool progressive = _entries.isEmpty;
    final List<YoutubePlaylistEntry> acc = <YoutubePlaylistEntry>[];
    try {
      await for (final YoutubePlaylistEntry entry in loader(playlistId)) {
        acc.add(entry);
        if (progressive &&
            (acc.length == _kFirstPublish ||
                acc.length % _kPublishEvery == 0)) {
          _publish(acc);
        }
      }
      _error = null;
      _completedAt = clock();
      _publish(acc);
    } on Object catch (e, st) {
      _error = e;
      // 拉到一半断了：已到的照样能用（下次取用再重拉整份）。
      if (progressive && acc.isNotEmpty) _publish(acc);
      ErrorLogService.instance.log(
        'YoutubePlaylistEpisodes.$playlistId',
        e,
        st,
      );
    } finally {
      _loading = false;
    }
  }

  void _publish(List<YoutubePlaylistEntry> acc) {
    if (listEquals(acc, _entries)) return;
    _entries = List<YoutubePlaylistEntry>.unmodifiable(acc);
    notifyListeners();
  }

  /// [videoId] 在列表里的位置；不在（还没拉到 / 不在这份列表里）为 -1。
  int indexOfVideo(String videoId) =>
      _entries.indexWhere((YoutubePlaylistEntry e) => e.videoId == videoId);
}

/// 播放列表条目 → 选集，带上已落书各集的进度角标 / 本机封面（一次批量查库）。查库失败
/// 只少这两样，列表照常。
Future<List<StreamBookEpisode>> loadYoutubePlaylistBookEpisodes(
  VideoBookRepository repo,
  List<YoutubePlaylistEntry> entries,
) async {
  Map<String, VideoBookRow> rows = const <String, VideoBookRow>{};
  try {
    rows = <String, VideoBookRow>{
      for (final VideoBookRow row in await repo.getByBookUids(<String>[
        for (final YoutubePlaylistEntry e in entries)
          streamVideoBookUid(youtubeCanonicalWatchUrl(e.videoId)),
      ]))
        row.bookUid: row,
    };
  } on Object catch (e, st) {
    ErrorLogService.instance.log('StreamBookEpisode.playlistRows', e, st);
  }
  return youtubePlaylistBookEpisodes(entries, rows: rows);
}
