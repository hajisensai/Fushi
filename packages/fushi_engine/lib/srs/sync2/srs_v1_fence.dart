/// 协议 1 旧根 `v2/meta.json` 上的围栏（2026-10-30 格式断代立的，字节冻结）：「[kSrsV1FenceMagic] + JSON」。协议 1 的
/// 版本（develop@d407ae22ca）握手 `jsonDecode` 失败、报 `meta.json unavailable`，整轮在写任何东西之前停下；本版本认它，
/// 不把围栏当成协议 1 的集合。
///
/// 只有协议 1 旧根的位置新代明确拒绝（D21 偏离定案，内核 `gen4/oldroot.rs`），协议 1 位置的一次性迁移（以前的
/// `srs_location_migration.dart`）已删；这里只剩判围栏与新集合立围栏要用的那几样（`srsSync4LocationRoot`）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 围栏 meta 开头的魔数：不是合法 JSON 的开头，旧版本解析失败；新版本认它、读后面的 JSON。
const String kSrsV1FenceMagic = 'FUSHI-SRS-MOVED-TO-V3\n';

/// 围栏 JSON 里的字段：数据挪到了哪个根。
const String kSrsV1MovedToKey = 'movedTo';

/// 围栏 meta 的字节：[kSrsV1FenceMagic] + JSON。
Uint8List srsEncodeV1Fence(Map<String, Object?> meta) =>
    Uint8List.fromList(utf8.encode('$kSrsV1FenceMagic${jsonEncode(meta)}'));

/// [bytes] 是围栏就交回它的 JSON（JSON 部分坏了交回空表），不是围栏为 null。
Map<String, Object?>? srsDecodeV1Fence(Uint8List bytes) {
  final List<int> magic = utf8.encode(kSrsV1FenceMagic);
  if (bytes.length < magic.length) return null;
  for (int i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return null;
  }
  try {
    final Object? j = jsonDecode(utf8.decode(bytes.sublist(magic.length)));
    return j is Map ? j.cast<String, Object?>() : <String, Object?>{};
  } on FormatException {
    return <String, Object?>{};
  }
}
