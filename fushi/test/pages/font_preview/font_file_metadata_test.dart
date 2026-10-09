import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/font_preview/font_file_metadata.dart';

/// 拼一个最小 sfnt：表目录 + OS/2（v1，带 code page）+ post + 可选 fvar。
Uint8List _buildSfnt({
  required int weight,
  required int codePages,
  bool fixedPitch = false,
  int panoseSerif = 0,
  (int, int)? wghtAxis,
}) {
  final List<(int, Uint8List)> tables = <(int, Uint8List)>[];
  final ByteData os2 = ByteData(86);
  os2.setUint16(0, 1); // version
  os2.setUint16(4, weight);
  os2.setUint8(32, panoseSerif == 0 ? 0 : 2); // bFamilyType = Latin text
  os2.setUint8(33, panoseSerif);
  os2.setUint32(78, codePages);
  tables.add((0x4F532F32, os2.buffer.asUint8List()));
  final ByteData post = ByteData(32);
  post.setUint32(12, fixedPitch ? 1 : 0);
  tables.add((0x706F7374, post.buffer.asUint8List()));
  if (wghtAxis != null) {
    final ByteData fvar = ByteData(16 + 20);
    fvar.setUint16(4, 16); // axesArrayOffset
    fvar.setUint16(8, 1); // axisCount
    fvar.setUint16(10, 20); // axisSize
    fvar.setUint32(16, 0x77676874); // 'wght'
    fvar.setInt32(20, wghtAxis.$1 << 16);
    fvar.setInt32(24, 400 << 16);
    fvar.setInt32(28, wghtAxis.$2 << 16);
    tables.add((0x66766172, fvar.buffer.asUint8List()));
  }
  final int dirSize = 12 + tables.length * 16;
  final BytesBuilder out = BytesBuilder();
  final ByteData head = ByteData(dirSize);
  head.setUint32(0, 0x00010000);
  head.setUint16(4, tables.length);
  int offset = dirSize;
  for (int i = 0; i < tables.length; i++) {
    final (int tag, Uint8List data) = tables[i];
    head.setUint32(12 + i * 16, tag);
    head.setUint32(12 + i * 16 + 8, offset);
    head.setUint32(12 + i * 16 + 12, data.length);
    offset += data.length;
  }
  out.add(head.buffer.asUint8List());
  for (final (int _, Uint8List data) in tables) {
    out.add(data);
  }
  return out.toBytes();
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('font_meta_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<FontFileMetadata?> read(String name, Uint8List bytes) async {
    final File file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return readFontFileMetadata(file.path);
  }

  test('静态 TTF：字重、JIS code page、PANOSE 衬线', () async {
    final FontFileMetadata? meta = await read(
      'mincho.ttf',
      _buildSfnt(weight: 700, codePages: 1 << 17, panoseSerif: 3),
    );
    expect(meta, isNotNull);
    expect(meta!.format, 'TTF');
    expect(meta.weights, <int>[700]);
    expect(meta.weightCount, 1);
    expect(meta.japanese, isTrue);
    expect(meta.simplifiedChinese, isFalse);
    expect(meta.styleClass, FontStyleClass.serif);
    expect(meta.sizeBytes, greaterThan(0));
  });

  test('可变字体：wght 轴范围换成标准字重档', () async {
    final FontFileMetadata? meta = await read(
      'var.ttf',
      _buildSfnt(weight: 400, codePages: 1 << 18, wghtAxis: (100, 900)),
    );
    expect(meta!.variableWeightRange, (100, 900));
    expect(meta.weightCount, 9);
    expect(meta.displayWeights.first, 100);
    expect(meta.simplifiedChinese, isTrue);
  });

  test('post.isFixedPitch → 等宽', () async {
    final FontFileMetadata? meta = await read(
      'mono.otf',
      _buildSfnt(weight: 400, codePages: 0, fixedPitch: true),
    );
    expect(meta!.format, 'OTF');
    expect(meta.styleClass, FontStyleClass.monospace);
  });

  test('读不出表时按名字推断语言与风格', () {
    final FontLibraryTraits ja = fontLibraryTraitsFor(name: 'Yu Mincho');
    expect(ja.japanese, isTrue);
    expect(ja.styleClass, FontStyleClass.serif);

    final FontLibraryTraits zh = fontLibraryTraitsFor(name: 'Noto Sans SC');
    expect(zh.chinese, isTrue);
    expect(zh.styleClass, FontStyleClass.sansSerif);

    final FontLibraryTraits mono = fontLibraryTraitsFor(name: 'JetBrains Mono');
    expect(mono.styleClass, FontStyleClass.monospace);

    // 系统清单给出的日文判定优先于名字。
    expect(
      fontLibraryTraitsFor(
        name: 'Arial',
        systemSupportsJapanese: true,
      ).japanese,
      isTrue,
    );
  });

  test('筛选：来源与特征', () {
    const FontLibraryTraits traits = FontLibraryTraits(
      japanese: true,
      chinese: false,
      styleClass: FontStyleClass.serif,
    );
    bool match(FontLibraryFilter f, {bool isFile = true}) =>
        fontLibraryFilterMatches(f, isFile: isFile, traits: traits);
    expect(match(FontLibraryFilter.all), isTrue);
    expect(match(FontLibraryFilter.imported), isTrue);
    expect(match(FontLibraryFilter.system), isFalse);
    expect(match(FontLibraryFilter.system, isFile: false), isTrue);
    expect(match(FontLibraryFilter.japanese), isTrue);
    expect(match(FontLibraryFilter.chinese), isFalse);
    expect(match(FontLibraryFilter.serif), isTrue);
    expect(match(FontLibraryFilter.sansSerif), isFalse);
  });
}
