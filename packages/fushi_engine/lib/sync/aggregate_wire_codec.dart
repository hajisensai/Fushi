import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/sync/aggregate_snapshot.dart';

/// 互联聚合端点（`/api/library/aggregate`）报文体的编解码：UTF-8 JSON 字节 ⇄
/// [AggregateSnapshot]。
///
/// 报文体是**整份**统计 + 收藏 + 浏览历史快照，编解码对它是 O(N) 的纯计算（UTF-8
/// 转码 + JSON 词法 / 序列化 + 逐行 fromJson）。HBK-AUDIT-028：这些步骤以前跑在
/// 调用方 isolate（app 里即 UI isolate）——client 的 GET 解码 / PUT 编码、host 的
/// PUT 解码 / GET 编码都是。传输层因此只搬**原始字节**，编解码一律经
/// `AggregatePureRunner` 在后台 isolate 里做（见 `AggregateSyncService.
/// decodeWireSnapshotOff` / `encodeWireSnapshotOff`），本文件只放纯函数。
final Converter<List<int>, Object?> _utf8JsonDecoder = utf8.decoder.fuse(
  json.decoder,
);

/// 报文体 → JSON 值。非法 UTF-8 / 非法 JSON 抛 [FormatException]（不吞：client 侧
/// 进同步错误，host 侧回 400）。
Object? decodeAggregateWireJson(Uint8List body) =>
    _utf8JsonDecoder.convert(body);

/// 报文体 → 快照。顶层不是 JSON object 时返回 null（由调用方决定：host 回 400，
/// client 当空快照折叠，与 [AggregateSnapshot.fromJson] 的降级同律）。
AggregateSnapshot? decodeAggregateWireSnapshot(Uint8List body) {
  final Object? decoded = decodeAggregateWireJson(body);
  if (decoded is! Map) return null;
  return AggregateSnapshot.fromJson(decoded);
}

/// JSON 值 → 报文体（UTF-8 JSON 字节，一步编码，不经中间 String）。
Uint8List encodeAggregateWireJson(Object? json) {
  final List<int> bytes = JsonUtf8Encoder().convert(json);
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}
