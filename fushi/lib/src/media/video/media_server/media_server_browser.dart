import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

/// 「可浏览的外部媒体服务器」契约（Jellyfin / Emby 是第一个实现；Plex 等之后照抄）。
///
/// **为什么不复用 [RemoteVideoSource.listRemoteVideos]**——那条契约是「一次性全量
/// 清单 → 混排占位卡」，它是互联 host 的形状：对端库就几百条，全量下发天经地义。
/// 媒体服务器不是：几十万条目的公共 Emby 服一进视频页就全库递归（BUG-1891），
/// 而且服务器自己有 媒体库 → 剧 → 季 → 集 的树，被拍平成叶子清单后剧的身份
/// （Series GUID）当场丢失，只能靠剧名字符串在客户端重新折叠。
///
/// 本接口把服务器的树**原样**暴露出来：每一层都是按父级分页的，客户端永远只持有
/// 当前屏幕那一页；播放仍走 [RemoteVideoClient] 既有的流播 / 字幕 / 断点契约，
/// 不另造播放路径。
///
/// 能力判据沿用本仓口径：`client is MediaServerBrowser` 是类型系统认可的判断，
/// 拿不到能力的源（互联 / 云盘 / URL 直链）根本调不出浏览方法。
///
/// **失败语义分两档**（实现按此口径，页面按此消费）：
/// - 主干导航（[listLibraries] / [listChildren] / [search] / [itemDetail]）走的
///   都是 `/Users/{uid}/Views` 与 `/Users/{uid}/Items` 这两条已在 Jellyfin / Emby /
///   飞牛影视三家验过的端点，失败就是真失败（断网 / 令牌失效 / 服务器 5xx），
///   **抛出**，页面据此显示错误与重试；
/// - 首页装饰行（[listResume] / [listNextUp] / [listLatest]）与剧集树
///   （[listSeasons] / [listEpisodes]）走的 `/Shows/*`、`/Items/Resume`、
///   `/Items/Latest` 在飞牛等兼容层上不保证存在。剧集树失败先回退到通用
///   `/Items?ParentId=` 树（那条三家都通），装饰行则**失败即空 + debugPrint**，
///   不把一条可有可无的行的失败抛成整页错误。
abstract interface class MediaServerBrowser implements RemoteCoverFetcher {
  /// 服务器身份（= [RemoteLibrarySource.remoteLibrarySourceId] 同口径：同 id 必须
  /// 意味着「问它要清单会得到同一份东西」）。页面用它做 PageStorage / 缓存键。
  String get serverId;

  /// 用户可见的服务器名（服务器自报名，缺省回落主机名）。
  String get displayName;

  /// 服务器根 URL（归一化后，无尾斜杠），只用于展示。
  String get serverUrl;

  /// 播放能力：把浏览到的叶子交给既有播放页（`VideoFushiPage.neutralizedRemote`）
  /// 时用的 client。对 Jellyfin 就是自己。
  RemoteVideoClient get playbackClient;

  /// 媒体库清单（Jellyfin `/Users/{uid}/Views`）。只返回视频域的库；音乐 / 图书 /
  /// 照片库在实现侧滤掉。
  Future<List<MediaServerLibrary>> listLibraries();

  /// 列 [parentId] 的直接子级，按父级分页（Jellyfin `/Users/{uid}/Items?ParentId=`）。
  ///
  /// [parentId] 可以是媒体库 id、文件夹 id、BoxSet id；null = 服务器根（一般不用，
  /// 页面从 [listLibraries] 进来）。返回的条目类型不限：剧集库返回 Series，电影库
  /// 返回 Movie，混合库两者都有。[sort] 缺省按名称。
  ///
  /// 非视频域类型（Audio / MusicAlbum / Book / Photo…）在实现侧滤掉，所以一页的
  /// `items.length` 可能小于服务器实际返回的行数——翻页**只认**
  /// [MediaServerPage.nextStartIndex]，别自己拿 `startIndex + items.length` 算。
  Future<MediaServerPage> listChildren({
    required String? parentId,
    int startIndex = 0,
    int limit = kMediaServerPageSize,
    MediaServerSort sort = MediaServerSort.name,
  });

