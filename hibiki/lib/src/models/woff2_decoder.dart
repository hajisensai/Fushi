import 'dart:typed_data';

import 'package:brotli/brotli.dart';
import 'package:hibiki/src/models/font_decoder.dart';

/// Decodes a WOFF2 container into raw sfnt (TrueType) bytes that Flutter's
/// `FontLoader` can register.
///
/// WOFF2 = Brotli-compressed tables + a reversible transform of `glyf`/`loca`
/// (and optionally `hmtx`). The Flutter engine cannot read WOFF2, so for the
/// app UI we reconstruct the original sfnt: decompress, reverse the glyf/loca
/// transform, re-encode glyphs into the standard TrueType `glyf` format, and
/// reassemble via [FontDecoder.buildSfnt].
///
/// Returns `null` for anything it cannot faithfully reconstruct (the caller
/// then skips the font rather than registering a corrupt one). A transformed
/// `hmtx` is currently unsupported and yields `null`.
class Woff2Decoder {
  Woff2Decoder._();

  static const int _signature = 0x774F4632; // 'wOF2'
  static const int _glyfTag = 0x676C7966; // 'glyf'
  static const int _locaTag = 0x6C6F6361; // 'loca'
  static const int _headTag = 0x68656164; // 'head'
  static const int _hmtxTag = 0x686D7478; // 'hmtx'

  /// WOFF2 "known table tags" (flag index 0..62; 63 = explicit tag).
  static const List<String> _knownTagStrings = <String>[
    'cmap',
    'head',
    'hhea',
    'hmtx',
    'maxp',
    'name',
    'OS/2',
    'post',
    'cvt ',
    'fpgm',
    'glyf',
    'loca',
    'prep',
    'CFF ',
    'VORG',
    'EBDT',
    'EBLC',
    'gasp',
    'hdmx',
    'kern',
    'LTSH',
    'PCLT',
    'VDMX',
    'vhea',
    'vmtx',
    'BASE',
    'GDEF',
    'GPOS',
    'GSUB',
    'EBSC',
    'JSTF',
    'MATH',
    'CBDT',
    'CBLC',
    'COLR',
    'CPAL',
    'SVG ',
    'sbix',
    'acnt',
    'avar',
    'bdat',
    'bloc',
    'bsln',
    'cvar',
    'fdsc',
    'feat',
    'fmtx',
    'fvar',
    'gvar',
    'hsty',
    'just',
    'lcar',
    'ltag',
    'meta',
    'mort',
    'morx',
    'opbd',
    'prop',
    'trak',
    'Zapf',
    'Silf',
    'Glat',
    'Gloc',
  ];

  static int _tag(String s) =>
      (s.codeUnitAt(0) << 24) |
      (s.codeUnitAt(1) << 16) |
      (s.codeUnitAt(2) << 8) |
      s.codeUnitAt(3);

