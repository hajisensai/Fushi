/// 合集子篇判据（用户 2026-08-02：「刮削的时候，子篇会刮削成和合集封面一样竖的
/// 那种。取消这个设定」）。
///
/// 作品级竖版海报只属于**合集自有封面**（`MediaCollections.coverPath`）；成员数
/// ≥2 的合集里的每一集（子篇）在任何**自动**路径下都不落作品海报——封面保持抽帧
/// 缩略图或集级剧照（`EpisodeScrapeService` 的 TMDB 剧照），两者都没有就保持无
/// 封面，不拿作品海报凑数。单片（独立条目或单成员合集）不受影响。用户在弹窗里
/// 亲手匹配（`applyCandidateToBooks` → userScraped）永远放行，不经此判据。
library;

import 'package:hibiki_core/hibiki_core.dart'
    show MediaCollectionItemRow, MediaKind;

/// 从全库合集成员表算出「合集子篇」视频 uid 集合：条目属于任一**成员数 ≥2** 的
/// 合集即视为子篇。成员数按合集全部成员计、不分媒体种类——混编合集（视频 + 书）
/// 里的视频集同样是某个多成员容器的一员，作品海报同样该落容器不落成员。
///
/// 纯函数、无 IO、输入序无关；输入取 `HibikiDatabase.getAllCollectionItems()`
/// 一次全量（消 N+1，与该查询的注释口径一致）。
Set<String> videoUidsInMultiMemberCollections(
  List<MediaCollectionItemRow> items,
) {
  final Map<int, int> memberCountByCollection = <int, int>{};
  for (final MediaCollectionItemRow item in items) {
    memberCountByCollection[item.collectionId] =
        (memberCountByCollection[item.collectionId] ?? 0) + 1;
  }
  return <String>{
    for (final MediaCollectionItemRow item in items)
      if (item.mediaType == MediaKind.video.dbValue &&
          memberCountByCollection[item.collectionId]! >= 2)
        item.entryKey,
  };
}
