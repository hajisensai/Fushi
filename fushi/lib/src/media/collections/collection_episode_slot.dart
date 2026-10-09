import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart'
    show
        VideoNameInfo,
        parseVideoFilename,
        parseVideoPath,
        parsedEpisodeNumbersOf;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi_core/fushi_core.dart'
    show MediaCollectionItemRow, MediaCollectionRow, MediaKind, VideoBookRow;

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
  const CollectionEpisodeSlot.local(VideoBookRow this.local,
      {this.remoteMirror})
      : remote = null;
  const CollectionEpisodeSlot.remote(RemoteVideoInfo this.remote)
      : local = null,
        remoteMirror = null;

  /// 本机视频行；null = 该集只在对端。
  final VideoBookRow? local;

  /// 对端下发的远端条目；null = 该集在本机。
  final RemoteVideoInfo? remote;

  /// 本机这一集在远端源上的**同一集**（BUG-2978：本地成员与远端成员各占一槽）。
  ///
  /// 合集清单是跨端 union：媒体服务器（Jellyfin/Emby）按剧名把单集收养进同名本地
  /// 合集、互联 host 的文件名与本机不同，都会让同一集以两个 entryKey 同时在
  /// `media_collection_items` 里——本地一行 + 远端一行。两行不是两集，解析成员时
  /// 由 [pairRemoteEpisodesWithLocal] 归并成一槽：本地优先（播放、刮削资料、管理
  /// 动作都认 [local]），远端那份挂在这里保留为同一集的第二播放来源，不再单独
  /// 出一张远端卡、也不再进「下载远端集」清单（本机已经有了）。
  final RemoteVideoInfo? remoteMirror;

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

  /// 看完：本地行或其远端同集任一标记看完即算——在媒体服务器上看完的那一集，
  /// 归并后不能因为「本地优先」就变回未看。
  bool get completed => local != null
      ? local!.completedAt != null || remoteMirror?.completedAt != null
      : remote!.completedAt != null;

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
  // 同一集的本地成员与远端成员归并成一槽（本地优先），否则详情页每集出两张卡、
  // 「已看完 x/N」「选集 N」把同一集数两遍。
  final List<VideoBookRow> localMembers = <VideoBookRow>[
    for (final String key in videoKeys)
      if (localByUid[key] case final VideoBookRow local) local,
  ];
  final List<RemoteVideoInfo> remoteMembers = <RemoteVideoInfo>[
    for (final String key in videoKeys)
      if (!localByUid.containsKey(key))
        if (remoteById[key] case final RemoteVideoInfo info) info,
  ];
  final Map<String, String> localUidByRemoteId = pairRemoteEpisodesWithLocal(
    local: localMembers,
    remote: remoteMembers,
  );
  final Map<String, RemoteVideoInfo> mirrorByLocalUid =
      <String, RemoteVideoInfo>{
    for (final MapEntry<String, String> pair in localUidByRemoteId.entries)
      pair.value: remoteById[pair.key]!,
  };
  final List<CollectionEpisodeSlot> slots = <CollectionEpisodeSlot>[];
  for (final String key in videoKeys) {
    final VideoBookRow? local = localByUid[key];
    if (local != null) {
      slots.add(CollectionEpisodeSlot.local(
        local,
        remoteMirror: mirrorByLocalUid[key],
      ));
      continue;
    }
    // 已并进本地同集的远端成员不再单独占槽。
    if (localUidByRemoteId.containsKey(key)) continue;
    if (remoteById[key] case final RemoteVideoInfo info) {
      slots.add(CollectionEpisodeSlot.remote(info));
    }
  }
  return slots;
}

/// 跨来源的分集身份：季号（解析不出视作第 1 季，与分季分组同口径）+ 集号。
typedef CollectionEpisodeIdentity = ({int season, int episode});

