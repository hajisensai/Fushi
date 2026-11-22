import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';

/// 合集分栏的**唯一读取入口**：给一批成员的文件名派生键，批量读手动分栏与手动
/// 季集指定，合成生效分栏（优先级见 [resolveCollectionSection]，拍板台 iR6ccUys9H）。
///
/// 合集详情页季 tab、播放器剧集面板、「为合集获取字幕」分季、tracking 多季判定都
/// 走这里——同一个文件在哪一栏，各处口径一致。两次批量查询，不逐成员往返。
///
/// [derivedKeyByUid]：`book_uid → 文件名派生键`（调用方按各自口径派生：详情页 /
/// tracking 用 `videoPath`，字幕面板路径解不出再退标题）。远端成员（本机没有
/// `video_books` 行）不要放进来，它们只有派生键。
Future<Map<String, CollectionSectionResolution>> loadCollectionSections(
  FushiDatabase db,
  Map<String, String> derivedKeyByUid,
) async {
  if (derivedKeyByUid.isEmpty) {
    return const <String, CollectionSectionResolution>{};
  }
  final Iterable<String> uids = derivedKeyByUid.keys;
  final Map<String, String> manual = await db
      .getVideoCollectionSectionOverrides(uids);
  final Map<String, VideoEpisodeBindingOverrideRow> pins = await db
      .getVideoEpisodeBindingOverrides(uids);
  return <String, CollectionSectionResolution>{
    for (final MapEntry<String, String> entry in derivedKeyByUid.entries)
      entry.key: resolveCollectionSection(
        derivedKey: entry.value,
        manualKey: manual[entry.key],
        pinnedSeason: pins[entry.key]?.seasonNumber,
      ),
  };
}

/// [loadCollectionSections] 的只要键版本：`book_uid → 生效分栏键`，派生键按
/// `videoPath`（[collectionGroupKeyForFilename]）。
Future<Map<String, String>> loadCollectionGroupKeysForVideos(
  FushiDatabase db,
  Iterable<VideoBookRow> videos,
) async {
  final Map<String, CollectionSectionResolution> resolved =
      await loadCollectionSections(db, <String, String>{
        for (final VideoBookRow video in videos)
          video.bookUid: collectionGroupKeyForFilename(video.videoPath),
      });
  return <String, String>{
    for (final MapEntry<String, CollectionSectionResolution> entry
        in resolved.entries)
      entry.key: entry.value.groupKey,
  };
}
