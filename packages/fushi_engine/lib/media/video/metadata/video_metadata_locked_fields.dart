/// 作品级字段锁（schema v99，对标 Jellyfin `LockedFields`）。
///
/// 用户手改过的字段进锁集合，之后任何一次刮削都保留旧值——不是「刮不到才保留」，
/// 而是「刮到了也不写」。存储形态是 `video_metadata_works.locked_fields` 里的
/// 逗号分隔字段名，解析在 [parseLockedFields]、编码在 [encodeLockedFields]。
///
/// 值域故意留成**前向兼容**：解析时不认识的名字静默丢掉，新版本新增的锁在旧版本
/// 里只是不生效，而不会让整行资料解析失败。
library;

/// 可锁字段。名字即持久化 wire 值，**不得改名**（改名 = 存量锁静默失效）。
enum VideoMetadataLockableField {
  title,
  originalTitle,
  overview,
  tagline,
  genres,
  studios,
  rating,
  cover,
  backdrop,
}

const Map<String, VideoMetadataLockableField> _byName =
    <String, VideoMetadataLockableField>{
  'title': VideoMetadataLockableField.title,
  'originalTitle': VideoMetadataLockableField.originalTitle,
  'overview': VideoMetadataLockableField.overview,
  'tagline': VideoMetadataLockableField.tagline,
  'genres': VideoMetadataLockableField.genres,
  'studios': VideoMetadataLockableField.studios,
  'rating': VideoMetadataLockableField.rating,
  'cover': VideoMetadataLockableField.cover,
  'backdrop': VideoMetadataLockableField.backdrop,
};

/// 解析 `locked_fields` 列。NULL / 空 / 全是未知值都返回空集合（= 无锁）。
Set<VideoMetadataLockableField> parseLockedFields(String? raw) {
  if (raw == null) return <VideoMetadataLockableField>{};
  final Set<VideoMetadataLockableField> out = <VideoMetadataLockableField>{};
  for (final String part in raw.split(',')) {
    final VideoMetadataLockableField? field = _byName[part.trim()];
    if (field != null) out.add(field);
  }
  return out;
}

/// 编码回 `locked_fields` 列。空集合返回 `null`，让列回到「无锁」的规范形态，
/// 而不是留一个空串（两种「无锁」形态会让守卫和 UI 都要写特例）。
String? encodeLockedFields(Set<VideoMetadataLockableField> fields) {
  if (fields.isEmpty) return null;
  // 按枚举声明序输出，保证同一集合永远编码成同一个字符串（可比较、可 diff）。
  return <String>[
    for (final VideoMetadataLockableField field
        in VideoMetadataLockableField.values)
      if (fields.contains(field)) field.name,
  ].join(',');
}
