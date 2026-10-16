/// 最小 protobuf 读取器：只够解 Anki 新 schema（collection.anki21b）里的配置 blob
/// 与 `media` 清单（MediaEntries）。只认 wire type 0（varint）/ 1（fixed64）/
/// 2（length-delimited）/ 5（fixed32）；group（3/4）出现即视为损坏。
///
/// 字段号照 rslib proto（anki/notetypes.proto、decks.proto、deck_config.proto、
/// import_export.proto），由使用方按号取值，本文件不认识任何具体消息。
library;

import 'dart:convert';
import 'dart:typed_data';

/// protobuf 数据损坏。
class SrsProtoFormatException implements Exception {
  const SrsProtoFormatException(this.message);

  final String message;

  @override
  String toString() => 'SrsProtoFormatException: $message';
}

/// 一个字段的原始值。varint / fixed 存成 [int]，length-delimited 存成字节。
class SrsProtoValue {
  const SrsProtoValue._(this.wireType, this._int, this._bytes);

  final int wireType;
  final int? _int;
  final Uint8List? _bytes;

  /// varint / fixed32 / fixed64 的原始整数（fixed64 按 64 位有符号读）。
  int get asInt => _int ?? 0;

  /// sint32 / sint64（zigzag）。
  int get asSint {
    final int v = asInt;
    return (v >>> 1) ^ -(v & 1);
  }

  bool get asBool => asInt != 0;

  /// fixed32 作 float。
  double get asFloat {
    final ByteData b = ByteData(4)
      ..setUint32(0, asInt & 0xffffffff, Endian.little);
    return b.getFloat32(0, Endian.little);
  }

  /// fixed64 作 double。
  double get asDouble {
    final ByteData b = ByteData(8)..setInt64(0, asInt, Endian.little);
    return b.getFloat64(0, Endian.little);
  }

  Uint8List get asBytes => _bytes ?? Uint8List(0);

  String get asString => utf8.decode(asBytes, allowMalformed: true);

  SrsProtoMessage get asMessage => SrsProtoMessage.parse(asBytes);
}

/// 一条已解析的消息：字段号 → 按出现顺序的值列表（repeated / packed 都在里面）。
class SrsProtoMessage {
  SrsProtoMessage._(this._fields);

  /// 空消息（字段全缺省）。
  factory SrsProtoMessage.empty() =>
      SrsProtoMessage._(<int, List<SrsProtoValue>>{});

  final Map<int, List<SrsProtoValue>> _fields;

  /// 解析 [bytes]；损坏抛 [SrsProtoFormatException]。
  static SrsProtoMessage parse(Uint8List bytes) {
    final Map<int, List<SrsProtoValue>> out = <int, List<SrsProtoValue>>{};
    int pos = 0;

    int readVarint() {
      int result = 0;
      int shift = 0;
      while (true) {
        if (pos >= bytes.length) {
          throw const SrsProtoFormatException('truncated varint');
        }
        final int b = bytes[pos++];
        if (shift < 64) result |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 70) throw const SrsProtoFormatException('varint too long');
      }
    }

    int readFixed(int n) {
      if (pos + n > bytes.length) {
        throw const SrsProtoFormatException('truncated fixed');
      }
      final ByteData d = ByteData.sublistView(bytes, pos, pos + n);
      pos += n;
      return n == 4
          ? d.getUint32(0, Endian.little)
          : d.getInt64(0, Endian.little);
    }

    while (pos < bytes.length) {
      final int key = readVarint();
      final int field = key >>> 3;
      final int wire = key & 7;
      if (field == 0) throw const SrsProtoFormatException('field number 0');
      final SrsProtoValue v;
      switch (wire) {
        case 0:
          v = SrsProtoValue._(0, readVarint(), null);
        case 1:
          v = SrsProtoValue._(1, readFixed(8), null);
        case 2:
          final int len = readVarint();
          if (len < 0 || pos + len > bytes.length) {
            throw const SrsProtoFormatException('truncated bytes');
          }
          v = SrsProtoValue._(
            2,
            null,
            Uint8List.sublistView(bytes, pos, pos + len),
          );
          pos += len;
        case 5:
          v = SrsProtoValue._(5, readFixed(4), null);
        default:
          throw SrsProtoFormatException('unsupported wire type $wire');
      }
      (out[field] ??= <SrsProtoValue>[]).add(v);
    }
    return SrsProtoMessage._(out);
  }

  bool has(int field) => _fields[field]?.isNotEmpty ?? false;

  /// 标量取最后一次出现（protobuf 语义）。
  SrsProtoValue? _last(int field) {
    final List<SrsProtoValue>? l = _fields[field];
    return l == null || l.isEmpty ? null : l.last;
  }

  List<SrsProtoValue> all(int field) =>
      _fields[field] ?? const <SrsProtoValue>[];

  int intOf(int field, [int fallback = 0]) => _last(field)?.asInt ?? fallback;

  int? optInt(int field) => _last(field)?.asInt;

  bool boolOf(int field) => _last(field)?.asBool ?? false;

  String stringOf(int field) => _last(field)?.asString ?? '';

  double floatOf(int field, [double fallback = 0]) =>
      _last(field)?.asFloat ?? fallback;

  SrsProtoMessage messageOf(int field) =>
      _last(field)?.asMessage ?? SrsProtoMessage.empty();

  List<SrsProtoMessage> messagesOf(int field) => <SrsProtoMessage>[
    for (final SrsProtoValue v in all(field)) v.asMessage,
  ];

  /// repeated float：packed（一个 length-delimited 里连续 fixed32）与非 packed 都认。
  List<double> floatsOf(int field) {
    final List<double> out = <double>[];
    for (final SrsProtoValue v in all(field)) {
      if (v.wireType == 5) {
        out.add(v.asFloat);
      } else if (v.wireType == 2) {
        final Uint8List b = v.asBytes;
        if (b.length % 4 != 0) {
          throw const SrsProtoFormatException('packed float length');
        }
        final ByteData d = ByteData.sublistView(b);
        for (int i = 0; i < b.length; i += 4) {
          out.add(d.getFloat32(i, Endian.little));
        }
      }
    }
    return out;
  }
}
