// WOFF2 → sfnt（ffc_font_woff2_to_sfnt）：回归向量逐字节一致 + 结构合法 + 坏输入。
//
// 原生库是硬依赖：找不到库就失败（FushiComputeUnavailableError），不 skip。测试宿主下
// 加载器自动向上找 native/fushi_compute/prebuilt/<平台>/；FUSHI_COMPUTE_LIB 可覆盖。
//
// 回归向量（woff2_vectors.json）的 sfnt 哈希来自已删除的纯 Dart 解码器，Rust 输出在删除前
// 逐份比对过。大字体语料不入库：设 FUSHI_WOFF2_CORPUS 指向语料目录才会额外比对。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

const String _fontDir = 'test/font';

class _Vector {
  _Vector(this.path, this.woff2Sha256, this.sfntSha256);
  final String path;
  final String woff2Sha256;
  final String sfntSha256;
}

List<_Vector> _vectors(String group, String baseDir) {
  final Map<String, Object?> json =
      jsonDecode(File('$_fontDir/woff2_vectors.json').readAsStringSync())
          as Map<String, Object?>;
  return <_Vector>[
    for (final Map<String, Object?> e
        in (json[group]! as List<Object?>).cast<Map<String, Object?>>())
      _Vector(
        '$baseDir/${e['file']}',
        e['woff2_sha256']! as String,
        e['sfnt_sha256']! as String,
      ),
  ];
}

/// 解析 sfnt 表目录：tag → (offset, length, checksum)。
Map<String, (int, int, int)> _tables(Uint8List sfnt) {
  final ByteData bd = ByteData.sublistView(sfnt);
  final int n = bd.getUint16(4);
  return <String, (int, int, int)>{
    for (int i = 0; i < n; i++)
      String.fromCharCodes(sfnt.sublist(12 + i * 16, 16 + i * 16)): (
        bd.getUint32(12 + i * 16 + 8),
        bd.getUint32(12 + i * 16 + 12),
        bd.getUint32(12 + i * 16 + 4),
      ),
  };
}

int _sum(Uint8List data, int start, int length) {
  int sum = 0;
  for (int i = 0; i < length; i += 4) {
    int word = 0;
    for (int j = 0; j < 4; j++) {
      final int k = start + i + j;
      word = (word << 8) | (i + j < length ? data[k] : 0);
    }
    sum = (sum + word) & 0xFFFFFFFF;
  }
  return sum;
}

/// 表目录升序、4 字节对齐、表校验和正确、整字体校验和为 0xB1B0AFBA、loca 与 glyf 自洽。
void _expectStructurallyValid(Uint8List sfnt, String name) {
  final ByteData bd = ByteData.sublistView(sfnt);
  final Map<String, (int, int, int)> tables = _tables(sfnt);
  final List<String> tags = tables.keys.toList();
  expect(tags, orderedEquals(List<String>.of(tags)..sort()), reason: name);
  final (int, int, int) head = tables['head']!;
  for (final MapEntry<String, (int, int, int)> t in tables.entries) {
    expect(t.value.$1 % 4, 0, reason: '$name ${t.key} offset alignment');
    if (t.key == 'head') continue; // 目录校验和含解码前的 checkSumAdjustment
    expect(
      _sum(sfnt, t.value.$1, t.value.$2),
      t.value.$3,
      reason: '$name ${t.key} checksum',
    );
  }
  expect(_sum(sfnt, 0, sfnt.length), 0xB1B0AFBA, reason: '$name whole-font');
  final (int, int, int)? glyf = tables['glyf'];
  final (int, int, int)? loca = tables['loca'];
  if (glyf != null && loca != null) {
    final int numGlyphs = bd.getUint16(tables['maxp']!.$1 + 4);
    expect(bd.getInt16(head.$1 + 50), 1, reason: '$name long loca');
    expect(loca.$2, (numGlyphs + 1) * 4, reason: '$name loca length');
    int prev = 0;
    for (int i = 0; i <= numGlyphs; i++) {
      final int off = bd.getUint32(loca.$1 + i * 4);
      expect(off >= prev, isTrue, reason: '$name loca monotonic at $i');
      prev = off;
    }
    expect(prev, glyf.$2, reason: '$name last loca == glyf length');
  }
}

