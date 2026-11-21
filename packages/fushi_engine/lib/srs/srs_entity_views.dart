/// 内核 `entity_views` 的视图（native/fushi_fsrs/src/store/gen4/cmd/views.rs 文件头）与它的**唯一一份**解码器：
/// 本机 [SrsDbStore.entityViews] 交出它，远程复习 V2 的主机原样搬它（`{id, tag, v}`，srs_remote_store.dart），
/// 客户端经这里解成物化输入，再交给与本机同一个物化内核（`srsMaterializeNotes` 等）。
///
/// 视图里的身份记录（`d`）与修改记录（`edits`）与本机读命令 `read` 的 `entities` / `edits` 逐字相同（内核测试
/// `cmd/views_tests.rs` 经 C ABI 对拍），所以按视图物化与本机读出来物化得到同一份结果；胜者、按类判定的活着的写入、
/// 信任状态都已在主机内核里算好，客户端不重算。
///
/// 不依赖 Flutter：app 与无头服务端共用。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart'
    show SrsEditItem, SrsEntitySource, srsCanonicalJson;

/// `entity_views` 一次最多点名的 ID 数（内核 `cmd/identity.rs` `LOOKUP_MAX`，与 `canonical_ids` 同一上限）：多了由
/// 调用方分批。
const int kSrsEntityViewsBatchMax = 4096;

/// 一个实体（一个别名类）的视图：[id] 是规范 ID，[tag] 是视图字节的 blake3 前 16 字节（hex，视图一变它必变），
/// [json] 是视图的规范 JSON 文本（原样搬，不再编码）。
class SrsEntityView {
  const SrsEntityView(this.id, this.tag, this.json);

  final String id;
  final String tag;
  final String json;

  @override
  bool operator ==(Object other) =>
      other is SrsEntityView &&
      other.id == id &&
      other.tag == tag &&
      other.json == json;

  @override
  int get hashCode => Object.hash(id, tag, json);

  @override
  String toString() => 'SrsEntityView($id, $tag)';
}

/// 视图 JSON 解开后的对象；不是对象、`id` 与 [view] 的不一致一律 [FormatException]。
Map<String, Object?> _decoded(SrsEntityView view) {
  final Object? decoded = jsonDecode(view.json);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('entity view: not an object');
  }
  if (decoded['id'] != view.id) {
    throw FormatException('entity view: id ${decoded['id']} != ${view.id}');
  }
  return decoded;
}

/// 视图里的修改记录（`[[行 JSON, 服务器时刻 | null], …]`），与本机读 `read edits` 的同一份原文。不合形一律
/// [FormatException]。
List<SrsEditItem> srsEntityViewEdits(SrsEntityView view) =>
    _editsOf(_decoded(view)['edits']);

List<SrsEditItem> _editsOf(Object? edits) {
  if (edits is! List<Object?>) {
    throw const FormatException('entity view: edits is not a list');
  }
  return <SrsEditItem>[
    for (final Object? e in edits)
      if (e case [final String row, final int? serverTime])
        SrsEditItem.stored(Uint8List.fromList(utf8.encode(row)), serverTime)
      else
        throw const FormatException('entity view: bad edit row'),
  ];
}

/// 视图 → 物化输入（身份记录 + 修改记录），与本机 [SrsDbStore] 读 `entities` + `edits` 拼出的那一份逐字相同。没有身份
/// 记录（`d` 为 null：只剩修改记录 / 日志 / 缓存行的实体）→ null，与本机「没有身份记录的 ID 不物化」同口径。不合形一律
/// [FormatException]。
SrsEntitySource? srsEntitySourceOfView(SrsEntityView view) {
  final Map<String, Object?> m = _decoded(view);
  final Object? d = m['d'];
  if (d == null) return null;
  if (d is! Map<String, Object?>) {
    throw const FormatException('entity view: d is not an object');
  }
  return SrsEntitySource(view.id, srsCanonicalJson(d), _editsOf(m['edits']));
}

/// 一批视图的物化输入（跳过没有身份记录的，顺序不变）。
List<SrsEntitySource> srsEntitySourcesOfViews(Iterable<SrsEntityView> views) =>
    <SrsEntitySource>[
      for (final SrsEntityView v in views) ?srsEntitySourceOfView(v),
    ];
