/// srs.db 的 ID 列编码（v17，native/fushi_fsrs/src/store/ids.rs）。
///
/// 规范小写带连字符的 UUID 文本存成 16 字节 BLOB，别的值原样存 TEXT（无损）。Dart 这边看到的 ID 一律是文本：
/// Drift 的类型化查询经 [srsIdType] 绑定 / 读取；手写 SQL 的 ID 参数写 `srs_id(?)`，结果列直接选 ID 列
/// （桥按声明类型还原成文本），表达式列（`MIN(id)`、`COALESCE(...)`）套 `srs_idt(...)`。
library;

import 'package:drift/drift.dart';

/// ID 列在 SQL 里的声明类型（TEXT 亲和）。
const String kSrsIdDeclType = 'UUIDTEXT';

const String _hex = '0123456789abcdef';

int _nibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  return -1;
}

/// 规范小写带连字符 UUID 文本 → 16 字节；别的文本 null（与 Rust `ids::pack` 相同）。
Uint8List? packSrsId(String s) {
  if (s.length != 36) return null;
  final Uint8List out = Uint8List(16);
  int k = 0;
  int i = 0;
  while (i < 36) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (s.codeUnitAt(i) != 0x2d) return null;
      i++;
      continue;
    }
    final int hi = _nibble(s.codeUnitAt(i));
    final int lo = _nibble(s.codeUnitAt(i + 1));
    if (hi < 0 || lo < 0) return null;
    out[k++] = (hi << 4) | lo;
    i += 2;
  }
  return out;
}

/// 16 字节 → 小写带连字符文本。
String unpackSrsId(Uint8List b) {
  final StringBuffer s = StringBuffer();
  for (int i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) s.write('-');
    s
      ..write(_hex[b[i] >> 4])
      ..write(_hex[b[i] & 15]);
  }
  return s.toString();
}

/// ID 列的 Drift 类型：Dart 值是 ID 文本，存储值是 [packSrsId] 的 BLOB 或原文本。
class SrsIdType implements CustomSqlType<String> {
  const SrsIdType();

  @override
  String mapToSqlLiteral(String dartValue) {
    final Uint8List? b = packSrsId(dartValue);
    if (b == null) return "'${dartValue.replaceAll("'", "''")}'";
    return "x'${b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join()}'";
  }

  @override
  Object mapToSqlParameter(String dartValue) =>
      packSrsId(dartValue) ?? dartValue;

  @override
  String read(Object fromSql) => switch (fromSql) {
    final Uint8List b when b.length == 16 => unpackSrsId(b),
    final String s => s,
    _ => throw ArgumentError.value(fromSql, 'fromSql', 'not an SRS id'),
  };

  @override
  String sqlTypeName(GenerationContext context) => kSrsIdDeclType;
}

/// [SrsIdType] 的实例（表声明与 `Variable` 用）。
const SrsIdType srsIdType = SrsIdType();
