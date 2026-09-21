import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// `RemoteVideoInfo.id` 的前缀：视频源扩展的一集。
///
/// 播放页把 id 当 `bookUid` 用（断点 / 字幕记忆 / 调轴都按它落 prefs），所以 id
/// 必须跨扩展不撞、跨刷新稳定：扩展包名 + 源 id + **源内集 URL**（Aniyomi 的
/// `SEpisode.url` 就是源内稳定身份，与漫画 `manga_chapter_states.chapterKey` 同一
/// 口径）。刻意不用列表下标——源刷新后新集插在前面，下标全体错位。
const String kAnimeSourceVideoIdPrefix = 'anime-source:';

/// 把一部在线作品（[MihonAnime] + 它的集列表）装成播放页能吃的 [RemoteVideoClient]。
///
/// 一集一条 [RemoteVideoInfo]，同一作品的集以 `playlist` 合集成员关联，播放页据
/// `remoteCollectionMembers` 建剧集列表并自动连播（换集 = 换成员 id）。取流走
/// 扩展的 `getVideoList`，选出的候选连同它的防盗链头一起记在本对象上，播放页紧
/// 接着的 load 经 [RemoteVideoStreamHeaders] 读到。
///
/// 浏览态零入库：本 client 只活在「作品页 → 播放」这一段，不进库页的远端清单缓存
/// （[listRemoteVideos] 只列本作品的集）。收藏入库是二期。
class AnimeSourceVideoClient
    implements
        RemoteVideoClient,
        RemoteCoverFetcher,
        RemoteVideoStreamHeaders,
        RemoteVideoStreamVariants {
  AnimeSourceVideoClient({
    required this.manager,
    required this.context,
    required this.anime,
    required List<MihonEpisode> episodes,
    http.Client? httpClient,
    MihonVideo Function(List<MihonVideo> candidates)? chooseVideo,
  }) : episodes = List<MihonEpisode>.unmodifiable(episodes),
       _httpClient = httpClient ?? createAppHttpIoClient(),
       _chooseVideo = chooseVideo ?? chooseBestAnimeVideo {
    _episodeIds = _buildEpisodeIds();
  }

  final MihonManager manager;
  final MihonSourceContext context;
  final MihonAnime anime;

  /// 按播放顺序（集号升序）排好的集列表；[remoteVideos] 与它同序。
  final List<MihonEpisode> episodes;
  final http.Client _httpClient;
  final MihonVideo Function(List<MihonVideo> candidates) _chooseVideo;

  /// 用户在作品页手动指定的候选（按集 id），优先于 [_chooseVideo]。
  final Map<String, MihonVideo> _pinnedVideos = <String, MihonVideo>{};

  /// 每集最近一次解析出的全部候选，供作品页的「线路 / 画质」选择器复用而不重取。
  final Map<String, List<MihonVideo>> _resolvedCandidates =
      <String, List<MihonVideo>>{};

  /// 最近一次 [remoteVideoStreamUrls] 选中的候选：它的头就是当前流的头。
  MihonVideo? _currentVideo;

  /// 最近一次取流的集 id：播放页的线路菜单（[streamVariants]）列的就是这一集的候选。
  String? _currentEpisodeId;

  AnimeMihonRuntime get _runtime => manager.animeRuntime;

  @override
  String get remoteLibrarySourceId =>
      'anime-source:${context.source.extensionPackage}:${context.source.id}';

  @override
  String get coverCacheNamespace => remoteLibrarySourceId;

  @override
  Map<String, String> get httpHeaderFields =>
      _currentVideo?.headers ?? const <String, String>{};

  /// 与 [episodes] 同序的集 id（见 [_buildEpisodeIds]）。
  late final List<String> _episodeIds;

  /// 本集在源内的稳定 id → 播放页 `bookUid`。
  String episodeVideoId(MihonEpisode episode) {
    final int index = episodes.indexOf(episode);
    return index >= 0 ? _episodeIds[index] : _baseEpisodeId(episode);
  }

  String _baseEpisodeId(MihonEpisode episode) =>
      '$kAnimeSourceVideoIdPrefix'
      '${context.source.extensionPackage}:${context.source.id}:'
      '${episode.url}';

  /// 集 id 以 `episode.url` 为身份；有的扩展把身份放在集号 / 名字上而 url 相同（或
  /// 为空），那样整部作品所有集都解析成同一条 id：换哪一集都取回第一集的流、断点 /
  /// 字幕记忆互相覆盖，表现为「点下一集还是这一集」。撞车的 id 追加集号去重（集号
  /// 也撞再追加下标兜底），不撞的保持原样（既有断点键不变）。
  List<String> _buildEpisodeIds() {
    final List<String> base = <String>[
      for (final MihonEpisode episode in episodes) _baseEpisodeId(episode),
    ];
    final Map<String, int> baseCounts = <String, int>{};
    for (final String id in base) {
      baseCounts[id] = (baseCounts[id] ?? 0) + 1;
    }
    final List<String> ids = <String>[
      for (int i = 0; i < base.length; i++)
        baseCounts[base[i]]! > 1
            ? '${base[i]}#${episodes[i].number.toStringAsFixed(0)}'
            : base[i],
    ];
    final Map<String, int> counts = <String, int>{};
    for (final String id in ids) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return <String>[
      for (int i = 0; i < ids.length; i++)
        counts[ids[i]]! > 1 ? '${ids[i]}/$i' : ids[i],
    ];
  }

  MihonEpisode? episodeForVideoId(String id) {
    final int index = _episodeIds.indexOf(id);
    return index >= 0 ? episodes[index] : null;
  }

  /// 本作品全部集的播放页 DTO，与 [episodes] 同序；播放页拿它当
  /// `remoteCollectionMembers`。
  List<RemoteVideoInfo> get remoteVideos => <RemoteVideoInfo>[
    for (int index = 0; index < episodes.length; index++)
      _infoFor(episodes[index], index),
  ];

  RemoteVideoInfo _infoFor(MihonEpisode episode, int index) => RemoteVideoInfo(
    id: episodeVideoId(episode),
    title: episode.name.isNotEmpty ? episode.name : anime.title,
    hasCover: anime.coverUrl != null && anime.coverUrl!.isNotEmpty,
    coverUrl: anime.coverUrl,
    collection: RemoteCollectionMembership(
      collectionName: anime.title,
      collectionType: 'playlist',
      sortIndex: index,
    ),
  );

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => remoteVideos;

  /// 解析一集的全部候选（缓存一份供选择器复用）。
  Future<List<MihonVideo>> resolveVideos(
    MihonEpisode episode, {
    bool refresh = false,
  }) async {
    final String id = episodeVideoId(episode);
    final List<MihonVideo>? cached = _resolvedCandidates[id];
    if (!refresh && cached != null) return cached;
    final List<MihonVideo> videos = await _runtime.getVideos(
      context.extension,
      context.source,
      episode,
      preferences: context.preferences,
    );
    _resolvedCandidates[id] = videos;
    return videos;
  }

  /// 为某集钉住一条候选（线路 / 画质）：下一次取该集的流用它，不再走默认策略。
  void pinVideo(MihonEpisode episode, MihonVideo video) {
    _pinnedVideos[episodeVideoId(episode)] = video;
  }

  /// 当前集已解析的候选；尚未取流为空。
  List<MihonVideo> get _currentCandidates {
    final String? id = _currentEpisodeId;
    return id == null
        ? const <MihonVideo>[]
        : _resolvedCandidates[id] ?? const <MihonVideo>[];
  }

  /// 播放页线路菜单：当前集的全部候选，按扩展给的顺序（它已按用户在扩展设置里
  /// 的画质 / 语言偏好排过）。
  @override
  List<RemoteVideoStreamVariant> get streamVariants =>
      <RemoteVideoStreamVariant>[
        for (final MihonVideo video in _currentCandidates)
          RemoteVideoStreamVariant(label: streamVariantLabel(video)),
      ];

  @override
  int get streamVariantIndex {
    final MihonVideo? current = _currentVideo;
    if (current == null) return -1;
    return _currentCandidates.indexOf(current);
  }

  /// 用户在播放页换线路：钉到当前集，播放页随后重新取流即播这一条。
  @override
  set streamVariantIndex(int index) {
    final String? id = _currentEpisodeId;
    final List<MihonVideo> candidates = _currentCandidates;
    if (id == null || index < 0 || index >= candidates.length) return;
    _pinnedVideos[id] = candidates[index];
  }

  /// 候选在菜单里的文案：扩展给的画质 / 线路名，没给就退到流的主机名（同一集多家
  /// hoster 时至少能分辨是哪一家）。
  static String streamVariantLabel(MihonVideo video) {
    if (video.quality.isNotEmpty) return video.quality;
    final String host = Uri.tryParse(video.resolvedUrl)?.host ?? '';
    return host.isNotEmpty ? host : video.resolvedUrl;
  }

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    final MihonEpisode? episode = episodeForVideoId(id);
    if (episode == null) {
      throw ArgumentError.value(id, 'id', 'not an episode of this anime');
    }
    final List<MihonVideo> candidates = await resolveVideos(episode);
    if (candidates.isEmpty) {
      throw const MihonRuntimeException(
        'NO_VIDEOS',
        'Source did not return any playable video for this episode',
      );
    }
    final MihonVideo chosen = _pinnedVideos[id] ?? _chooseVideo(candidates);
    _currentVideo = chosen;
    _currentEpisodeId = id;
    final MihonVideoTrack? subtitle = chosen.subtitleTracks.firstOrNull;
    final String streamUrl = chosen.resolvedUrl;
    return RemoteVideoStreamUrls(
      streamUrl: streamUrl,
      subtitleUrl: subtitle?.url,
      subtitleFileName: subtitle == null
          ? null
          : subtitleFileNameFor(subtitle, episode),
      // Aniyomi lib-14 的 `Video.audioTracks` 是**可选替代配音轨**（流本身带原声），
      // 不是 YouTube 那种 audio-only 分离流；[RemoteVideoStreamUrls.audioStreamUrl]
      // 的契约是后者（播放页会 audio-add 并选中它），塞进去会默认切到第一条配音、
      // 制卡也从它裁。替代音轨选择器留二期，这里恒 null。
      audioStreamUrl: null,
      // HLS 是转封装的分片流，不带原容器的内嵌字幕轨。
      streamIsOriginalContainer: !isHlsStreamUrl(streamUrl),
    );
  }

  /// 外挂字幕落盘名：保留源给的扩展名（`.vtt` / `.srt` / `.ass`），缺省 `.vtt`
  /// （Aniyomi 生态的字幕轨绝大多数是 WebVTT）。
  static String subtitleFileNameFor(
    MihonVideoTrack track,
    MihonEpisode episode,
  ) {
    final String path = Uri.tryParse(track.url)?.path ?? '';
    final String extension = p.extension(path).toLowerCase();
    final String suffix =
        const <String>{'.vtt', '.srt', '.ass', '.ssa'}.contains(extension)
        ? extension
        : '.vtt';
    // `\w` 在 Dart 里只认 ASCII，源给的语言标签多半是「日本語」这类：按 Unicode
    // 字母/数字保留，其余（空格、斜杠、括号）折成下划线。
    final String lang = track.lang.replaceAll(
      RegExp(r'[^\p{L}\p{N}\-]+', unicode: true),
      '_',
    );
    return 'episode_${episode.number.toStringAsFixed(0)}'
        '${lang.isEmpty ? '' : '.$lang'}$suffix';
  }

  static bool isHlsStreamUrl(String url) {
    final String path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  /// 字幕轨与流同一个站点时才带流的头（防盗链站点的字幕也在同一防盗链之下），
  /// 跨站一律不带——与 `UrlStreamVideoClient` 的口径一致。
  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    final MihonVideo? video = _currentVideo;
    final MihonVideoTrack? track = video?.subtitleTracks.firstOrNull;
    if (video == null || track == null) return;
    final Uri subtitleUri = Uri.parse(track.url);
    final Uri streamUri = Uri.parse(video.resolvedUrl);
    final bool sameSite =
        subtitleUri.scheme == streamUri.scheme &&
        subtitleUri.host == streamUri.host &&
        subtitleUri.port == streamUri.port;
    final http.Response response = await _httpClient.get(
      subtitleUri,
      headers: sameSite && video.headers.isNotEmpty ? video.headers : null,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'subtitle download failed: HTTP ${response.statusCode}',
        subtitleUri,
      );
    }
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(response.bodyBytes);
    onProgress?.call(1.0);
  }

  /// 在线源的整片下载是二期（直链可下、HLS 要分片合并）；本期与粘贴 URL 流同口径。
  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    throw UnsupportedError('anime source stream not downloadable');
  }

  /// 源站没有断点端点：断点走本地 prefs（播放页按 id 落），这里恒 (0, 0)。
  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}

  /// 封面必须经扩展自己的 OkHttp 客户端取（站点 Referer / cookie / 拦截器），裸
  /// `Image.network` 在防盗链站点上是空图。
  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) =>
      manager.runtime.fetchSourceImage(
        context.extension,
        context.source,
        coverUrl,
        preferences: context.preferences,
      );

  void dispose() {
    _httpClient.close();
  }
}