  /// 一部剧的季清单（Jellyfin `/Shows/{seriesId}/Seasons`）。季通常个位数，不分页。
  Future<List<MediaServerItem>> listSeasons(String seriesId);

  /// 一部剧（或其中一季）的集清单，按季集号升序，分页
  /// （Jellyfin `/Shows/{seriesId}/Episodes?SeasonId=`）。[seasonId] null = 整部剧。
  Future<MediaServerPage> listEpisodes({
    required String seriesId,
    String? seasonId,
    int startIndex = 0,
    int limit = kMediaServerEpisodePageSize,
  });

  /// 「继续观看」（Jellyfin `/Users/{uid}/Items/Resume`）：服务器端有断点的叶子。
  Future<List<MediaServerItem>> listResume({int limit = kMediaServerRowLimit});

  /// 「接下来看」（Jellyfin `/Shows/NextUp`）：每部在看的剧的下一集。
  Future<List<MediaServerItem>> listNextUp({int limit = kMediaServerRowLimit});

  /// 「最近添加」（Jellyfin `/Users/{uid}/Items/Latest`）。[libraryId] null = 全部。
  ///
  /// 服务器把剧集库的新集折成 Series 容器返回（Jellyfin `GroupItems` 缺省），所以
  /// 这里会混着 Series 与 Movie；null 时服务器还会把音乐 / 图书库的新条目一起给
  /// 出来再被实现侧滤掉，[limit] 会被它们吃掉一部分——想要每库准数就按库分别问。
  Future<List<MediaServerItem>> listLatest({
    String? libraryId,
    int limit = kMediaServerRowLimit,
  });

  /// 全服务器搜索（Jellyfin `/Users/{uid}/Items?SearchTerm=&Recursive=true`），
  /// 只搜 Movie / Series 两种（集在剧里下钻；单值 `IncludeItemTypes` 各一轮，
  /// BUG-2254），按「电影在前、剧在后」的拼接序分页。空白 [query] 不发请求，直接
  /// 空页。
  ///
  /// 服务器的 `SearchTerm` 语义各家不同（兼容层会按字模糊，BUG-2608），实现侧
  /// **必须**再按 `rankMediaServerSearchHits` 把关：只留标题 / 原名真含查询词的
  /// 条目，页内精确同名置顶。因此 [startIndex] / [MediaServerPage.nextStartIndex]
  /// 是**服务器行**偏移、[MediaServerPage.totalCount] 是两轮服务器总数（命中数的
  /// 上界，不是命中数）；一页的 `items.length` 可以少于 [limit]（甚至为 0）而
  /// [MediaServerPage.hasMore] 仍为 true——页面照常按 nextStartIndex 翻，也可以
  /// 略多于 [limit]（最后一发服务器页整页把关后全收）。
  Future<MediaServerPage> search(
    String query, {
    int startIndex = 0,
    int limit = kMediaServerPageSize,
  });

  /// 单条目详情（Jellyfin `/Users/{uid}/Items/{id}`，含简介 / 类型 / 评分）。
  /// 失败抛出；调用方拿着清单里的那条 best-effort 回退即可（与
  /// `RemoteVideoDetailFetch.remoteVideoDetail` 同款口径）。
  Future<MediaServerItem> itemDetail(String itemId);

  /// 条目封面 URL（带尺寸上限；服务器侧缩放，客户端不再解原图）。无图返回 null。
  /// [kind] 缺省主图；横版背景 / logo 由页面按需要求（分别按
  /// [MediaServerItem.hasBackdrop] / [MediaServerItem.hasThumb] /
  /// [MediaServerItem.hasLogo] 判有无）。
  String? coverUrl(
    MediaServerItem item, {
    int maxWidth = kMediaServerCoverMaxWidth,
    MediaServerImageKind kind = MediaServerImageKind.primary,
  });

