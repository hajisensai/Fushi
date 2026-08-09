import 'dart:io' show zlib;
import 'dart:typed_data';

/// Converts web-font containers to raw sfnt (TrueType/OpenType) bytes that
/// Flutter's `FontLoader` can register.
///
/// The Flutter engine only accepts raw sfnt data; it cannot read WOFF/WOFF2
/// (those only work in the reader's WebView, which has a browser font stack).
/// To use a user-imported web font for the app UI we must reconstruct the
/// underlying sfnt and hand THAT to the engine. This file covers WOFF 1.0
/// (per-table zlib). WOFF2 (Brotli + glyf/loca transform) is handled
/// separately.
class FontDecoder {
  FontDecoder._();

  static const int _woffSignature = 0x774F4646; // 'wOFF'
  static const int _headTag = 0x68656164; // 'head'
  static const int _headerSize = 44;
  static const int _dirEntrySize = 20;

  /// Decodes a WOFF 1.0 container to sfnt bytes, or `null` when [bytes] is not
  /// a valid/decodable WOFF (caller then skips this font).
  static Uint8List? woffToSfnt(Uint8List bytes) {
    if (bytes.length < _headerSize) return null;
    final ByteData bd =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
    if (bd.getUint32(0) != _woffSignature) return null;

    final int flavor = bd.getUint32(4);
    final int numTables = bd.getUint16(12);
    if (numTables == 0) return null;
    if (_headerSize + numTables * _dirEntrySize > bytes.length) return null;

    final List<_WoffTable> tables = <_WoffTable>[];
    for (int i = 0; i < numTables; i++) {
      final int o = _headerSize + i * _dirEntrySize;
      tables.add(_WoffTable(
        tag: bd.getUint32(o),
        offset: bd.getUint32(o + 4),
        compLength: bd.getUint32(o + 8),
        origLength: bd.getUint32(o + 12),
        origChecksum: bd.getUint32(o + 16),
      ));
    }

    for (final _WoffTable t in tables) {
      if (t.offset + t.compLength > bytes.length) return null;
      final Uint8List comp =
          Uint8List.sublistView(bytes, t.offset, t.offset + t.compLength);
      if (t.compLength >= t.origLength) {
        // Stored uncompressed (spec: compLength == origLength).
        t.data = Uint8List.sublistView(comp, 0, t.origLength);
      } else {
        final List<int> inflated = zlib.decode(comp);
        if (inflated.length != t.origLength) return null;
        t.data = Uint8List.fromList(inflated);
      }
    }

    return buildSfnt(
        flavor,
        tables
            .map((_WoffTable t) => SfntTable(t.tag, t.origChecksum, t.data!))
            .toList());
  }

  /// Assembles a complete sfnt file from decoded [tables] under [flavor]
  /// (the sfnt version, e.g. 0x00010000 for TrueType or 'OTTO').
  ///
  /// Shared by the WOFF and WOFF2 paths. Sorts the table directory by tag,
  /// 4-byte-aligns each table, and recomputes `head.checkSumAdjustment` so the
  /// result is a structurally valid font.
  static Uint8List buildSfnt(int flavor, List<SfntTable> tables) {
    final int numTables = tables.length;
    tables.sort((SfntTable a, SfntTable b) => a.tag.compareTo(b.tag));

    int offset = 12 + 16 * numTables;
    final List<int> dataOffsets = <int>[];
    for (final SfntTable t in tables) {
      dataOffsets.add(offset);
      offset += t.data.length;
      offset = (offset + 3) & ~3;
    }
    final int totalSize = offset;
    final Uint8List out = Uint8List(totalSize);
    final ByteData od = ByteData.view(out.buffer);

    final int maxPow2 = _largestPow2LE(numTables);
    od.setUint32(0, flavor);
    od.setUint16(4, numTables);
    od.setUint16(6, maxPow2 * 16);
    od.setUint16(8, _log2(maxPow2));
    od.setUint16(10, numTables * 16 - maxPow2 * 16);

    int recOff = 12;
    int headDataOffset = -1;
    for (int i = 0; i < numTables; i++) {
      final SfntTable t = tables[i];
      final int dOff = dataOffsets[i];
      od.setUint32(recOff, t.tag);
      od.setUint32(recOff + 4, t.checksum);
      od.setUint32(recOff + 8, dOff);
      od.setUint32(recOff + 12, t.data.length);
      out.setRange(dOff, dOff + t.data.length, t.data);
      if (t.tag == _headTag) headDataOffset = dOff;
      recOff += 16;
    }

    if (headDataOffset >= 0 && headDataOffset + 12 <= totalSize) {
      od.setUint32(headDataOffset + 8, 0);
      final int sum = _checksum(od, totalSize);
      od.setUint32(headDataOffset + 8, (0xB1B0AFBA - sum) & 0xFFFFFFFF);
    }
    return out;
  }

  static int _checksum(ByteData data, int end) {
    int sum = 0;
    for (int i = 0; i + 4 <= end; i += 4) {
      sum = (sum + data.getUint32(i)) & 0xFFFFFFFF;
    }
    return sum;
  }

  static int _largestPow2LE(int n) {
    int p = 1;
    while (p * 2 <= n) {
      p *= 2;
    }
    return p;
  }

  static int _log2(int n) {
    int r = 0;
    while ((1 << (r + 1)) <= n) {
      r++;
    }
    return r;
  }
}

/// One decoded table on its way into [FontDecoder.buildSfnt].
class SfntTable {
  SfntTable(this.tag, this.checksum, this.data);
  final int tag;
  final int checksum;
  final Uint8List data;
}

class _WoffTable {
  _WoffTable({
    required this.tag,
    required this.offset,
    required this.compLength,
    required this.origLength,
    required this.origChecksum,
  });
  final int tag;
  final int offset;
  final int compLength;
  final int origLength;
  final int origChecksum;
  Uint8List? data;
}
