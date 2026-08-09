/// 统一媒体身份值对象（命名统一 Phase 3.3）。
///
/// 事实上的统一媒体身份是 `(MediaKind, entryKey)` 二元组，此前被独立定义了
/// 3 次（`ShelfEntryRef` / `CollectionOrderingItem` / `CollectionManifestMember`），
/// 字段等价、互不复用。本类是该二元组的唯一真相源：上述类型改为持有 / 委托
/// [MediaRef]，各自对外 API 与持久化形态逐字节不变。
library;

import 'media_kind.dart';

/// 一个媒体条目的稳定身份 `(kind, entryKey)`。
///
/// - [kind]：合集 / 书架值域的媒体种类（落库 / 上 wire 用 [dbMediaType]）；
/// - [entryKey]：条目稳定身份——epub=bookKey / srt=uid / video=bookUid /
///   game=galgames.id。
///
/// 值语义：`==` / [hashCode] 按二元组逐字段比较（与历史 `ShelfEntryRef` 的
/// 实现同构）。序列化：落库 mediaType 串走 [dbMediaType]（= [MediaKind.dbValue]，
/// 绝不用 `.name`），折叠归属 / 组内序 map 的复合键走 [compositeKey]
/// （委托 [MediaKind.compositeKey]，逐字节同历史手写插值）。
class MediaRef {
  const MediaRef({required this.kind, required this.entryKey});

  /// 媒体种类。
  final MediaKind kind;

  /// 条目稳定身份（epub=bookKey / srt=uid / video=bookUid / game=galgames.id）。
  final String entryKey;

  /// 落 DB / 上 wire 的 mediaType 串（= [MediaKind.dbValue]）。
  String get dbMediaType => kind.dbValue;

  /// 复合键 `'<kind>|<entryKey>'`（委托 [MediaKind.compositeKey]）。
  String get compositeKey => kind.compositeKey(entryKey);

  /// 把 DB / wire 的 `(mediaType, entryKey)` 串对解析为 [MediaRef]。
  ///
  /// 未知 / 空种类（含合集墓碑 `''` 哨兵）或空 entryKey 一律返回 `null`，
  /// **绝不抛异常**——同步引擎须容忍未知值原样透传（此时调用方保留裸串）。
  static MediaRef? tryParse(String? mediaType, String? entryKey) {
    final MediaKind? kind = MediaKind.tryParse(mediaType);
    if (kind == null || entryKey == null || entryKey.isEmpty) return null;
    return MediaRef(kind: kind, entryKey: entryKey);
  }

  @override
  bool operator ==(Object other) =>
      other is MediaRef && other.kind == kind && other.entryKey == entryKey;

  @override
  int get hashCode => Object.hash(kind, entryKey);

  @override
  String toString() => 'MediaRef($kind, $entryKey)';
}
