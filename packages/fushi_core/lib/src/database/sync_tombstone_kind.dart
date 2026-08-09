/// sync 删除墓碑值域（sync_deletion_tombstones 表的 `media_type` 列）。
///
/// ⚠️ 与合集/书架域（`MediaKind`）**互不通用**：`book` ≠ `epub`（本域的
/// `book` 指「书资产」整体，itemKey=bookKey）。表注释只列了 4 个资产种类，
/// 但收藏词 / 收藏句的删除传播墓碑也存进同一列（写入点
/// `FushiDatabase.removeFavoriteWord` / `FavoriteSentenceRepository`），
/// 故本枚举含全部 7 个已落库值。
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
  /// 行，它的跨设备身份就是 `uid`（见 `AppModelLibraryHostService` 的身份键规则，接收端
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
  favoritesentence('favoritesentence');

  const SyncTombstoneKind(this.dbValue);

  /// 落 DB 的字符串。永不改变；持久化场景只用本字段，绝不用 `.name`。
  final String dbValue;

  /// 严格解析：精确匹配七个落库值之一，未知 / null → null，绝不抛
  /// ——同步引擎须容忍对端未来新增的未知种类原样透传。
  static SyncTombstoneKind? tryParse(String? raw) {
    for (final SyncTombstoneKind kind in SyncTombstoneKind.values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}