  /// 媒体库自身的封面 URL（[MediaServerLibrary.hasCover] 为 false 时 null）。
  String? libraryCoverUrl(
    MediaServerLibrary library, {
    int maxWidth = kMediaServerCoverMaxWidth,
  });

  /// 把一个**可播放叶子**（Movie / Episode）适配成既有播放页消费的
  /// [RemoteVideoInfo]。非叶子抛 [ArgumentError]。
  ///
  /// 页面把当前季（或整部剧）的集清单逐条过这里，得到播放页的
  /// `remoteCollectionMembers`，剧集面板与上下集就都有了。
  RemoteVideoInfo toRemoteVideoInfo(MediaServerItem item);
}

/// 网格一页的条目数。桌面 6 列 × 10 行，移动端 3 列 × 20 行，都在一页内可滚一段。
const int kMediaServerPageSize = 60;

/// 集清单一页的条目数（横向轨道 / 列表，条目轻）。
const int kMediaServerEpisodePageSize = 100;

/// 首页横滚行（继续观看 / 接下来 / 最近添加）的条目上限。
const int kMediaServerRowLimit = 20;

/// 封面请求的宽度上限（像素）。与本地封面解码上限 `kLocalCoverDecodePixelWidth`
/// 同量级：网格卡最宽约 240 逻辑像素 × 3 倍 dpr。
const int kMediaServerCoverMaxWidth = 720;

/// 服务器上的一个媒体库（Jellyfin「视图」）。
class MediaServerLibrary {
  const MediaServerLibrary({
    required this.id,
    required this.name,
    required this.kind,
    this.hasCover = false,
  });

  final String id;
  final String name;
  final MediaServerLibraryKind kind;

  /// 库本身有没有主图（Jellyfin 库视图可以有封面）。
  final bool hasCover;
}

enum MediaServerLibraryKind {
  movies,
  tvShows,

  /// 混合 / 家庭视频 / 未标类型的视频库。
  mixed,
}

/// 条目类型。服务器的其它类型（Audio / Book / Photo…）在实现侧滤掉，不进来。
enum MediaServerItemType {
  movie,
  series,
  season,
  episode,

  /// BoxSet / Playlist / 普通文件夹：可继续下钻但本身不可播。
  folder,
}

enum MediaServerSort { name, dateAdded, premiereDate, communityRating }

enum MediaServerImageKind { primary, backdrop, thumb, logo }

/// 服务器上的一个条目（电影 / 剧 / 季 / 集 / 文件夹）。
///
/// 字段只保留浏览与播放要用的；不带 MediaSources 这类重字段（那是
/// `RemoteVideoDetailFetch` 单条目按需补的，见 BUG-1891）。
class MediaServerItem {
  const MediaServerItem({
    required this.id,
    required this.name,
    required this.type,
    this.originalTitle,
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.seasonNumber,
    this.episodeNumber,
    this.productionYear,
    this.durationMs,
    this.positionMs = 0,
    this.lastPlayedAtMs = 0,
    this.played = false,
    this.playedPercentage,
    this.childCount,
    this.episodeCount,
    this.unplayedChildCount,
    this.hasCover = false,
    this.hasBackdrop = false,
    this.hasThumb = false,
    this.hasLogo = false,
    this.parentThumbItemId,
    this.parentBackdropItemId,
    this.overview,
    this.communityRating,
    this.genres = const <String>[],
    this.hasSubtitle = false,
  });

  final String id;
  final String name;
  final MediaServerItemType type;

  /// 原名（Jellyfin / Emby `OriginalTitle`）：中文库里通常是外文原题。搜索把关
  /// （`media_server_search_match.dart`）拿它和 [name] 一起匹配，用户按原题搜也能命中。
  final String? originalTitle;

  /// 集 / 季所属的剧（Jellyfin `SeriesId` / `SeriesName`）。
  final String? seriesId;
  final String? seriesName;

