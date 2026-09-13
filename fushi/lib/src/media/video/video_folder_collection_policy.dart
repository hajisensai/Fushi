import 'package:fushi_core/fushi_core.dart';

/// 文件夹模式优先展示其目录合集；切回作品模式后不再强制折进旧目录合集。
/// 一次性导入删除临时来源后仍保留目录组织。
Map<String, int> applyVideoFolderCollectionPolicy({
  required Map<String, int> primary,
  required List<MediaCollectionRow> collections,
  required List<MediaCollectionItemRow> items,
  required List<VideoBookRow> books,
  required List<MediaSourceRow> sources,
}) {
  final Map<String, int> result = Map<String, int>.of(primary);
  final Map<int, MediaCollectionRow> byId = <int, MediaCollectionRow>{
    for (final MediaCollectionRow collection in collections)
      collection.id: collection,
  };
  final Map<int, String> modes = <int, String>{
    for (final MediaSourceRow source in sources)
      source.id: source.videoGroupingMode,
  };
  final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
    for (final VideoBookRow book in books) book.bookUid: book,
  };
  final Set<String> folderMembers = <String>{};
  for (final MediaCollectionItemRow item in items) {
    if (item.mediaType != MediaKind.video.dbValue ||
        byId[item.collectionId]?.sourceFolderPath == null) {
      continue;
    }
    final VideoBookRow? book = byUid[item.entryKey];
    if (book == null) continue;
    final String key = MediaKind.video.compositeKey(item.entryKey);
    final String mode =
        modes[book.sourceId] ?? book.videoGroupingMode ?? 'series';
    if (mode == 'folder') {
      if (folderMembers.add(key)) result[key] = item.collectionId;
    } else if (result[key] == item.collectionId) {
      result.remove(key);
    }
  }
  // 保留作品模式下原有普通合集/手动合集归属。
  for (final MediaCollectionItemRow item in items) {
    if (item.mediaType != MediaKind.video.dbValue ||
        byId[item.collectionId]?.sourceFolderPath != null) {
      continue;
    }
    result.putIfAbsent(
      MediaKind.video.compositeKey(item.entryKey),
      () => item.collectionId,
    );
  }
  return result;
}
