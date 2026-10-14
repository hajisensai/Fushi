import 'dart:typed_data';

import 'package:fushi/src/models/woff2_decoder.dart';

/// 阅读器加载字体前清掉 `head.flags` 的第 5 位（「x = 0 是竖排基线」）。
///
/// OpenType 规定这一位表示字形按竖排画、x 坐标 0 就是竖排基线。Apple 的 CoreText（iOS /
/// macOS 的 WKWebView）照它办：竖排直立字形不再按字宽左移半个字居中；DirectWrite、
/// FreeType（Windows / Android / Linux）都不看这一位。M PLUS Rounded 1c（字体目录里的推荐
/// 字体）是普通横排字形（x 从 0 画到 1000），却错设了这一位——Apple 上竖排整列字形偏出
/// 自己的行盒半个字（+0.5em，Mac WKWebView 实测，清掉这一位后为 0；给正常字体设上这一位
/// 同样偏 +0.5em），高亮窄条、选区、光标都对不上字，其它平台正常。清掉它让 Apple 与
/// 其它平台画法一致：真按 x = 0 画竖排字形的字体本来就只在 Apple 上画对，三个引擎里有
/// 两个不认这一位。
///
/// 支持 sfnt（TrueType / CFF）、TTC（逐个子字体）、WOFF（head 未压缩时就地改）与 WOFF2
/// （只有确实带这一位时才解码成 sfnt 下发）。没设这一位或解析不了时原样返回、不复制。
/// 改动后同步更新 head 的表目录校验和与 `checkSumAdjustment`。
({Uint8List data, String? mime}) clearVerticalBaselineFlag(Uint8List data) {
  if (data.length < 12) return (data: data, mime: null);
  final ByteData bytes = ByteData.sublistView(data);
  final int tag = bytes.getUint32(0);
  if (tag == _ttcf) {
    final Uint8List? out = _patchCollection(data);
    return (data: out ?? data, mime: null);
  }
  if (tag == _wOFF) {
    final Uint8List? out = _patchWoff(data);
    return (data: out ?? data, mime: null);
  }
  if (tag == _wOF2) {
    // WOFF2 的 head 永远在压缩流里，只能解码后看；没设这一位就原样下发 WOFF2。
    final Uint8List? sfnt = Woff2Decoder.toSfnt(data);
    if (sfnt == null) return (data: data, mime: null);
    final Uint8List? out = _patchSfnt(sfnt, 0, wholeFontChecksum: true);
    if (out == null) return (data: data, mime: null);
    final bool cff = ByteData.sublistView(out).getUint32(0) == _otto;
    return (data: out, mime: cff ? 'font/otf' : 'font/ttf');
  }
  if (tag == 0x00010000 || tag == _otto || tag == _true) {
    final Uint8List? out = _patchSfnt(data, 0, wholeFontChecksum: true);
    return (data: out ?? data, mime: null);
  }
  return (data: data, mime: null);
}

const int _flagBit = 1 << 5;
const int _head = 0x68656164; // 'head'
const int _ttcf = 0x74746366; // 'ttcf'
const int _wOFF = 0x774F4646; // 'wOFF'
const int _wOF2 = 0x774F4632; // 'wOF2'
const int _otto = 0x4F54544F; // 'OTTO'
const int _true = 0x74727565; // 'true'

/// 单个 sfnt（从 [start] 开始的表目录）。需要改时返回副本，否则 null。
Uint8List? _patchSfnt(
  Uint8List data,
  int start, {
  required bool wholeFontChecksum,
  Uint8List? into,
}) {
  final ByteData src = ByteData.sublistView(data);
  if (start + 12 > data.length) return null;
  final int numTables = src.getUint16(start + 4);
  for (int i = 0; i < numTables; i++) {
    final int rec = start + 12 + i * 16;
    if (rec + 16 > data.length) return null;
    if (src.getUint32(rec) != _head) continue;
    final int offset = src.getUint32(rec + 8);
    final int length = src.getUint32(rec + 12);
    if (length < 54 || offset + length > data.length) return null;
    final int flags = src.getUint16(offset + 16);
    if (flags & _flagBit == 0) return null;
    final Uint8List out = into ?? Uint8List.fromList(data);
    final ByteData dst = ByteData.sublistView(out);
    dst.setUint16(offset + 16, flags & ~_flagBit);
    if (wholeFontChecksum) dst.setUint32(offset + 8, 0);
    dst.setUint32(
      rec + 4,
      _tableChecksum(out, offset, length, headTable: true),
    );
    if (wholeFontChecksum) {
      final int sum = _tableChecksum(out, 0, out.length, headTable: false);
      dst.setUint32(offset + 8, (0xB1B0AFBA - sum) & 0xFFFFFFFF);
    }
    return out;
  }
  return null;
}

/// TTC：逐个子字体改（子字体可能共用同一张 head 表，改过就不再改）。
Uint8List? _patchCollection(Uint8List data) {
  final ByteData src = ByteData.sublistView(data);
  if (data.length < 12) return null;
  final int count = src.getUint32(8);
  Uint8List? out;
  for (int i = 0; i < count; i++) {
    final int at = 12 + i * 4;
    if (at + 4 > data.length) break;
    final Uint8List? patched = _patchSfnt(
      out ?? data,
      src.getUint32(at),
      wholeFontChecksum: false,
      into: out,
    );
    if (patched != null) out = patched;
  }
  return out;
}

/// WOFF 1：head 表没压缩（compLength == origLength）时就地改并更新 origChecksum；
/// 压缩了就原样返回（WOFF 1 下这种 head 极少见）。
Uint8List? _patchWoff(Uint8List data) {
  final ByteData src = ByteData.sublistView(data);
  if (data.length < 44) return null;
  final int numTables = src.getUint16(12);
  for (int i = 0; i < numTables; i++) {
    final int rec = 44 + i * 20;
    if (rec + 20 > data.length) return null;
    if (src.getUint32(rec) != _head) continue;
    final int offset = src.getUint32(rec + 4);
    final int compLength = src.getUint32(rec + 8);
    final int origLength = src.getUint32(rec + 12);
    if (compLength != origLength || origLength < 54) return null;
    if (offset + origLength > data.length) return null;
    final int flags = src.getUint16(offset + 16);
    if (flags & _flagBit == 0) return null;
    final Uint8List out = Uint8List.fromList(data);
    final ByteData dst = ByteData.sublistView(out);
    dst.setUint16(offset + 16, flags & ~_flagBit);
    dst.setUint32(
      rec + 16,
      _tableChecksum(out, offset, origLength, headTable: true),
    );
    return out;
  }
  return null;
}

/// OpenType 表校验和：按大端 uint32 求和（不足 4 字节补 0）。head 表计算时
/// `checkSumAdjustment`（偏移 8）按 0 算。
int _tableChecksum(
  Uint8List data,
  int offset,
  int length, {
  required bool headTable,
}) {
  int sum = 0;
  final int end = offset + length;
  for (int i = offset; i < end; i += 4) {
    int word = 0;
    for (int k = 0; k < 4; k++) {
      word = (word << 8) | (i + k < end ? data[i + k] : 0);
    }
    if (headTable && i - offset == 8) word = 0;
    sum = (sum + word) & 0xFFFFFFFF;
  }
  return sum;
}