  /// Decodes [bytes] to sfnt, or `null` if it is not a decodable WOFF2.
  static Uint8List? toSfnt(Uint8List bytes) {
    try {
      return _decode(bytes);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _decode(Uint8List bytes) {
    final _Reader r = _Reader(bytes);
    if (r.u32() != _signature) return null;
    final int flavor = r.u32();
    r.u32(); // length
    final int numTables = r.u16();
    if (numTables == 0) return null;
    r.u16(); // reserved
    r.u32(); // totalSfntSize
    final int totalCompressedSize = r.u32();
    r.u16(); // majorVersion
    r.u16(); // minorVersion
    r.u32(); // metaOffset
    r.u32(); // metaLength
    r.u32(); // metaOrigLength
    r.u32(); // privOffset
    r.u32(); // privLength

    final List<_Entry> entries = <_Entry>[];
    for (int i = 0; i < numTables; i++) {
      final int flags = r.u8();
      final int tagIndex = flags & 0x3F;
      final int transform = (flags >> 6) & 0x03;
      final int tag =
          tagIndex == 63 ? r.u32() : _tag(_knownTagStrings[tagIndex]);
      final int origLength = r.base128();
      final bool transformed;
      if (tag == _glyfTag || tag == _locaTag) {
        transformed = transform == 0;
      } else if (tag == _hmtxTag) {
        transformed = transform == 1;
      } else {
        transformed = false;
      }
      final int transformLength = transformed ? r.base128() : origLength;
      entries.add(_Entry(tag, transformed, origLength, transformLength));
    }

    final Uint8List comp = r.take(totalCompressedSize);
    final Uint8List decoded = Uint8List.fromList(brotli.decode(comp));

    int p = 0;
    for (final _Entry e in entries) {
      if (p + e.streamLength > decoded.length) return null;
      e.data = Uint8List.sublistView(decoded, p, p + e.streamLength);
      p += e.streamLength;
    }

    final Map<int, Uint8List> out = <int, Uint8List>{};
    _Entry? glyf;
    for (final _Entry e in entries) {
      if (e.tag == _hmtxTag && e.transformed) return null; // unsupported
      if (e.tag == _glyfTag) {
        glyf = e;
        continue;
      }
      if (e.tag == _locaTag) {
        if (!e.transformed) out[e.tag] = e.data!;
        continue; // transformed loca is rebuilt from glyf
      }
      out[e.tag] = e.data!;
    }

    if (glyf != null) {
      if (glyf.transformed) {
        final _GlyfResult g = _reconstructGlyf(glyf.data!);
        out[_glyfTag] = g.glyf;
        out[_locaTag] = g.loca;
        final Uint8List? head = out[_headTag];
        if (head != null && head.length >= 52) {
          // We always emit the long loca format.
          final Uint8List patched = Uint8List.fromList(head);
          ByteData.view(patched.buffer).setInt16(50, 1);
          out[_headTag] = patched;
        }
      } else {
        out[_glyfTag] = glyf.data!;
      }
    }

    final List<SfntTable> tables = <SfntTable>[];
    out.forEach((int tag, Uint8List data) {
      tables.add(SfntTable(tag, _checksum(data), data));
    });
    return FontDecoder.buildSfnt(flavor, tables);
  }

  // ── glyf transform reversal (WOFF2 spec §5.1) ──────────────────────────

  static _GlyfResult _reconstructGlyf(Uint8List data) {
    final _Reader h = _Reader(data);
    h.u16(); // reserved
    final int optionFlags = h.u16();
    final int numGlyphs = h.u16();
    h.u16(); // indexFormat (ignored; we emit long loca)
    final int nContourSize = h.u32();
    final int nPointsSize = h.u32();
    final int flagSize = h.u32();
    final int glyphSize = h.u32();
    final int compositeSize = h.u32();
    final int bboxSize = h.u32();
    final int instructionSize = h.u32();
    if ((optionFlags & 0x0001) != 0) {
      h.u32(); // overlapSimpleBitmapSize (consumed; bitmap not needed here)
    }

    int base = h.pos;
    final _Reader nContour = _Reader.view(data, base, nContourSize);
    base += nContourSize;
    final _Reader nPoints = _Reader.view(data, base, nPointsSize);
    base += nPointsSize;
    final _Reader flagStream = _Reader.view(data, base, flagSize);
    base += flagSize;
    final _Reader glyphStream = _Reader.view(data, base, glyphSize);
    base += glyphSize;
    final _Reader compositeStream = _Reader.view(data, base, compositeSize);
    base += compositeSize;
    final _Reader bboxStream = _Reader.view(data, base, bboxSize);
    base += bboxSize;
    final _Reader instructionStream = _Reader.view(data, base, instructionSize);

    // bboxBitmap occupies the first 4*ceil(numGlyphs/32) bytes of bboxStream.
    final int bitmapLen = ((numGlyphs + 31) >> 5) << 2;
    final Uint8List bboxBitmap = bboxStream.take(bitmapLen);

    final BytesBuilder glyfOut = BytesBuilder(copy: false);
    final List<int> loca = <int>[0];

    for (int i = 0; i < numGlyphs; i++) {
      final int nc = nContour.i16();
      final bool hasBbox = (bboxBitmap[i >> 3] & (0x80 >> (i & 7))) != 0;
      Uint8List glyph;
      if (nc == 0) {
        glyph = Uint8List(0);
      } else if (nc > 0) {
        glyph = _simpleGlyph(
          nc,
          hasBbox,
          nPoints,
          flagStream,
          glyphStream,
          instructionStream,
          bboxStream,
        );
      } else {
        glyph = _compositeGlyph(
          hasBbox,
          compositeStream,
          glyphStream,
          instructionStream,
          bboxStream,
        );
      }
      glyfOut.add(glyph);
      if (glyph.length.isOdd) glyfOut.addByte(0); // 2-byte align
      loca.add(glyfOut.length);
    }

    final Uint8List glyf = glyfOut.toBytes();
    final ByteData locaBd = ByteData(loca.length * 4);
    for (int i = 0; i < loca.length; i++) {
      locaBd.setUint32(i * 4, loca[i]);
    }
    return _GlyfResult(glyf, locaBd.buffer.asUint8List());
  }

  static Uint8List _simpleGlyph(
    int nc,
    bool hasBbox,
    _Reader nPoints,
    _Reader flagStream,
    _Reader glyphStream,
    _Reader instructionStream,
    _Reader bboxStream,
  ) {
    final List<int> endPts = <int>[];
    int total = 0;
    for (int c = 0; c < nc; c++) {
      total += nPoints.read255();
      endPts.add(total - 1);
    }

    final Uint8List flags = flagStream.take(total);
    final List<_Pt> pts = _tripletDecode(flags, glyphStream, total);

    final int instrLen = glyphStream.read255();
    final Uint8List instr = instructionStream.take(instrLen);

    int xMin, yMin, xMax, yMax;
    if (hasBbox) {
      xMin = bboxStream.i16();
      yMin = bboxStream.i16();
      xMax = bboxStream.i16();
      yMax = bboxStream.i16();
    } else if (pts.isEmpty) {
      xMin = yMin = xMax = yMax = 0;
    } else {
      xMin = xMax = pts[0].x;
      yMin = yMax = pts[0].y;
      for (final _Pt pt in pts) {
        if (pt.x < xMin) xMin = pt.x;
        if (pt.x > xMax) xMax = pt.x;
        if (pt.y < yMin) yMin = pt.y;
        if (pt.y > yMax) yMax = pt.y;
      }
    }

    final BytesBuilder out = BytesBuilder(copy: false);
    out.add(_i16(nc));
    out.add(_i16(xMin));
    out.add(_i16(yMin));
    out.add(_i16(xMax));
    out.add(_i16(yMax));
    for (final int e in endPts) {
      out.add(_u16(e));
    }
    out.add(_u16(instrLen));
    out.add(instr);

    // Re-encode flags + coordinates in standard TrueType form (with REPEAT).
    final List<int> flagBytes = <int>[];
    final BytesBuilder xs = BytesBuilder(copy: false);
    final BytesBuilder ys = BytesBuilder(copy: false);
    int prevX = 0;
    int prevY = 0;
    for (final _Pt pt in pts) {
      final int dx = pt.x - prevX;
      final int dy = pt.y - prevY;
      prevX = pt.x;
      prevY = pt.y;
      int flag = pt.onCurve ? 0x01 : 0x00;
      if (dx == 0) {
        flag |= 0x10; // X_IS_SAME
      } else if (dx >= -255 && dx <= 255) {
        flag |= 0x02; // X_SHORT
        if (dx > 0) flag |= 0x10; // positive
        xs.addByte(dx.abs());
      } else {
        xs.add(_i16(dx));
      }
      if (dy == 0) {
        flag |= 0x20; // Y_IS_SAME
      } else if (dy >= -255 && dy <= 255) {
        flag |= 0x04; // Y_SHORT
        if (dy > 0) flag |= 0x20; // positive
        ys.addByte(dy.abs());
      } else {
        ys.add(_i16(dy));
      }
      flagBytes.add(flag);
    }
    out.add(_runLengthFlags(flagBytes));
    out.add(xs.toBytes());
    out.add(ys.toBytes());
    return out.toBytes();
  }

  static Uint8List _compositeGlyph(
    bool hasBbox,
    _Reader compositeStream,
    _Reader glyphStream,
    _Reader instructionStream,
    _Reader bboxStream,
  ) {
    final int start = compositeStream.pos;
    bool haveInstr = false;
    while (true) {
      final int flags = compositeStream.u16();
      compositeStream.u16(); // glyphIndex
      compositeStream
          .skip((flags & 0x0001) != 0 ? 4 : 2); // ARG_1_AND_2_ARE_WORDS
      if ((flags & 0x0008) != 0) {
        compositeStream.skip(2); // WE_HAVE_A_SCALE
      } else if ((flags & 0x0040) != 0) {
        compositeStream.skip(4); // WE_HAVE_AN_X_AND_Y_SCALE
      } else if ((flags & 0x0080) != 0) {
        compositeStream.skip(8); // WE_HAVE_A_TWO_BY_TWO
      }
      if ((flags & 0x0100) != 0) haveInstr = true; // WE_HAVE_INSTRUCTIONS
      if ((flags & 0x0020) == 0) break; // MORE_COMPONENTS
    }
    final Uint8List compBytes =
        compositeStream.range(start, compositeStream.pos);

    int instrLen = 0;
    Uint8List instr = Uint8List(0);
    if (haveInstr) {
      instrLen = glyphStream.read255();
      instr = instructionStream.take(instrLen);
    }

    // Composite glyphs must carry an explicit bbox.
    final int xMin = hasBbox ? bboxStream.i16() : 0;
    final int yMin = hasBbox ? bboxStream.i16() : 0;
    final int xMax = hasBbox ? bboxStream.i16() : 0;
    final int yMax = hasBbox ? bboxStream.i16() : 0;

    final BytesBuilder out = BytesBuilder(copy: false);
    out.add(_i16(-1));
    out.add(_i16(xMin));
    out.add(_i16(yMin));
    out.add(_i16(xMax));
    out.add(_i16(yMax));
    out.add(compBytes);
    if (haveInstr) {
      out.add(_u16(instrLen));
      out.add(instr);
    }
    return out.toBytes();
  }

  static List<_Pt> _tripletDecode(Uint8List flags, _Reader g, int n) {
    final List<_Pt> result = <_Pt>[];
    int x = 0;
    int y = 0;
    for (int i = 0; i < n; i++) {
      final int flag = flags[i];
      final bool onCurve = (flag & 0x80) == 0;
      final int f = flag & 0x7F;
      int dx;
      int dy;
      if (f < 10) {
        dx = 0;
        dy = _sign(f, ((f & 14) << 7) + g.u8());
      } else if (f < 20) {
        dx = _sign(f, (((f - 10) & 14) << 7) + g.u8());
        dy = 0;
      } else if (f < 84) {
        final int b0 = f - 20;
        final int b1 = g.u8();
        dx = _sign(f, 1 + (b0 & 0x30) + (b1 >> 4));
        dy = _sign(f >> 1, 1 + ((b0 & 0x0C) << 2) + (b1 & 0x0F));
      } else if (f < 120) {
        final int b0 = f - 84;
        final int b1 = g.u8();
        final int b2 = g.u8();
        dx = _sign(f, 1 + ((b0 ~/ 12) << 8) + b1);
        dy = _sign(f >> 1, 1 + (((b0 % 12) >> 2) << 8) + b2);
      } else if (f < 124) {
        final int b1 = g.u8();
        final int b2 = g.u8();
        final int b3 = g.u8();
        dx = _sign(f, (b1 << 4) + (b2 >> 4));
        dy = _sign(f >> 1, ((b2 & 0x0F) << 8) + b3);
      } else {
        final int b1 = g.u8();
        final int b2 = g.u8();
        final int b3 = g.u8();
        final int b4 = g.u8();
        dx = _sign(f, (b1 << 8) + b2);
        dy = _sign(f >> 1, (b3 << 8) + b4);
      }
      x += dx;
      y += dy;
      result.add(_Pt(x, y, onCurve));
    }
    return result;
  }

  static int _sign(int flag, int base) => (flag & 1) != 0 ? base : -base;

  static Uint8List _runLengthFlags(List<int> flags) {
    final BytesBuilder out = BytesBuilder(copy: false);
    int i = 0;
    while (i < flags.length) {
      final int f = flags[i];
      int repeat = 0;
      while (i + repeat + 1 < flags.length &&
          flags[i + repeat + 1] == f &&
          repeat < 255) {
        repeat++;
      }
      if (repeat > 0) {
        out.addByte(f | 0x08); // REPEAT_FLAG
        out.addByte(repeat);
        i += repeat + 1;
      } else {
        out.addByte(f);
        i++;
      }
    }
    return out.toBytes();
  }

  static int _checksum(Uint8List data) {
    final ByteData bd =
        ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
    int sum = 0;
    final int full = data.length & ~3;
    int i = 0;
    for (; i < full; i += 4) {
      sum = (sum + bd.getUint32(i)) & 0xFFFFFFFF;
    }
    if (i < data.length) {
      int rem = 0;
      for (int j = 0; j < 4; j++) {
        rem = (rem << 8) | (i + j < data.length ? data[i + j] : 0);
      }
      sum = (sum + rem) & 0xFFFFFFFF;
    }
    return sum;
  }

  static Uint8List _i16(int v) {
    final ByteData b = ByteData(2);
    b.setInt16(0, v);
    return b.buffer.asUint8List();
  }

  static Uint8List _u16(int v) {
    final ByteData b = ByteData(2);
    b.setUint16(0, v);
    return b.buffer.asUint8List();
  }
}

class _Entry {
  _Entry(this.tag, this.transformed, this.origLength, this.transformLength);
  final int tag;
  final bool transformed;
  final int origLength;
  final int transformLength;
  Uint8List? data;
  int get streamLength => transformed ? transformLength : origLength;
}

class _GlyfResult {
  _GlyfResult(this.glyf, this.loca);
  final Uint8List glyf;
  final Uint8List loca;
}

class _Pt {
  _Pt(this.x, this.y, this.onCurve);
  final int x;
  final int y;
  final bool onCurve;
}

/// Sequential big-endian reader over a byte range (no copying).
class _Reader {
  _Reader(Uint8List data)
      : _u = data,
        _bd =
            ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);

  factory _Reader.view(Uint8List data, int offset, int length) {
    final Uint8List slice =
        Uint8List.sublistView(data, offset, offset + length);
    return _Reader(slice);
  }

  final Uint8List _u;
  final ByteData _bd;
  int _p = 0;

  int get pos => _p;

  void skip(int n) => _p += n;

  int u8() => _bd.getUint8(_p++);

  int u16() {
    final int v = _bd.getUint16(_p);
    _p += 2;
    return v;
  }

  int i16() {
    final int v = _bd.getInt16(_p);
    _p += 2;
    return v;
  }

  int u32() {
    final int v = _bd.getUint32(_p);
    _p += 4;
    return v;
  }

  /// WOFF2 UIntBase128 variable-length unsigned integer.
  int base128() {
    int result = 0;
    for (int i = 0; i < 5; i++) {
      final int b = u8();
      if (i == 0 && b == 0x80) {
        throw const FormatException('UIntBase128 leading zero');
      }
      if ((result & 0xFE000000) != 0) {
        throw const FormatException('UIntBase128 overflow');
      }
      result = (result << 7) | (b & 0x7F);
      if ((b & 0x80) == 0) return result;
    }
    throw const FormatException('UIntBase128 too long');
  }

  /// WOFF2 255UInt16 variable-length unsigned short.
  int read255() {
    final int code = u8();
    if (code == 253) {
      return u16();
    } else if (code == 255) {
      return u8() + 253;
    } else if (code == 254) {
      return u8() + 506;
    }
    return code;
  }

  Uint8List take(int n) {
    final Uint8List slice = Uint8List.sublistView(_u, _p, _p + n);
    _p += n;
    return slice;
  }

  Uint8List range(int start, int end) => Uint8List.sublistView(_u, start, end);
}
