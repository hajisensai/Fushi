/// 视频播放音量记忆的偏好键（TODO-451 / cehHSgF04K）。
///
/// 音量按「作品」记：作为播放列表合集某一集打开时（`playlistCollectionId` 非空）
/// 记在**系列级**键上，全系列共享——换集、自动连播、从书架直接进任一集读到的都是
/// 同一个值；单视频（无合集）仍按本条目记。
///
/// 统一合集 Phase 3 把每集拆成独立 VideoBooks 行之后，原来的 `video_volume_<bookUid>`
/// 实际变成了「每集一个音量」：连播到下一集音量回到 100 / 回到那集上次的值（用户报
/// 「音量设置没有跟随系列」）。系列键是新增键，不改冻结的旧键名；读取时系列键缺省
/// 回退本集旧键，迁移前已存的值继续生效。
library;

/// 单条目（单视频 / 原盘标题 / 远端条目）的音量键。存量键名，冻结不改。
String videoVolumePrefKey(String bookUid) => 'video_volume_$bookUid';

/// 播放列表合集（系列）的音量键。
String videoSeriesVolumePrefKey(int collectionId) =>
    'video_volume_collection_$collectionId';

/// 用户改音量时写入的键：在合集里写系列键，否则写本条目键。
String videoVolumeWriteKey({required String bookUid, int? collectionId}) =>
    collectionId == null
    ? videoVolumePrefKey(bookUid)
    : videoSeriesVolumePrefKey(collectionId);

/// 开片读音量的查找顺序：系列键优先，回退本条目键（兼容系列键出现前各集已存的值）。
List<String> videoVolumeReadKeys({
  required String bookUid,
  int? collectionId,
}) => <String>[
  if (collectionId != null) videoSeriesVolumePrefKey(collectionId),
  videoVolumePrefKey(bookUid),
];
