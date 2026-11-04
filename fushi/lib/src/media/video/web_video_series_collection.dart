// 网页档流媒体剧集 → playlist 合集（GBDddvjDsj / BUG-4024 流媒体部分）。
//
// 网页档每播一集落一本独立的流媒体书（`ensureWebVideoEpisodeBook`），按集记进度 / 统计
// 是对的；缺的是「这些集属于同一部剧」这层结构，于是继续观看 / 视频库里每集各占一张卡。
// 本仓里「一部剧」只有一种持久形态：playlist 合集——媒体服务器单集
// （`mediaServerCollectionOf`）、在线视频源（`AnimeSourceVideoClient`）、IPTV 导入都按
// 剧名落 playlist 合集，库页折叠、继续观看归组、续播的系列上下文、跨端同步全吃它。
// 网页档照同一范式：拿到站点给的整部剧 metadata（Netflix [NetflixTitleMetadata]）时，
// 把库里已有的这部剧各集收进以剧名为自然键的 playlist 合集，不另立一套「剧身份」。
//
// 走 [FushiDatabase.adoptRemoteCollectionMember]（自动路径）：用户删过这个合集 / 把某集
// 移出过都有墓碑，自动收编一律让路，不复活、不接手用户合集；用户没手排过时成员按
// 季 / 集序落槽位。
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/video/netflix_metadata.dart';
import 'package:fushi/src/media/video/url_stream_video.dart'
    show streamVideoBookUid;

/// playlist 合集的类型值（与媒体服务器 / 在线源 / IPTV 同一档）。
const String kWebVideoSeriesCollectionType = 'playlist';

/// 一部剧在合集里的一集：书 id + 合集槽位。
typedef WebVideoSeriesMember = ({String bookUid, int sortIndex});

/// 合集槽位：季序 × 10000 + 集序（与 `mediaServerCollectionOf` 同口径，站点日后补集
/// 不挤动已有集的相对顺序）。
int webVideoSeriesSortIndex(NetflixEpisode episode) =>
    episode.seasonSeq * 10000 + episode.seq;

/// 这份 metadata 对应的合集名；不是剧集（电影 / 没集 / 没剧名）返回 null——电影本来就是
/// 单张卡，不建合集。
String? webVideoSeriesCollectionName(NetflixTitleMetadata meta) {
  final String name = meta.title.trim();
  if (!meta.isShow || meta.episodes.isEmpty || name.isEmpty) return null;
  return name;
}

/// 这部剧全部集在本仓的书 id（与 `ensureWebVideoEpisodeBook` 落书同一身份：规范化
/// 播放页地址 → [streamVideoBookUid]）及槽位，按 metadata 季 / 集序。
List<WebVideoSeriesMember> webVideoSeriesMembers(NetflixTitleMetadata meta) =>
    <WebVideoSeriesMember>[
      for (final NetflixEpisode e in meta.episodes)
        (
          bookUid: streamVideoBookUid(e.watchUrl),
          sortIndex: webVideoSeriesSortIndex(e),
        ),
    ];

/// 把库里已有的这部剧各集收进它的 playlist 合集（没有就建）。只收已落书的集（没看过的集
/// 不凭空造书）；已在合集里的跳过，幂等。返回合集 id；不是剧集、库里一集都没有、或全被
/// 墓碑挡下（用户删过合集 / 移出过这些集）返回 null。
///
/// 同一部剧之前散着的集（本修复前看过的）也在这里一并收编：metadata 一到就按全集 id 查库。
Future<int?> linkWebVideoSeriesEpisodes(
  FushiDatabase db,
  NetflixTitleMetadata meta,
) async {
  final String? name = webVideoSeriesCollectionName(meta);
  if (name == null) return null;
  final List<WebVideoSeriesMember> members = webVideoSeriesMembers(meta);
  final Set<String> uids = <String>{
    for (final WebVideoSeriesMember m in members) m.bookUid,
  };
  final Set<String> inLibrary = <String>{
    for (final VideoBookRow row in await (db.select(
      db.videoBooks,
    )..where((t) => t.bookUid.isIn(uids))).get())
      row.bookUid,
  };
  if (inLibrary.isEmpty) return null;
  final MediaCollectionRow? existing = await db.getMediaCollectionByNaturalKey(
    name,
    kWebVideoSeriesCollectionType,
  );
  final Set<String> already = existing == null
      ? <String>{}
      : await _videoMembersOf(db, existing.id);
  int? collectionId;
  for (final WebVideoSeriesMember m in members) {
    if (!inLibrary.contains(m.bookUid) || already.contains(m.bookUid)) {
      continue;
    }
    final int? id = await db.adoptRemoteCollectionMember(
      name: name,
      collectionType: kWebVideoSeriesCollectionType,
      mediaType: MediaKind.video,
      remoteEntryKey: m.bookUid,
      sortIndex: m.sortIndex,
    );
    collectionId ??= id;
  }
  collectionId ??= existing?.id;
  if (collectionId == null) return null;
  // 只认确实收着本剧集的合集：全被墓碑挡下时，同名的 existing 里可能一集本剧都没有。
  final Set<String> now = await _videoMembersOf(db, collectionId);
  return now.any(inLibrary.contains) ? collectionId : null;
}

Future<Set<String>> _videoMembersOf(FushiDatabase db, int collectionId) async =>
    <String>{
      for (final MediaCollectionItemRow item in await db.getCollectionItems(
        collectionId,
      ))
        if (item.mediaType == MediaKind.video.dbValue) item.entryKey,
    };
