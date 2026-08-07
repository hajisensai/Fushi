/// 合集子篇判据（BUG-1393；用户 2026-08-02：「作品海报只归合集封面，成员条目保持
/// 抽帧/集级剧照，宁可无封面不凑数」）。
///
/// 作品级竖版海报只属于**合集自有封面**（`MediaCollections.coverPath`）；成员数
/// ≥2 的合集里的每一集（子篇）在任何**自动**路径下都不落作品海报——封面保持抽帧
/// 缩略图或集级剧照（`EpisodeScrapeService` 的 TMDB 剧照），两者都没有就保持无
/// 封面，不拿作品海报凑数。单片（独立条目或单成员合集）不受影响。用户在弹窗里
/// 亲手匹配（`applyCandidateToBooks` → userScraped）永远放行，不经此判据。
///
/// ⚠️ 判据返回的不是「要不要跳过」的 bool，而是**归属 collectionId**：闸住子篇
/// 封面只做对了一半，那张海报还得有地方去（用户口径是「归合集封面」而不是「消
/// 失」）。把 collectionId 一并算出来，自动刮削才能把海报改落到容器上；bool 会
/// 把这条信息扔掉，逼调用方再查一次库。
library;

import 'package:fushi_core/fushi_core.dart'
    show MediaCollectionItemRow, MediaKind;

/// 从全库合集成员表算出「合集子篇 → 所属多成员合集 id」的映射：条目属于任一
/// **成员数 ≥2** 的合集即视为子篇。成员数按合集全部成员计、不分媒体种类——混编
/// 合集（视频 + 书）里的视频集同样是某个多成员容器的一员，作品海报同样该落容器
/// 不落成员。
///
/// 一条目跨多个多成员合集时取**最小 collectionId**（与
/// `FushiDatabase.getPrimaryCollectionIdByEntry` 的折叠归属同口径：库网格里该
/// 条目折进 id 最小的合集卡，海报也该落到用户看得见的那张卡上）。
///
/// 纯函数、无 IO、输入序无关；输入取 `FushiDatabase.getAllCollectionItems()`
/// 一次全量（消 N+1，与该查询的注释口径一致）。
Map<String, int> multiMemberCollectionIdByVideoUid(
  List<MediaCollectionItemRow> items,
) {
  final Map<int, int> memberCountByCollection = <int, int>{};
  for (final MediaCollectionItemRow item in items) {
    memberCountByCollection[item.collectionId] =
        (memberCountByCollection[item.collectionId] ?? 0) + 1;
  }
  final Map<String, int> result = <String, int>{};
  for (final MediaCollectionItemRow item in items) {
    if (item.mediaType != MediaKind.video.dbValue) continue;
    if (memberCountByCollection[item.collectionId]! < 2) continue;
    final int? existing = result[item.entryKey];
    if (existing == null || item.collectionId < existing) {
      result[item.entryKey] = item.collectionId;
    }
  }
  return result;
}
