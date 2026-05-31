import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/font_decoder.dart';

/// One table for the test WOFF encoder.
class _Tbl {
  _Tbl(this.tag, this.data);
  final int tag;
  final Uint8List data;
}

int _tag(String s) {
  assert(s.length == 4);
  return (s.codeUnitAt(0) << 24) |
      (s.codeUnitAt(1) << 16) |
      (s.codeUnitAt(2) << 8) |
      s.codeUnitAt(3);
}

Uint8List _filled(int n, int byte) =>
    Uint8List.fromList(List<int>.filled(n, byte));

int _pad4(int n) => (n + 3) & ~3;

/// Minimal WOFF 1.0 encoder mirroring the container [FontDecoder.woffToSfnt]
/// consumes. Compresses each table with zlib; stores uncompressed when that
/// would not shrink it (exercising both decode paths).
Uint8List _encodeWoff(int flavor, List<_Tbl> tables) {
  final int n = tables.length;
  const int headerSize = 44;
  const int dirSize = 20;
  final List<Uint8List> blobs = <Uint8List>[];
  final List<int> compLengths = <int>[];
  final List<int> origLengths = <int>[];
  for (final _Tbl t in tables) {
    final Uint8List comp = Uint8List.fromList(zlib.encode(t.data));
    if (comp.length < t.data.length) {
      blobs.add(comp);
      compLengths.add(comp.length);
    } else {
      blobs.add(t.data);
      compLengths.add(t.data.length); // stored: compLength == origLength
    }
    origLengths.add(t.data.length);
  }

  int offset = headerSize + dirSize * n;
  final List<int> offsets = <int>[];
  for (int i = 0; i < n; i++) {
    offsets.add(offset);
    offset = _pad4(offset + blobs[i].length);
  }
  final int total = offset;
  final Uint8List out = Uint8List(total);
  final ByteData bd = ByteData.view(out.buffer);

  bd.setUint32(0, 0x774F4646); // 'wOFF'
  bd.setUint32(4, flavor);
  bd.setUint32(8, total);
  bd.setUint16(12, n);
  bd.setUint16(14, 0);
  bd.setUint32(16, 0); // totalSfntSize (unused by decoder)

  for (int i = 0; i < n; i++) {
    final int o = headerSize + i * dirSize;
    bd.setUint32(o, tables[i].tag);
    bd.setUint32(o + 4, offsets[i]);
    bd.setUint32(o + 8, compLengths[i]);
    bd.setUint32(o + 12, origLengths[i]);
    bd.setUint32(o + 16, 0); // origChecksum (decoder copies; tests ignore)
    out.setRange(offsets[i], offsets[i] + blobs[i].length, blobs[i]);
  }
  return out;
}

({int flavor, Map<int, Uint8List> tables}) _parseSfnt(Uint8List sfnt) {
  final ByteData bd =
      ByteData.view(sfnt.buffer, sfnt.offsetInBytes, sfnt.lengthInBytes);
  final int flavor = bd.getUint32(0);
  final int n = bd.getUint16(4);
  final Map<int, Uint8List> tables = <int, Uint8List>{};
  for (int i = 0; i < n; i++) {
    final int o = 12 + i * 16;
    final int tag = bd.getUint32(o);
    final int off = bd.getUint32(o + 8);
    final int len = bd.getUint32(o + 12);
    tables[tag] = Uint8List.sublistView(sfnt, off, off + len);
  }
  return (flavor: flavor, tables: tables);
}

void main() {
  group('FontDecoder.woffToSfnt', () {
    test('round-trips compressed + stored tables back to sfnt', () {
      final List<_Tbl> entries = <_Tbl>[
        _Tbl(_tag('aaaa'), _filled(200, 7)), // compressible -> zlib path
        _Tbl(
            _tag('bbbb'), Uint8List.fromList(<int>[1, 2, 3])), // -> stored path
        _Tbl(_tag('cccc'), _filled(64, 3)),
      ];
      final Uint8List woff = _encodeWoff(0x00010000, entries);

      final Uint8List? sfnt = FontDecoder.woffToSfnt(woff);
      expect(sfnt, isNotNull);

      final parsed = _parseSfnt(sfnt!);
      expect(parsed.flavor, 0x00010000);
      expect(parsed.tables.length, entries.length);
      for (final _Tbl e in entries) {
        expect(parsed.tables[e.tag], equals(e.data),
            reason: 'table 0x${e.tag.toRadixString(16)} data mismatch');
      }
    });

    test('directory is sorted by tag ascending', () {
      final Uint8List woff = _encodeWoff(0x00010000, <_Tbl>[
        _Tbl(_tag('zzzz'), _filled(20, 1)),
        _Tbl(_tag('aaaa'), _filled(20, 2)),
        _Tbl(_tag('mmmm'), _filled(20, 3)),
      ]);
      final Uint8List sfnt = FontDecoder.woffToSfnt(woff)!;
      final ByteData bd = ByteData.view(sfnt.buffer);
      final int n = bd.getUint16(4);
      int prev = -1;
      for (int i = 0; i < n; i++) {
        final int tag = bd.getUint32(12 + i * 16);
        expect(tag > prev, isTrue, reason: 'records not tag-sorted');
        prev = tag;
      }
    });

    test('recomputes head.checkSumAdjustment so font checksum is the magic',
        () {
      final Uint8List woff = _encodeWoff(0x00010000, <_Tbl>[
        _Tbl(_tag('head'), Uint8List(54)),
        _Tbl(_tag('aaaa'), _filled(40, 9)),
      ]);
      final Uint8List sfnt = FontDecoder.woffToSfnt(woff)!;
      final ByteData bd = ByteData.view(sfnt.buffer);
      int sum = 0;
      for (int i = 0; i + 4 <= sfnt.length; i += 4) {
        sum = (sum + bd.getUint32(i)) & 0xFFFFFFFF;
      }
      expect(sum, 0xB1B0AFBA);
    });

    test('rejects non-WOFF bytes', () {
      expect(
          FontDecoder.woffToSfnt(Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5])),
          isNull);
    });
  });
}
