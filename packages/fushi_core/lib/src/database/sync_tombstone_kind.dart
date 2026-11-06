/// sync 删除墓碑值域（sync_deletion_tombstones 表的 `media_type` 列）。
///
/// ⚠️ 与合集/书架域（`MediaKind`）**互不通用**：`book` ≠ `epub`（本域的
/// `book` 指「书资产」整体，itemKey=bookKey）。表注释只列了 4 个资产种类，
/// 但收藏词 / 收藏句的删除传播墓碑也存进同一列（写入点
/// `FushiDatabase.removeFavoriteWord` / `FavoriteSentenceRepository`），
/// 故本枚举含全部已落库值（v128 起另含内置浏览器的历史 / 书签两种，v130 起加音乐曲目）。
library;

/// sync 删除墓碑的资产种类（命名统一 Phase 3.4，模式照 `SentenceSourceKind` /
/// `MediaKind`）。落库仍存原字符串（字节不变），边界上用 [tryParse] 显式解析、
/// 用 [dbValue] 显式落库。
enum SyncTombstoneKind {
  /// 书（EPUB；itemKey=bookKey）。
  book('book'),

  /// 有声书（itemKey=bookKey，与其 epub 共享）。
  audiobook('audiobook'),

  /// 纯字幕书 / standalone SRT（itemKey=srt_books.uid）。
  ///
  /// **只对 standalone 行使用**：这类书 `book_key` 恒空、无 EpubBooks 行、无 Audiobooks
  /// 行，它的跨设备身份就是 `uid`（见 `LocalLibraryHostService` 的身份键规则，接收端
  /// 导包逐字保留 uid）。srt-backed 的字幕书（有配对 EPUB、`book_key` 非空）身份是
  /// bookKey，墓碑走 [book] 种类——两者互斥，同一资产绝不会产生两条墓碑。
  srtbook('srtbook'),

  /// 视频（itemKey=bookUid）。
  video('video'),

  /// 本地音频源（itemKey=displayName）。
  localaudio('localaudio'),

  /// 收藏词（itemKey=NUL 连接的 (expression, reading, sourceType) 键）。
  favoriteword('favoriteword'),

  /// 收藏句（itemKey=内容键，见 `FavoriteSentenceRepository.itemKeyOf` /
  /// `kFavoriteSentenceTombstoneType`）。
  favoritesentence('favoritesentence'),

  /// 内置浏览器历史（v128）。itemKey = url（逐条删除），或区间墓碑
  /// `~clear:<since>`（「清除浏览数据」，见 `webHistoryClearTombstoneKey`）。
  /// 只经聚合快照传播（[propagatesViaAggregateSnapshotOnly]）。
  webhistory('webhistory'),

  /// 内置浏览器书签 / 书签文件夹（v128；itemKey = web_browser_bookmarks.uid）。
  /// 删文件夹时每个后代各写一条。只经聚合快照传播。
  webbookmark('webbookmark'),

  /// 音乐曲目（itemKey=music_tracks.track_uid，内容派生、跨设备稳定；v130 起）。
  music('music');

  const SyncTombstoneKind(this.dbValue);

  /// 只经聚合快照（AggregateSnapshot）跨端传播、**不**发布成云端 `__tombstones__`
  /// 逐条标记、也不进互联 host 的删除确认清单的种类。浏览器历史 / 书签的删除没有
  /// 「其他设备已删除，要不要删」的确认语义（快照合并直接仲裁），且一次清除可能产生
  /// 大量条目——逐条标记文件会把云端目录撑爆。
  bool get propagatesViaAggregateSnapshotOnly =>
      this == SyncTombstoneKind.webhistory ||
      this == SyncTombstoneKind.webbookmark;

  /// 落 DB 的字符串。永不改变；持久化场景只用本字段，绝不用 `.name`。
  final String dbValue;

  /// 严格解析：精确匹配已知落库值之一，未知 / null → null，绝不抛
  /// ——同步引擎须容忍对端未来新增的未知种类原样透传。
  static SyncTombstoneKind? tryParse(String? raw) {
    for (final SyncTombstoneKind kind in SyncTombstoneKind.values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}

/// 书墓碑对应的云盘书文件夹处置结论（`sync_deletion_tombstones.cloud_folder_state`，
/// v142）。落库存 [dbValue]；未知值按 [pending] 读（宁可继续藏远端占位卡，也不把
/// 没核实过的残留放出来）。
enum TombstoneCloudFolderState {
  /// 未处置：文件夹可能还在云盘上（v142 之前的墓碑一律是这个状态）。
  pending(0),

  /// 云通道 / 书架「同时从远端删除」已删掉这本书的云盘文件夹。
  deleted(1),

  /// 处置时核实：云盘同步根下没有这个文件夹（这本书从没上传过），无可删。
  absent(2);

  const TombstoneCloudFolderState(this.dbValue);

  /// 落库整数值。
  final int dbValue;

  /// 解析落库值；未知值 → [pending]。
  static TombstoneCloudFolderState fromDb(int value) {
    for (final TombstoneCloudFolderState s in values) {
      if (s.dbValue == value) return s;
    }
    return pending;
  }

  /// 文件夹已处置（删掉或本就没有）：此后云盘上同名文件夹只可能是新上传的。
  bool get resolved => this != pending;
}
