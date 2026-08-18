import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi_core/fushi_core.dart'
    show MediaCollectionItemRow, MediaKind, VideoBookRow;

/// 合集的一个**成员槽**：本地视频行 [local] 或「只在对端、本机没有」的远端占位
/// [remote]，二者恰一非空。
///
/// 为什么合集成员不能只是 [VideoBookRow]：合集清单是**跨端 union**
/// （`CollectionSyncEngine` / `applyCollectionLocalChanges`），互联客户端本地的
/// `media_collection_items` 里必然存在「entryKey 是 host 侧 bookUid、本机没有对应
/// 视频行」的成员行。把成员窄化成本地行，等于在客户端把整个合集判空
/// （BUG-1704：详情页显示「合集为空」）。库页早就用同构的 `_VideoSlot` 混排本地卡与
/// 远端占位卡，详情页沿用同一模型。
///
/// 能力边界与库页一致：远端槽只支持**流播 / 下载**，不参与任何写本地库的管理动作
/// （改集名、批量字幕、补缺集、删除本体）——那些动作的调用方取 [local] 子集。
class CollectionEpisodeSlot {
  const CollectionEpisodeSlot.local(VideoBookRow this.local) : remote = null;
  const CollectionEpisodeSlot.remote(RemoteVideoInfo this.remote)
      : local = null;

  /// 本机视频行；null = 该集只在对端。
  final VideoBookRow? local;

  /// 对端下发的远端条目；null = 该集在本机。
  final RemoteVideoInfo? remote;

  /// 该集只在对端（渲染云角标、禁用本地管理动作的唯一判据）。
  bool get isRemote => local == null;

  /// 成员键：本地是 `VideoBooks.bookUid`，远端是 host 侧的 video id——二者同域
  /// （host 下发的 id 就是它自己的 bookUid），故也正是本地 `media_collection_items`
  /// 里那一行的 `entryKey`。
  String get entryKey => local?.bookUid ?? remote!.id;

  String get title => local?.title ?? remote!.title;

  /// 集号 / 分季解析的输入：本地用真实文件路径，远端只有 host 给的标题
  /// （host 端标题默认就是文件名，解析不出时各调用方自有回落）。
  String get filename => local?.videoPath ?? remote!.title;

  int get positionMs => local?.lastPositionMs ?? remote!.positionMs;

  bool get completed =>
      local != null ? local!.completedAt != null : remote!.completedAt != null;

  /// 最近播放时刻（epoch 毫秒）；远端的真相源是 host 下发的进度更新戳，与首页
  /// 「继续观看」行同一口径。
  int? get lastPlayedAtMs =>
      local != null ? local!.lastPlayedAt : remote!.positionUpdatedAtMs;

  int? get importedAt => local?.importedAt ?? remote?.importedAt;

  /// 封面本地路径（远端槽恒 null，封面走 [remoteCoverUrl]）。
  String? get coverPath => local?.coverPath;

  String? get remoteCoverUrl => remote?.coverUrl;
}

/// 解析一个合集的**有序**视频成员槽（本地行 + 只在对端的远端占位）。
///
/// 顺序即 `media_collection_items` 的落盘序（跨端 LWW 同步的合集序），远端成员天然
/// 落在它在 host 上的位置——「第 5 集只在 host、1~4 在本机」显示成连续的 1..5，而不是
/// 把远端集堆到末尾。
///
/// [loadRemoteVideos] = null（日历页一类没有远端上下文的调用方）或对端不可达时，
/// 解析不到本地行的成员**照旧丢弃**，与远端支持引入前逐字节同行为。
Future<List<CollectionEpisodeSlot>> loadCollectionEpisodeSlots({
  required VideoBookRepository repository,
  required int collectionId,
  Future<List<RemoteVideoInfo>> Function()? loadRemoteVideos,
}) async {
  final List<MediaCollectionItemRow> items =
      await repository.getCollectionItems(collectionId);
  final List<String> videoKeys = <String>[
    for (final MediaCollectionItemRow item in items)
      if (item.mediaType == MediaKind.video.dbValue) item.entryKey,
  ];
  final Map<String, VideoBookRow> localByUid = <String, VideoBookRow>{};
  for (final String key in videoKeys) {
    final VideoBookRow? row = await repository.getByBookUid(key);
    if (row != null) localByUid[key] = row;
  }
  final bool anyMissing =
      videoKeys.any((String key) => !localByUid.containsKey(key));
  Map<String, RemoteVideoInfo> remoteById = const <String, RemoteVideoInfo>{};
  // 全员本地时一次远端清单都不问：详情页是高频入口，没有缺口就没有理由付网络/缓存
  // 代价（有缓存也仍是一次 provider 往返）。
  if (anyMissing && loadRemoteVideos != null) {
    try {
      final List<RemoteVideoInfo> remote = await loadRemoteVideos();
      remoteById = <String, RemoteVideoInfo>{
        for (final RemoteVideoInfo info in remote) info.id: info,
      };
    } catch (_) {
      // 离线 / 未配对 / 拉取失败：退化成「只有本地成员」，与库页远端占位卡的离线
      // 语义一致（不显示占位，绝不因为对端不可达就让页面报错）。
      remoteById = const <String, RemoteVideoInfo>{};
    }
  }
  return <CollectionEpisodeSlot>[
    for (final String key in videoKeys)
      if (localByUid[key] case final VideoBookRow local)
        CollectionEpisodeSlot.local(local)
      else if (remoteById[key] case final RemoteVideoInfo info)
        CollectionEpisodeSlot.remote(info),
  ];
}

/// 合集视图的**远端上下文**：让「只在对端」的成员能列出、能播、能取封面。
///
/// 三件事必然同生共死——有互联 client 才拿得到远端清单、才有带鉴权的封面链、才有
/// 流播入口，所以合成一个可空注入而不是三个各自为政的回调。null = 调用方没有远端
/// 上下文（如日历页），合集视图退化成纯本地，与远端支持引入前逐字节相同。
class CollectionRemoteContext {
  const CollectionRemoteContext({
    required this.loadRemoteVideos,
    required this.openEpisode,
    this.coverFetcher,
  });

  /// 拉对端视频清单（调用方走共享的 [RemoteLibraryCache]，TTL 内不打网络）。
  final Future<List<RemoteVideoInfo>> Function() loadRemoteVideos;

  /// 打开一个远端成员：收到本合集**全部**远端成员与起播下标，播放器据此建剧集
  /// 列表并跨成员连播（与库页远端占位卡同一入口）。
  final void Function(
    RemoteVideoInfo episode,
    List<RemoteVideoInfo> members,
    int index,
  ) openEpisode;

  /// 远端封面取数器（钉扎 HTTP 客户端）；null = 远端集只画占位图标。
  final RemoteCoverFetcher? coverFetcher;
}
