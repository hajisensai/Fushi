import 'dart:typed_data';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_video_client.dart';

/// 一次 [FakeMediaServerBrowser.listChildren] / `search` / `listEpisodes` 调用的
/// 参数快照，测试据此断言「翻页只认 nextStartIndex」「排序切换重置分页」等契约。
class FakePageRequest {
  const FakePageRequest({
    required this.kind,
    this.parentId,
    this.query,
    this.seasonId,
    required this.startIndex,
    required this.limit,
    this.sort,
  });

  final String kind;
  final String? parentId;
  final String? query;
  final String? seasonId;
  final int startIndex;
  final int limit;
  final MediaServerSort? sort;

  @override
  String toString() =>
      'FakePageRequest($kind parent=$parentId query=$query season=$seasonId '
      'start=$startIndex limit=$limit sort=$sort)';
}

/// 内存版 [MediaServerBrowser]：数据可编程、失败可编程、请求有日志。
///
/// 页面只经契约接口消费，所以这里不模拟 HTTP，只模拟契约层面的行为：分页按
/// [startIndex] / [limit] 切片；[nextStartIndexShift] 模拟「实现侧滤掉了非视频域
/// 条目」——返回的 `nextStartIndex` 比 `startIndex + items.length` 多这么多，页面
/// 若自己算起点就会被抓到。
class FakeMediaServerBrowser implements MediaServerBrowser {
  FakeMediaServerBrowser({
    this.serverId = 'fake:server',
    this.displayName = 'Fake Server',
    this.serverUrl = 'http://fake:8096',
  });

  @override
  final String serverId;
  @override
  final String displayName;
  @override
  final String serverUrl;

  final List<MediaServerLibrary> libraries = <MediaServerLibrary>[];

  /// parentId（null 用 `''`）→ 子级。
  final Map<String, List<MediaServerItem>> children =
      <String, List<MediaServerItem>>{};

  /// seriesId → 季。
  final Map<String, List<MediaServerItem>> seasons =
      <String, List<MediaServerItem>>{};

  /// `'$seriesId|$seasonId'`（整部剧用 `'$seriesId|'`）→ 集。
  final Map<String, List<MediaServerItem>> episodes =
      <String, List<MediaServerItem>>{};
  final List<MediaServerItem> resume = <MediaServerItem>[];
  final List<MediaServerItem> nextUp = <MediaServerItem>[];
  final List<MediaServerItem> latest = <MediaServerItem>[];

  /// 搜索结果（不按 query 过滤，任何非空 query 都返回它）。
  final List<MediaServerItem> searchResults = <MediaServerItem>[];

  /// itemId → 详情（缺项时 [itemDetail] 抛）。
  final Map<String, MediaServerItem> details = <String, MediaServerItem>{};

  bool failLibraries = false;
  bool failChildren = false;
  bool failResume = false;
  bool failNextUp = false;
  bool failLatest = false;
  bool failSeasons = false;
  bool failEpisodes = false;
  bool failSearch = false;

  /// 见类文档；0 = 不偏移（`nextStartIndex` 缺省推导）。
  int nextStartIndexShift = 0;

  /// 设了就整页由它给（按 startIndex），绕过 [searchResults] 切片：用来造
  /// 「首页 0 条但 hasMore」这类把关后的形状（BUG-2608）。
  MediaServerPage Function(int startIndex, int limit)? searchPager;

  final List<FakePageRequest> requests = <FakePageRequest>[];
  int listLibrariesCalls = 0;
  int listResumeCalls = 0;
  int listNextUpCalls = 0;
  int listLatestCalls = 0;
  int listSeasonsCalls = 0;
  int itemDetailCalls = 0;

  final RemoteVideoClient _playback = _NoopRemoteVideoClient();

  @override
  RemoteVideoClient get playbackClient => _playback;

  @override
  String get coverCacheNamespace => 'fake-media-server';

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async =>
      throw UnsupportedError('fake browser has no covers');

  @override
  Future<List<MediaServerLibrary>> listLibraries() async {
    listLibrariesCalls++;
    if (failLibraries) throw StateError('libraries unavailable');
    return List<MediaServerLibrary>.of(libraries);
  }

  MediaServerPage _slice(List<MediaServerItem> all, int startIndex, int limit) {
    final int end = (startIndex + limit).clamp(0, all.length);
    final int start = startIndex.clamp(0, all.length);
    final List<MediaServerItem> items = all.sublist(start, end);
    // 偏移只在还没到尾时加，否则 hasMore 的判定会被偏移量本身骗过。
    final int? next = nextStartIndexShift == 0 || end >= all.length
        ? null
        : startIndex + items.length + nextStartIndexShift;
    return MediaServerPage(
      items: items,
      totalCount: all.length,
      startIndex: startIndex,
      nextStartIndex: next,
    );
  }