  /// 集所属的季（Jellyfin `SeasonId`）。
  final String? seasonId;

  /// 季号（对 Season 是自身序号，对 Episode 是 `ParentIndexNumber`）。
  final int? seasonNumber;

  /// 集号（`IndexNumber`）。
  final int? episodeNumber;
  final int? productionYear;
  final int? durationMs;

  /// 服务器端断点（`UserData.PlaybackPositionTicks` → ms）。0 = 无。
  final int positionMs;

  /// 断点更新时刻（`UserData.LastPlayedDate` → epoch ms）。0 = 无。
  final int lastPlayedAtMs;

  /// 服务器端标记为已看完（`UserData.Played`）。
  final bool played;
  final double? playedPercentage;

  /// 容器的子项数（剧的集数 / 季数、文件夹的条目数）。
  final int? childCount;

  /// 剧的总集数（Jellyfin `RecursiveItemCount`）。[childCount] 对剧是季数，
  /// 显示「全 N 话」必须用这个。
  final int? episodeCount;

  /// 容器的未看子项数（`UserData.UnplayedItemCount`）。
  final int? unplayedChildCount;
  final bool hasCover;
  final bool hasBackdrop;

  /// 横版缩略图 / logo 有无（Jellyfin `ImageTags.Thumb` / `ImageTags.Logo`）；
  /// [MediaServerBrowser.coverUrl] 按它们决定要不要给 URL，免得页面拿着一个
  /// 必 404 的地址去请求。
  final bool hasThumb;
  final bool hasLogo;

  /// 集 / 季可借用的上级横图所在条目 id（通常是剧）：Thumb 与 Backdrop 各一。
  /// 只在服务器确实报了对应图片 tag 时非 null。拿它们取图时把 id 当成一个
  /// `hasThumb` / `hasBackdrop` 的条目交给 [MediaServerBrowser.coverUrl] 即可。
  final String? parentThumbItemId;
  final String? parentBackdropItemId;
  final String? overview;
  final double? communityRating;
  final List<String> genres;

  /// 服务器粗粒度 `HasSubtitles`（图形轨也算 true；精确判断在播放页按详情取）。
  final bool hasSubtitle;

  bool get isPlayable =>
      type == MediaServerItemType.movie || type == MediaServerItemType.episode;

  bool get isContainer => !isPlayable;

  /// `S01E02` 形态的季集编码；缺号返回空串。
  String get episodeCode {
    if (type != MediaServerItemType.episode ||
        seasonNumber == null ||
        episodeNumber == null) {
      return '';
    }
    return 'S${seasonNumber.toString().padLeft(2, '0')}'
        'E${episodeNumber.toString().padLeft(2, '0')}';
  }
}

/// 一页条目 + 服务器报的总数；[hasMore] 由页面决定要不要继续翻。
class MediaServerPage {
  const MediaServerPage({
    required this.items,
    required this.totalCount,
    required this.startIndex,
    int? nextStartIndex,
  }) : _nextStartIndex = nextStartIndex;

  const MediaServerPage.empty()
    : items = const <MediaServerItem>[],
      totalCount = 0,
      startIndex = 0,
      _nextStartIndex = null;

  final List<MediaServerItem> items;
  final int totalCount;
  final int startIndex;

  /// 实现在客户端滤掉了非视频域类型时显式给出的下一页起点（= 服务器实际返回的
  /// 行数 + [startIndex]）；null = 没滤，按 `items.length` 推。
  final int? _nextStartIndex;

  bool get hasMore => nextStartIndex < totalCount;

  /// 下一页起点（[hasMore] 为 false 时无意义）。翻页只认它：一页里被实现侧滤掉的
  /// 条目在服务器那边照样占着序号，拿 `startIndex + items.length` 会把下一页的
  /// 前几条重复取回来。
  int get nextStartIndex => _nextStartIndex ?? startIndex + items.length;
}