void main() {
  final FushiFont font = FushiFont.instance;

  group('committed regression vectors', () {
    for (final _Vector v in _vectors('committed', _fontDir + '/fixtures')) {
      test(v.path.split('/').last, () {
        final Uint8List woff2 = File(v.path).readAsBytesSync();
        expect(sha256.convert(woff2).toString(), v.woff2Sha256);
        final Uint8List? sfnt = font.woff2ToSfnt(woff2);
        expect(sfnt, isNotNull);
        expect(sha256.convert(sfnt!).toString(), v.sfntSha256);
        _expectStructurallyValid(sfnt, v.path);
      });
    }
  });

  final String? corpus = Platform.environment['FUSHI_WOFF2_CORPUS'];
  group('large CJK corpus (FUSHI_WOFF2_CORPUS)', () {
    for (final _Vector v in _vectors('corpus', corpus ?? '')) {
      test(v.path.split('/').last, () {
        final Uint8List woff2 = File(v.path).readAsBytesSync();
        expect(sha256.convert(woff2).toString(), v.woff2Sha256);
        final Uint8List? sfnt = font.woff2ToSfnt(woff2);
        expect(sha256.convert(sfnt!).toString(), v.sfntSha256);
        _expectStructurallyValid(sfnt, v.path);
      });
    }
  }, skip: corpus == null ? 'FUSHI_WOFF2_CORPUS not set' : null);

  group('tableChecksum', () {
    // 向量由删除前的 Dart `_tableChecksum`（font_vertical_baseline_flag.dart）对确定性输入
    // byte(i) = (i * 0x9E3779B1 mod 2^32) >> 24 生成：(长度, headTable, 结果)。
    // 覆盖空、补零尾字（1/3/9/10/11/13/4099）、偏移 8 恰为补零尾字（9～11）与整字。
    const List<(int, bool, int)> vectors = <(int, bool, int)>[
      (0, false, 0),
      (0, true, 0),
      (1, false, 0),
      (1, true, 0),
      (3, false, 10370048),
      (3, true, 10370048),
      (4, false, 10370266),
      (4, true, 10370266),
      (8, false, 2025189933),
      (8, true, 2025189933),
      (9, false, 1773531693),
      (9, true, 2025189933),
      (10, false, 1782903341),
      (10, true, 2025189933),
      (11, false, 1782915117),
      (11, true, 2025189933),
      (12, false, 1782915321),
      (12, true, 2025189933),
      (13, false, 3561300217),
      (13, true, 3803574829),
      (54, false, 4154254568),
      (54, true, 101561884),
      (4096, false, 2052601364),
      (4096, true, 2294875976),
      (4099, false, 4050512404),
      (4099, true, 4292787016),
    ];
    final Uint8List buf = Uint8List(4099);
    for (int i = 0; i < buf.length; i++) {
      buf[i] = ((i * 0x9E3779B1) & 0xffffffff) >> 24;
    }

    test('matches the former Dart implementation bit for bit', () {
      for (final (int len, bool head, int expected) in vectors) {
        expect(
          font.tableChecksum(buf, length: len, headTable: head),
          expected,
          reason: 'length $len headTable $head',
        );
      }
      // 非零 offset：[5, 59)，head 表。
      expect(
        font.tableChecksum(buf, offset: 5, length: 54, headTable: true),
        825805873,
      );
    });

    test('whole decoded font sums to the OpenType magic', () {
      final Uint8List sfnt = font.woff2ToSfnt(
        File(
          '$_fontDir/fixtures/NotoSerifJP-subset-hmtx.woff2',
        ).readAsBytesSync(),
      )!;
      expect(font.tableChecksum(sfnt), 0xB1B0AFBA);
    });

    test('out-of-range slice throws RangeError', () {
      expect(
        () => font.tableChecksum(buf, offset: 4000, length: 200),
        throwsRangeError,
      );
    });
  });

  group('rejects undecodable input with null', () {
    test('wrong signature / empty / truncated', () {
      expect(font.woff2ToSfnt(Uint8List(0)), isNull);
      expect(font.woff2ToSfnt(Uint8List.fromList('OTTO'.codeUnits)), isNull);
      final ByteData header = ByteData(48)..setUint32(0, 0x774F4632);
      expect(font.woff2ToSfnt(header.buffer.asUint8List()), isNull);
    });

    test('corrupted Brotli stream', () {
      final Uint8List woff2 = File(
        '$_fontDir/fixtures/Roboto-Regular-hmtx.woff2',
      ).readAsBytesSync();
      final Uint8List broken = Uint8List.fromList(woff2);
      for (int i = broken.length ~/ 2; i < broken.length; i++) {
        broken[i] ^= 0xA5;
      }
      expect(font.woff2ToSfnt(broken), isNull);
      expect(font.woff2ToSfnt(Uint8List.sublistView(woff2, 0, 200)), isNull);
    });
  });
}