  @override
  Future<MediaServerPage> listChildren({
    required String? parentId,
    int startIndex = 0,
    int limit = kMediaServerPageSize,
    MediaServerSort sort = MediaServerSort.name,
  }) async {
    requests.add(
      FakePageRequest(
        kind: 'children',
        parentId: parentId,
        startIndex: startIndex,
        limit: limit,
        sort: sort,
      ),
    );
    if (failChildren) throw StateError('children unavailable');
    final List<MediaServerItem> all =
        children[parentId ?? ''] ?? const <MediaServerItem>[];
    return _slice(all, startIndex, limit);
  }

  @override
  Future<List<MediaServerItem>> listSeasons(String seriesId) async {
    listSeasonsCalls++;
    if (failSeasons) throw StateError('seasons unavailable');
    return List<MediaServerItem>.of(
      seasons[seriesId] ?? const <MediaServerItem>[],
    );
  }

  @override
  Future<MediaServerPage> listEpisodes({
    required String seriesId,
    String? seasonId,
    int startIndex = 0,
    int limit = kMediaServerEpisodePageSize,
  }) async {
    requests.add(
      FakePageRequest(
        kind: 'episodes',
        parentId: seriesId,
        seasonId: seasonId,
        startIndex: startIndex,
        limit: limit,
      ),
    );
    if (failEpisodes) throw StateError('episodes unavailable');
    final List<MediaServerItem> all =
        episodes['$seriesId|${seasonId ?? ''}'] ?? const <MediaServerItem>[];
    return _slice(all, startIndex, limit);
  }

  @override
  Future<List<MediaServerItem>> listResume({
    int limit = kMediaServerRowLimit,
  }) async {
    listResumeCalls++;
    if (failResume) throw StateError('resume unavailable');
    return resume.take(limit).toList();
  }

  @override
  Future<List<MediaServerItem>> listNextUp({
    int limit = kMediaServerRowLimit,
  }) async {
    listNextUpCalls++;
    if (failNextUp) throw StateError('next up unavailable');
    return nextUp.take(limit).toList();
  }

  @override
  Future<List<MediaServerItem>> listLatest({
    String? libraryId,
    int limit = kMediaServerRowLimit,
  }) async {
    listLatestCalls++;
    if (failLatest) throw StateError('latest unavailable');
    return latest.take(limit).toList();
  }

  @override
  Future<MediaServerPage> search(
    String query, {
    int startIndex = 0,
    int limit = kMediaServerPageSize,
  }) async {
    requests.add(
      FakePageRequest(
        kind: 'search',
        query: query,
        startIndex: startIndex,
        limit: limit,
      ),
    );
    if (query.trim().isEmpty) return const MediaServerPage.empty();
    if (failSearch) throw StateError('search unavailable');
    final MediaServerPage Function(int startIndex, int limit)? pager =
        searchPager;
    if (pager != null) return pager(startIndex, limit);
    return _slice(searchResults, startIndex, limit);
  }

  @override
  Future<MediaServerItem> itemDetail(String itemId) async {
    itemDetailCalls++;
    final MediaServerItem? detail = details[itemId];
    if (detail == null) throw StateError('no detail for $itemId');
    return detail;
  }

  @override
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  }) => null;

  @override
  String? libraryCoverUrl(
    MediaServerLibrary library, {
    int maxWidth = kMediaServerCoverMaxWidth,
  }) => null;

  @override
  RemoteVideoInfo toRemoteVideoInfo(MediaServerItem item) {
    if (!item.isPlayable) {
      throw ArgumentError.value(item.type, 'item', 'not playable');
    }
    return RemoteVideoInfo(id: item.id, title: item.name);
  }
}

/// 播放页 client 桩：浏览页只把它原样交给播放出口，不调任何成员。
class _NoopRemoteVideoClient implements RemoteVideoClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 造 N 部电影（id `prefix-N`）。
List<MediaServerItem> fakeMovies(int count, {String prefix = 'movie'}) =>
    <MediaServerItem>[
      for (int i = 0; i < count; i++)
        MediaServerItem(
          id: '$prefix-$i',
          name: 'Movie $i',
          type: MediaServerItemType.movie,
          productionYear: 2000 + i,
          durationMs: 90 * 60 * 1000,
          hasCover: false,
        ),
    ];

/// 造一部剧某一季的 N 集。
List<MediaServerItem> fakeEpisodes({
  required String seriesId,
  required String seasonId,
  required int seasonNumber,
  required int count,
}) => <MediaServerItem>[
  for (int i = 1; i <= count; i++)
    MediaServerItem(
      id: '$seasonId-ep$i',
      name: 'Episode $i',
      type: MediaServerItemType.episode,
      seriesId: seriesId,
      seriesName: 'Series $seriesId',
      seasonId: seasonId,
      seasonNumber: seasonNumber,
      episodeNumber: i,
      durationMs: 24 * 60 * 1000,
    ),
];
