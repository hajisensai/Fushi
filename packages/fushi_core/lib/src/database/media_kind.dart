/// 合集 / 书架值域的媒体种类枚举（P5 统一地基）。
///
/// **只覆盖「合集/书架 mediaType」值域**：`MediaCollectionItems.mediaType` /
/// `ShelfEntries.mediaType` / `BookTagMembershipTombstones.mediaType` /
/// `CollectionMemberTombstones.mediaType`。定义在 hibiki_core 是因为它是
/// **schema 值域的一部分**（同 activity_event_types.dart 的理由）。
///
/// ⚠️ 与本仓其它 6 个字符串值域**互不通用**，混编即数据事故（跨域换算走
/// media_kind_mappings.dart 的显式映射表，不得手写）：
/// - 活动事件域（`ActivityMediaKind` / `kActivityMediaBook='book'` 等，
///   activity_event_types.dart）——注意 `book` ≠ `epub`；
/// - 来源库域（`MediaSources.mediaKind`）；
/// - Profile 绑定域（`ProfileMediaKind`，profile_media_kind.dart）——注意
///   `srtbook` ≠ `srt`；
/// - 删除墓碑域（`SyncTombstoneKind`，sync_tombstone_kind.dart，
///   `SyncDeletionTombstones.mediaType`）；
/// - 统计来源域（`StatSourceKind` / `kStatSourceVideo` 等，
///   stat_source_kind.dart）；
/// - 文件扩展名 / MIME / Anki tag。
library;

/// 合集 / 书架成员的媒体种类。
///
/// Drift 列本身保持 `TEXT`（不引入 TypeConverter）：
/// - `MediaCollectionItems.mediaType` 有 `''` 哨兵
///   （`FushiDatabase.collectionTombstoneSentinel`）；
/// - 同步引擎必须原样透传对端未来新增的未知种类。
/// 因此边界上用 [tryParse] 显式解析、用 [dbValue] 显式落库。
enum MediaKind {
  /// EPUB 书。
  epub('epub'),

  /// 字幕书（SRT/字幕文本导入的书）。
  srt('srt'),

  /// 视频。
  video('video'),

  /// galgame 游戏。
  game('game');

  const MediaKind(this.dbValue);

  /// 落 DB / 上 wire 的字符串。永不改变（Never break userspace）。
  ///
  /// 纪律：任何持久化/拼键场景**只用本字段**，绝不用 `.name`——
  /// 二者当前恰好相同是巧合，不是契约。
  final String dbValue;

  /// 把 DB / wire 字符串解析为枚举。
  ///
  /// `null`、`''` 哨兵（合集墓碑占位）与未知种类（对端未来新增）一律返回
  /// `null`，**绝不抛异常**——同步引擎须容忍未知值。
  static MediaKind? tryParse(String? raw) {
    for (final MediaKind kind in MediaKind.values) {
      if (kind.dbValue == raw) {
        return kind;
      }
    }
    return null;
  }

  /// 折叠归属 / 组内序 map 的复合键 `'<kind>|<entryKey>'` 唯一真相源。
  ///
  /// 生成串必须与历史手写插值逐字节一致（`MediaCollections.coverSource`
  /// 有落库点依赖此格式）。
  String compositeKey(String entryKey) => '$dbValue|$entryKey';
}