/// 默认选流策略，与 Aniyomi 播放器的 `HosterLoader.selectBestVideo` 同口径：
/// 扩展标了 `preferred` 的第一条优先；否则取扩展给的第一条——宿主已经按扩展自己
/// 的 `sortVideos` / `sort`（用户在扩展设置里选的画质、语言偏好）排过序，第一条
/// 就是它认为最合适的。此前按「行数最高」硬选会把扩展设置里的画质偏好整个作废
/// （用户选 720p 省流量也永远被推成 1080p）。
MihonVideo chooseBestAnimeVideo(List<MihonVideo> candidates) {
  for (final MihonVideo candidate in candidates) {
    if (candidate.preferred) return candidate;
  }
  return candidates.first;
}

/// 播放顺序：集号升序（源多半新集在前），集号相同按上传时间，再按原顺序稳定。
List<MihonEpisode> sortEpisodesForPlayback(List<MihonEpisode> episodes) {
  final List<(int, MihonEpisode)> indexed = <(int, MihonEpisode)>[
    for (int i = 0; i < episodes.length; i++) (i, episodes[i]),
  ];
  indexed.sort(((int, MihonEpisode) a, (int, MihonEpisode) b) {
    final int byNumber = a.$2.number.compareTo(b.$2.number);
    if (byNumber != 0) return byNumber;
    final int byUpload = a.$2.uploadedAt.compareTo(b.$2.uploadedAt);
    if (byUpload != 0) return byUpload;
    return a.$1.compareTo(b.$1);
  });
  return <MihonEpisode>[
    for (final (int, MihonEpisode) item in indexed) item.$2,
  ];
}
