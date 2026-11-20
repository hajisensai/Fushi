/// 视频播放倍速记忆的偏好键（video-s2-2）。
///
/// 与音量记忆（`video_volume_pref.dart`）同一口径：作为播放列表合集某一集打开时
/// （`playlistCollectionId` 非空）记在**系列级**键上，全系列共享；单视频 / 原盘标题 /
/// 远端条目仍按本条目记。
///
/// 统一合集 Phase 3 把每集拆成独立 VideoBooks 行之后，`video_speed_<bookUid>` 实际变成
/// 「每集一个倍速」：本地合集换集 / 连播读的是下一集自己的键（多半回到 1.0），而远端
/// 原地换集沿用当前倍速——同一个「系列」两边行为不一致。系列键是新增键，不改冻结的
/// 旧键名；读取时系列键缺省回退本集旧键，迁移前已存的值继续生效。
library;

/// 单条目的倍速键。存量键名，冻结不改。
String videoSpeedPrefKey(String bookUid) => 'video_speed_$bookUid';

/// 播放列表合集（系列）的倍速键。
String videoSeriesSpeedPrefKey(int collectionId) =>
    'video_speed_collection_$collectionId';

/// 用户改倍速时写入的键：在合集里写系列键，否则写本条目键。
String videoSpeedWriteKey({required String bookUid, int? collectionId}) =>
    collectionId == null
    ? videoSpeedPrefKey(bookUid)
    : videoSeriesSpeedPrefKey(collectionId);

/// 开片读倍速的查找顺序：系列键优先，回退本条目键（兼容系列键出现前各集已存的值）。
List<String> videoSpeedReadKeys({required String bookUid, int? collectionId}) =>
    <String>[
      if (collectionId != null) videoSeriesSpeedPrefKey(collectionId),
      videoSpeedPrefKey(bookUid),
    ];
