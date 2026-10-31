/// 内核列式结果（native/fushi_fsrs/src/store/bulk.rs `Columns`）的解码：在同一块字节上建类型化视图，不拷贝。
///
/// 一块是一张表：`"FCL1" u32 行数 u32 列数 u32 0`，再逐列 `u32 名字长 + 名字（补齐到 8）`、`u32 类型 u32 0`、
/// 数据（补齐到 8）。类型：1 i64、2 f64、3 i64?、4 f64?（行数个有值标志 + 数据）、5 str（u64 字节数、行数 + 1 个
/// u32 偏移、UTF-8）、6 str?（标志 + 同 5）。字符串按需解码（[SrsStringColumn.operator []]）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 一张列式表。[bytes] 必须从缓冲区起点 8 字节对齐（`TransferableTypedData.materialize()` 的结果与新分配的
/// `Uint8List` 都是）。
final class SrsColumns {
  SrsColumns._(this.rows, this._cols);

  factory SrsColumns.decode(Uint8List bytes) {
    if (bytes.offsetInBytes % 8 != 0) bytes = Uint8List.fromList(bytes);
    final ByteData d = ByteData.sublistView(bytes);
    if (bytes.length < 16 ||
        bytes[0] != 0x46 ||
        bytes[1] != 0x43 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x31) {
      throw const FormatException('SrsColumns: bad magic');
    }
    final int rows = d.getUint32(4, Endian.little);
    final int n = d.getUint32(8, Endian.little);
    int at = 16;
    int pad(int x) => (x + 7) & ~7;
    final ByteBuffer buf = bytes.buffer;
    final int base = bytes.offsetInBytes;
    final Map<String, Object> cols = <String, Object>{};
    for (int c = 0; c < n; c++) {
      final int nameLen = d.getUint32(at, Endian.little);
      final String name = utf8.decode(
        Uint8List.sublistView(bytes, at + 4, at + 4 + nameLen),
      );
      at = pad(at + 4 + nameLen);
      final int kind = d.getUint32(at, Endian.little);
      at += 8;
      Uint8List? valid;
      if (kind == 3 || kind == 4 || kind == 6) {
        valid = Uint8List.sublistView(bytes, at, at + rows);
        at = pad(at + rows);
      }
      switch (kind) {
        case 1:
        case 3:
          cols[name] = SrsIntColumn._(buf.asInt64List(base + at, rows), valid);
          at += rows * 8;
        case 2:
        case 4:
          cols[name] = SrsDoubleColumn._(
            buf.asFloat64List(base + at, rows),
            valid,
          );
          at += rows * 8;
        case 5:
        case 6:
          final int total = d.getUint64(at, Endian.little);
          at += 8;
          final Uint32List offsets = buf.asUint32List(base + at, rows + 1);
          at = pad(at + (rows + 1) * 4);
          final Uint8List text = Uint8List.sublistView(bytes, at, at + total);
          at = pad(at + total);
          cols[name] = SrsStringColumn._(text, offsets, valid);
        default:
          throw FormatException('SrsColumns: unknown column kind $kind');
      }
    }
    return SrsColumns._(rows, cols);
  }

  final int rows;
  final Map<String, Object> _cols;

  T _col<T>(String name) {
    final Object? c = _cols[name];
    if (c is! T) throw StateError('SrsColumns: no $T column "$name"');
    return c;
  }

  bool has(String name) => _cols.containsKey(name);
  SrsIntColumn ints(String name) => _col<SrsIntColumn>(name);
  SrsDoubleColumn doubles(String name) => _col<SrsDoubleColumn>(name);
  SrsStringColumn strings(String name) => _col<SrsStringColumn>(name);
}

/// 整数列（可空列的空值读成 null）。
final class SrsIntColumn {
  SrsIntColumn._(this.values, this._valid);

  /// 原始值（空值处为 0）。
  final Int64List values;
  final Uint8List? _valid;

  int operator [](int i) => values[i];
  int? at(int i) => (_valid == null || _valid[i] != 0) ? values[i] : null;
  bool flag(int i) => values[i] != 0;
}

/// 浮点列。
final class SrsDoubleColumn {
  SrsDoubleColumn._(this.values, this._valid);

  final Float64List values;
  final Uint8List? _valid;

  double operator [](int i) => values[i];
  double? at(int i) => (_valid == null || _valid[i] != 0) ? values[i] : null;
}

/// 字符串列：按行解码（ASCII 走快路径）。
final class SrsStringColumn {
  SrsStringColumn._(this._text, this._offsets, this._valid);

  final Uint8List _text;
  final Uint32List _offsets;
  final Uint8List? _valid;

  int get length => _offsets.length - 1;

  String operator [](int i) {
    final int s = _offsets[i];
    final int e = _offsets[i + 1];
    bool ascii = true;
    for (int k = s; k < e; k++) {
      if (_text[k] >= 0x80) {
        ascii = false;
        break;
      }
    }
    return ascii
        ? String.fromCharCodes(_text, s, e)
        : utf8.decode(Uint8List.sublistView(_text, s, e));
  }

  String? at(int i) => (_valid == null || _valid[i] != 0) ? this[i] : null;

  /// 全部行（空值为 null）。
  List<String?> toNullableList() => <String?>[
    for (int i = 0; i < length; i++) at(i),
  ];

  /// 全部行（空值为空串）。
  List<String> toList() => <String>[for (int i = 0; i < length; i++) this[i]];
}
