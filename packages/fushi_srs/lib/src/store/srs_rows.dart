/// srs.db 行页的二进制编码，与 native/fushi_fsrs/src/store/rows.rs 逐字节相同。小端：
/// `u32 行数, u32 列数`，然后逐行逐列 `u8 标记`（0 NULL / 1 i64 / 2 f64 / 3 UTF-8 文本 /
/// 4 字节），文本与字节前面是 `u32` 长度。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 一页行：每个值是 `null` / [int] / [double] / [String] / [Uint8List]。
Uint8List srsEncodeRows(int columns, List<List<Object?>> rows) {
  final BytesBuilder out = BytesBuilder(copy: false);
  final ByteData head = ByteData(8)
    ..setUint32(0, rows.length, Endian.little)
    ..setUint32(4, columns, Endian.little);
  out.add(head.buffer.asUint8List());
  final ByteData num8 = ByteData(8);
  final ByteData num4 = ByteData(4);
  for (final List<Object?> row in rows) {
    if (row.length != columns) {
      throw ArgumentError('row has ${row.length} values, expected $columns');
    }
    for (final Object? v in row) {
      switch (v) {
        case null:
          out.addByte(0);
        case final bool b:
          out.addByte(1);
          num8.setInt64(0, b ? 1 : 0, Endian.little);
          out.add(Uint8List.fromList(num8.buffer.asUint8List()));
        case final int i:
          out.addByte(1);
          num8.setInt64(0, i, Endian.little);
          out.add(Uint8List.fromList(num8.buffer.asUint8List()));
        case final double d:
          out.addByte(2);
          num8.setFloat64(0, d, Endian.little);
          out.add(Uint8List.fromList(num8.buffer.asUint8List()));
        case final String s:
          final Uint8List b = utf8.encode(s);
          out.addByte(3);
          num4.setUint32(0, b.length, Endian.little);
          out.add(Uint8List.fromList(num4.buffer.asUint8List()));
          out.add(b);
        case final Uint8List b:
          out.addByte(4);
          num4.setUint32(0, b.length, Endian.little);
          out.add(Uint8List.fromList(num4.buffer.asUint8List()));
          out.add(b);
        default:
          throw ArgumentError('unsupported value type ${v.runtimeType}');
      }
    }
  }
  return out.takeBytes();
}

/// 解出一页：返回 (列数, 行)。越界 / 坏标记抛 [FormatException]。
(int, List<List<Object?>>) srsDecodeRows(Uint8List bytes) {
  final ByteData d = ByteData.sublistView(bytes);
  int at = 0;
  void need(int n) {
    if (at + n > bytes.length) {
      throw const FormatException('truncated srs row page');
    }
  }

  need(8);
  final int nRows = d.getUint32(0, Endian.little);
  final int nCols = d.getUint32(4, Endian.little);
  at = 8;
  final List<List<Object?>> rows = <List<Object?>>[];
  for (int r = 0; r < nRows; r++) {
    final List<Object?> row = List<Object?>.filled(nCols, null);
    for (int c = 0; c < nCols; c++) {
      need(1);
      final int tag = bytes[at++];
      switch (tag) {
        case 0:
          row[c] = null;
        case 1:
          need(8);
          row[c] = d.getInt64(at, Endian.little);
          at += 8;
        case 2:
          need(8);
          row[c] = d.getFloat64(at, Endian.little);
          at += 8;
        case 3 || 4:
          need(4);
          final int n = d.getUint32(at, Endian.little);
          at += 4;
          need(n);
          final Uint8List slice = Uint8List.sublistView(bytes, at, at + n);
          row[c] = tag == 3 ? utf8.decode(slice) : Uint8List.fromList(slice);
          at += n;
        default:
          throw FormatException('bad srs row tag $tag');
      }
    }
    rows.add(row);
  }
  if (at != bytes.length) {
    throw const FormatException('trailing bytes in srs row page');
  }
  return (nCols, rows);
}