/// 把**同一合集**里「本机有、远端也有」的同一集配对：返回 远端 id → 本地 bookUid。
///
/// 纯函数，合集详情页（[loadCollectionEpisodeSlots]）与库页混排（远端占位卡）
/// 共用同一判据，两处的集数口径因此一致。
///
/// 身份 = (季号, 集号)：本地从真实文件路径整批解析（与集卡序号同一个
/// [parsedEpisodeNumbersOf]，季号走 [parseVideoPath] 的父目录回落），远端从标题
/// 解析（媒体服务器标题是 `剧名 S01E02 集名`，互联 host 默认是文件名）。远端
/// 标题不是路径，故走 [parseVideoFilename]——`Fate/Zero` 这种带斜杠的剧名不能被
/// 当成目录切开。
///
/// 只配**两边各自唯一**的身份：同一身份在本地或远端出现多次（多版本、解析撞号）
/// 时宁可不并，也不把两集错并成一集；解析不出集号的（PV / 特典 / 电影）一律不并。
Map<String, String> pairRemoteEpisodesWithLocal({
  required List<VideoBookRow> local,
  required List<RemoteVideoInfo> remote,
}) {
  if (local.isEmpty || remote.isEmpty) return const <String, String>{};
  final List<int?> localEpisodes = parsedEpisodeNumbersOf(<String>[
    for (final VideoBookRow row in local) row.videoPath,
  ]);
  final Map<CollectionEpisodeIdentity, String?> localByIdentity =
      <CollectionEpisodeIdentity, String?>{};
  for (int i = 0; i < local.length; i++) {
    final int? episode = localEpisodes[i];
    if (episode == null) continue;
    final CollectionEpisodeIdentity identity = (
      season: parseVideoPath(local[i].videoPath).season ?? 1,
      episode: episode,
    );
    // 撞号 → 记 null（该身份作废），不按先来后到挑一个。
    localByIdentity[identity] =
        localByIdentity.containsKey(identity) ? null : local[i].bookUid;
  }
  if (localByIdentity.isEmpty) return const <String, String>{};
  final Map<CollectionEpisodeIdentity, String?> remoteByIdentity =
      <CollectionEpisodeIdentity, String?>{};
  for (final RemoteVideoInfo info in remote) {
    final VideoNameInfo parsed = parseVideoFilename(info.title);
    final int? episode = parsed.episode;
    if (episode == null) continue;
    final CollectionEpisodeIdentity identity =
        (season: parsed.season ?? 1, episode: episode);
    remoteByIdentity[identity] =
        remoteByIdentity.containsKey(identity) ? null : info.id;
  }
  final Map<String, String> pairs = <String, String>{};
  remoteByIdentity.forEach((CollectionEpisodeIdentity identity, String? id) {
    final String? uid = localByIdentity[identity];
    if (id != null && uid != null) pairs[id] = uid;
  });
  return pairs;
}

/// 库页口径的同一判据：按**合集**分桶后，返回已被本机同一集覆盖的远端 id 集合
/// （库页据此不再出远端占位卡，与详情页归并后的集数一致）。
///
/// [collectionOfEntry] 给出视频条目（本地 bookUid / 远端 id）所在的合集；不在
/// 合集里的条目没有「同一部作品」的上下文，一律不判重。
Set<String> remoteEpisodesMirroredLocally({
  required List<VideoBookRow> local,
  required List<RemoteVideoInfo> remote,
  required int? Function(String entryKey) collectionOfEntry,
}) {
  if (local.isEmpty || remote.isEmpty) return const <String>{};
  final Map<int, List<RemoteVideoInfo>> remoteByCollection =
      <int, List<RemoteVideoInfo>>{};
  for (final RemoteVideoInfo info in remote) {
    final int? cid = collectionOfEntry(info.id);
    if (cid != null) {
      (remoteByCollection[cid] ??= <RemoteVideoInfo>[]).add(info);
    }
  }
  if (remoteByCollection.isEmpty) return const <String>{};
  final Map<int, List<VideoBookRow>> localByCollection =
      <int, List<VideoBookRow>>{};
  for (final VideoBookRow row in local) {
    final int? cid = collectionOfEntry(row.bookUid);
    if (cid != null && remoteByCollection.containsKey(cid)) {
      (localByCollection[cid] ??= <VideoBookRow>[]).add(row);
    }
  }
  final Set<String> mirrored = <String>{};
  remoteByCollection.forEach((int cid, List<RemoteVideoInfo> members) {
    final List<VideoBookRow>? locals = localByCollection[cid];
    if (locals == null) return;
    mirrored.addAll(
      pairRemoteEpisodesWithLocal(local: locals, remote: members).keys,
    );
  });
  return mirrored;
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
    this.downloadMembers,
    this.scrapeOnHost,
    this.scrapeForHost,
    this.chooseTmdbOrderingOnHost,
    this.downloads,
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

  /// 把本合集**只在对端**的成员整批下载到本机（串行排队，见
  /// `InterconnectDownloadManager.startBatch`）。null = 该远端源不支持下载
  /// 到本地库（详情页不出「下载远端集」入口）。
  final Future<void> Function(
    MediaCollectionRow collection,
    List<RemoteVideoInfo> members,
  )? downloadMembers;

  /// 7a：让 host 用户选定的身份在 host 上重刮本合集（候选搜索也打到 host）。
  /// null = 对端不支持远程刮削。
  final Future<void> Function(MediaCollectionRow collection)? scrapeOnHost;

  /// 7b：本机刮削后把完整资料回写 host。null = 本机无刮削链或对端不支持。
  final Future<void> Function(MediaCollectionRow collection)? scrapeForHost;

  /// TMDB 备选排序（Shoko `PreferredAlternateOrderingID`）在 host 上选定并重刮。
  /// null = 对端不是互联 host。
  final Future<void> Function(MediaCollectionRow collection)?
      chooseTmdbOrderingOnHost;

  /// app 级互联下载管理器：详情页据它给**每一集**画下载进度 / 失败角标（任务键
  /// = 远端集 id = [CollectionEpisodeSlot.entryKey]，与库页远端占位卡同一张表）。
  /// 详情页是普通 StatefulWidget、既有测试不挂 `ProviderScope`，所以由库页注入
  /// 而不是页内取 provider；null = 集卡不画下载态（与注入前逐像素相同）。
  final InterconnectDownloadManager? downloads;
}
