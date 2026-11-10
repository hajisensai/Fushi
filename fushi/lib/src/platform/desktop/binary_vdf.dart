import 'dart:convert';
import 'dart:typed_data';

/// Steam's binary KeyValues format, as used by `userdata/<id>/config/
/// shortcuts.vdf` (the non-Steam games in the library).
///
/// Each entry is a type byte, a NUL-terminated UTF-8 key and a value:
///   0x00 map (entries until 0x08), 0x01 string (NUL-terminated UTF-8),
///   0x02 int32, 0x03 float32, 0x07 uint64 (all little endian).
/// 0x08 ends a map; the file is one root map.
///
/// Parsing keeps every entry in order and every value's exact bytes, so an
/// unchanged file serializes back byte for byte. Unknown types throw
/// [FormatException]: a file this code cannot fully read is never rewritten.
class VdfMap {
  VdfMap([List<VdfEntry>? entries]) : entries = entries ?? <VdfEntry>[];

  final List<VdfEntry> entries;

  /// First value under [key], compared case-insensitively (Steam has written
  /// both `appname` and `AppName` over the years).
  Object? operator [](String key) {
    final String lower = key.toLowerCase();
    for (final VdfEntry entry in entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// Replaces the first entry under [key] (case-insensitive), or appends one.
  void set(String key, Object value) {
    final String lower = key.toLowerCase();
    for (int i = 0; i < entries.length; i++) {
      if (entries[i].key.toLowerCase() == lower) {
        entries[i] = VdfEntry(entries[i].key, value);
        return;
      }
    }
    entries.add(VdfEntry(key, value));
  }
}

class VdfEntry {
  const VdfEntry(this.key, this.value);

  final String key;

  /// [VdfMap], [String], [VdfInt32], [VdfFloat32] or [VdfUint64].
  final Object value;
}

class VdfInt32 {
  const VdfInt32(this.value);

  /// Signed, as stored. Steam's 32-bit app ids are written as int32.
  final int value;

  /// The same bits read as unsigned (how Steam names artwork files).
  int get unsigned => value & 0xFFFFFFFF;
}

class VdfFloat32 {
  const VdfFloat32(this.bits);

  /// Raw bits, so the value round-trips exactly.
  final int bits;
}

class VdfUint64 {
  const VdfUint64(this.bytes);

  /// Raw little-endian bytes (8), so the value round-trips exactly.
  final Uint8List bytes;
}

const int _typeMap = 0x00;
const int _typeString = 0x01;
const int _typeInt32 = 0x02;
const int _typeFloat32 = 0x03;
const int _typeUint64 = 0x07;
const int _typeEnd = 0x08;

/// Reads a whole binary VDF file into its root map.
VdfMap parseBinaryVdf(Uint8List bytes) {
  final _Reader reader = _Reader(bytes);
  final VdfMap root = reader.readMap();
  if (!reader.atEnd) {
    throw FormatException('trailing bytes at ${reader.offset}');
  }
  return root;
}

/// Writes [root] in the format [parseBinaryVdf] reads.
Uint8List serializeBinaryVdf(VdfMap root) {
  final BytesBuilder out = BytesBuilder(copy: false);
  _writeMapBody(out, root);
  return out.takeBytes();
}

void _writeMapBody(BytesBuilder out, VdfMap map) {
  for (final VdfEntry entry in map.entries) {
    final Object value = entry.value;
    if (value is VdfMap) {
      out.addByte(_typeMap);
      _writeCString(out, entry.key);
      _writeMapBody(out, value);
    } else if (value is String) {
      out.addByte(_typeString);
      _writeCString(out, entry.key);
      _writeCString(out, value);
    } else if (value is VdfInt32) {
      out.addByte(_typeInt32);
      _writeCString(out, entry.key);
      out.add(
        (ByteData(4)..setInt32(0, value.value.toSigned(32), Endian.little))
            .buffer
            .asUint8List(),
      );
    } else if (value is VdfFloat32) {
      out.addByte(_typeFloat32);
      _writeCString(out, entry.key);
      out.add(
        (ByteData(
          4,
        )..setUint32(0, value.bits, Endian.little)).buffer.asUint8List(),
      );
    } else if (value is VdfUint64) {
      out.addByte(_typeUint64);
      _writeCString(out, entry.key);
      out.add(value.bytes);
    } else {
      throw ArgumentError('unsupported VDF value ${value.runtimeType}');
    }
  }
  out.addByte(_typeEnd);
}

void _writeCString(BytesBuilder out, String text) {
  final List<int> encoded = utf8.encode(text);
  if (encoded.contains(0)) {
    throw ArgumentError('VDF strings cannot contain NUL');
  }
  out.add(encoded);
  out.addByte(0);
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  bool get atEnd => offset >= bytes.length;

  int _byte() {
    if (atEnd) throw const FormatException('unexpected end of file');
    return bytes[offset++];
  }

  String _cString() {
    final int start = offset;
    while (true) {
      if (atEnd) throw const FormatException('unterminated string');
      if (bytes[offset] == 0) break;
      offset++;
    }
    final String text = utf8.decode(
      bytes.sublist(start, offset),
      allowMalformed: false,
    );
    offset++;
    return text;
  }

  Uint8List _take(int length) {
    if (offset + length > bytes.length) {
      throw const FormatException('unexpected end of file');
    }
    final Uint8List slice = Uint8List.fromList(
      bytes.sublist(offset, offset + length),
    );
    offset += length;
    return slice;
  }

  VdfMap readMap() {
    final VdfMap map = VdfMap();
    while (true) {
      final int type = _byte();
      if (type == _typeEnd) return map;
      final String key = _cString();
      switch (type) {
        case _typeMap:
          map.entries.add(VdfEntry(key, readMap()));
        case _typeString:
          map.entries.add(VdfEntry(key, _cString()));
        case _typeInt32:
          final int value = ByteData.sublistView(
            _take(4),
          ).getInt32(0, Endian.little);
          map.entries.add(VdfEntry(key, VdfInt32(value)));
        case _typeFloat32:
          final int bits = ByteData.sublistView(
            _take(4),
          ).getUint32(0, Endian.little);
          map.entries.add(VdfEntry(key, VdfFloat32(bits)));
        case _typeUint64:
          map.entries.add(VdfEntry(key, VdfUint64(_take(8))));
        default:
          throw FormatException('unknown VDF type 0x${type.toRadixString(16)}');
      }
    }
  }
}
