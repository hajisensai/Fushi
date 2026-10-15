import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/font_vertical_baseline_flag.dart';

/// 一张 54 字节的 head 表，flags 按 [flags] 写入（偏移 16）。
Uint8List _headTable(int flags) {
  final ByteData head = ByteData(54);
  head.setUint32(0, 0x00010000); // version
  head.setUint32(12, 0x5F0F3CF5); // magicNumber
  head.setUint16(16, flags);
  head.setUint16(18, 1000); // unitsPerEm
  return head.buffer.asUint8List();
}

int _checksum(Uint8List data, int offset, int length, {bool head = false}) {
  int sum = 0;
  for (int i = offset; i < offset + length; i += 4) {
    int word = 0;
    for (int k = 0; k < 4; k++) {
      word = (word << 8) | (i + k < offset + length ? data[i + k] : 0);
    }
    if (head && i - offset == 8) word = 0;
    sum = (sum + word) & 0xFFFFFFFF;
  }
  return sum;
}

/// 最小 sfnt：表目录 + head + 一张 8 字节的 'post' 占位表。
Uint8List _sfnt(int flags, {int tag = 0x00010000}) {
  final Uint8List head = _headTable(flags);
  const int dirEnd = 12 + 2 * 16;
  const int headOffset = dirEnd;
  const int postOffset = headOffset + 56; // head 补齐到 4 字节
  final ByteData out = ByteData(postOffset + 8);
  out.setUint32(0, tag);
  out.setUint16(4, 2);
  // 'head'
  out.setUint32(12, 0x68656164);
  out.setUint32(20, headOffset);
  out.setUint32(24, 54);
  // 'post'
  out.setUint32(28, 0x706F7374);
  out.setUint32(36, postOffset);
  out.setUint32(40, 8);
  final Uint8List bytes = out.buffer.asUint8List();
  bytes.setRange(headOffset, headOffset + 54, head);
  out.setUint32(16, _checksum(bytes, headOffset, 54, head: true));
  return bytes;
}

int _flagsAt(Uint8List data, int headOffset) =>
    ByteData.sublistView(data).getUint16(headOffset + 16);

void main() {
  group('clearVerticalBaselineFlag (head.flags bit 5, Apple 竖排偏半个字)', () {
    test('sfnt：清掉第 5 位，其它位不动，表校验和与 checkSumAdjustment 重算', () {
      final Uint8List font = _sfnt(0x0229); // M PLUS Rounded 1c 的 flags
      final ({Uint8List data, String? mime}) fixed = clearVerticalBaselineFlag(
        font,
      );
      expect(fixed.mime, isNull);
      expect(_flagsAt(fixed.data, 44), 0x0209);
      final ByteData d = ByteData.sublistView(fixed.data);
      expect(d.getUint32(16), _checksum(fixed.data, 44, 54, head: true));
      // 整个文件（含 checkSumAdjustment）按 uint32 求和 = 0xB1B0AFBA。
      expect(_checksum(fixed.data, 0, fixed.data.length), 0xB1B0AFBA);
      // 输入不被改动。
      expect(_flagsAt(font, 44), 0x0229);
    });

    test('CFF（OTTO）同样处理', () {
      final Uint8List font = _sfnt(0x0020, tag: 0x4F54544F);
      expect(_flagsAt(clearVerticalBaselineFlag(font).data, 44), 0);
    });

    test('没设第 5 位：原样返回同一个实例，不复制', () {
      final Uint8List font = _sfnt(0x000B); // Zen Maru Gothic 的 flags
      expect(identical(clearVerticalBaselineFlag(font).data, font), isTrue);
    });

    test('TTC：每个子字体的 head 都清掉', () {
      final Uint8List a = _sfnt(0x0029);
      final Uint8List b = _sfnt(0x0021);
      const int header = 12 + 2 * 4;
      final int bOffset = header + a.length;
      final ByteData ttc = ByteData(bOffset + b.length);
      ttc.setUint32(0, 0x74746366); // 'ttcf'
      ttc.setUint32(4, 0x00010000);
      ttc.setUint32(8, 2);
      ttc.setUint32(12, header);
      ttc.setUint32(16, bOffset);
      final Uint8List bytes = ttc.buffer.asUint8List();
      bytes.setRange(header, header + a.length, a);
      bytes.setRange(bOffset, bOffset + b.length, b);
      // 子字体表目录里的 offset 是相对整个文件的。
      final ByteData view = ByteData.sublistView(bytes);
      for (final int base in <int>[header, bOffset]) {
        view.setUint32(base + 20, base + 44);
        view.setUint32(base + 36, base + 100);
      }
      final Uint8List out = clearVerticalBaselineFlag(bytes).data;
      expect(_flagsAt(out, header + 44), 0x0009);
      expect(_flagsAt(out, bOffset + 44), 0x0001);
    });

    test('WOFF：head 未压缩时就地清掉并更新 origChecksum', () {
      final Uint8List head = _headTable(0x0020);
      const int dirEnd = 44 + 20;
      final ByteData woff = ByteData(dirEnd + 56);
      woff.setUint32(0, 0x774F4646); // 'wOFF'
      woff.setUint32(4, 0x00010000);
      woff.setUint16(12, 1);
      woff.setUint32(44, 0x68656164);
      woff.setUint32(48, dirEnd);
      woff.setUint32(52, 54); // compLength
      woff.setUint32(56, 54); // origLength
      final Uint8List bytes = woff.buffer.asUint8List();
      bytes.setRange(dirEnd, dirEnd + 54, head);
      final Uint8List out = clearVerticalBaselineFlag(bytes).data;
      expect(ByteData.sublistView(out).getUint16(dirEnd + 16), 0);
      expect(
        ByteData.sublistView(out).getUint32(60),
        _checksum(out, dirEnd, 54, head: true),
      );
    });

    test('不是字体 / 截断数据：原样返回', () {
      final Uint8List junk = Uint8List.fromList(List<int>.filled(40, 7));
      expect(identical(clearVerticalBaselineFlag(junk).data, junk), isTrue);
      final Uint8List cut = _sfnt(0x0020).sublist(0, 60);
      expect(identical(clearVerticalBaselineFlag(cut).data, cut), isTrue);
    });
  });
}
