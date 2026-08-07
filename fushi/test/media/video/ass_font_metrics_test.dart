import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/ass_font_metrics.dart';

/// BUG-897：ASS 字号的 libass `ass_face_set_size` 语义（`em = Fontsize × upem / winCell`）
/// 守卫——sfnt 表解析、TTC 多 face、OS/2 缺失回退 hhea、索引优先级与大小写。

/// 组一个最小 sfnt 单 face 字体（head + hhea + [OS/2] + name）。
Uint8List _buildFace({
  int upem = 1000,
  int hheaAsc = 800,
  int hheaDesc = -200,
  int? winAsc = 1100,
  int? winDesc = 300,
  String family = 'TestFam',
}) {
  final bool hasOs2 = winAsc != null && winDesc != null;

  final Uint8List head = Uint8List(54);
  ByteData.sublistView(head).setUint16(18, upem);

  final Uint8List hhea = Uint8List(36);
  ByteData.sublistView(hhea)
    ..setInt16(4, hheaAsc)
    ..setInt16(6, hheaDesc);

  Uint8List? os2;
  if (hasOs2) {
    os2 = Uint8List(96);
    ByteData.sublistView(os2)
      ..setUint16(74, winAsc)
      ..setUint16(76, winDesc);
  }

  // name 表：format 0，一条 Windows(3) Unicode nameID=1 记录，UTF-16BE。
  final List<int> famUtf16 = <int>[];
  for (final int cu in family.codeUnits) {
    famUtf16
      ..add((cu >> 8) & 0xFF)
      ..add(cu & 0xFF);
  }
  final Uint8List name = Uint8List(6 + 12 + famUtf16.length);
  final ByteData nd = ByteData.sublistView(name);
  nd
    ..setUint16(0, 0) // format
    ..setUint16(2, 1) // count
    ..setUint16(4, 6 + 12) // string storage offset
    ..setUint16(6, 3) // platformID Windows
    ..setUint16(8, 1) // encodingID
    ..setUint16(10, 0x409) // languageID
    ..setUint16(12, 1) // nameID Family
    ..setUint16(14, famUtf16.length)
    ..setUint16(16, 0);
  name.setRange(6 + 12, name.length, famUtf16);

  final List<(String, Uint8List)> tables = <(String, Uint8List)>[
    ('head', head),
    ('hhea', hhea),
    if (os2 != null) ('OS/2', os2),
    ('name', name),
  ];
  final int numTables = tables.length;
  final int dirLen = 12 + numTables * 16;
  int total = dirLen;
  for (final (String, Uint8List) t in tables) {
    total += t.$2.length;
  }
  final Uint8List out = Uint8List(total);
  final ByteData od = ByteData.sublistView(out);
  od
    ..setUint32(0, 0x00010000)
    ..setUint16(4, numTables);
  int offset = dirLen;
  for (int i = 0; i < numTables; i++) {
    final (String tag, Uint8List body) = tables[i];
    final int rec = 12 + i * 16;
    od
      ..setUint32(
          rec,
          (tag.codeUnitAt(0) << 24) |
              (tag.codeUnitAt(1) << 16) |
              (tag.codeUnitAt(2) << 8) |
              tag.codeUnitAt(3))
      ..setUint32(rec + 8, offset)
      ..setUint32(rec + 12, body.length);
    out.setRange(offset, offset + body.length, body);
    offset += body.length;
  }
  return out;
}

/// 把若干单 face 字体包成 TTC 容器。
Uint8List _wrapTtc(List<Uint8List> faces) {
  final int headerLen = 12 + faces.length * 4;
  int total = headerLen;
  for (final Uint8List f in faces) {
    total += f.length;
  }
  final Uint8List out = Uint8List(total);
  final ByteData od = ByteData.sublistView(out);
  od
    ..setUint32(0, 0x74746366) // 'ttcf'
    ..setUint32(8, faces.length);
  int offset = headerLen;
  for (int i = 0; i < faces.length; i++) {
    od.setUint32(12 + i * 4, offset);
    out.setRange(offset, offset + faces[i].length, faces[i]);
    // 真 TTC 的表偏移是**文件绝对偏移**：把单 face 的局部表偏移平移到绝对位置。
    final ByteData fd =
        ByteData.sublistView(out, offset, offset + faces[i].length);
    final int numTables = fd.getUint16(4);
    for (int t = 0; t < numTables; t++) {
      final int rec = 12 + t * 16;
      fd.setUint32(rec + 8, fd.getUint32(rec + 8) + offset);
    }
    offset += faces[i].length;
  }
  return out;
}

void main() {
  test('单 face：cellPerEm = (usWinAscent+usWinDescent)/upem（libass 语义）', () {
    final List<SfntFaceCellMetrics> faces = parseSfntCellMetrics(
        _buildFace(upem: 1000, winAsc: 1100, winDesc: 300));
    expect(faces, hasLength(1));
    expect(faces.single.families, contains('TestFam'));
    expect(faces.single.cellPerEm, closeTo(1.4, 1e-9));
  });

  test('无 OS/2：回退 hhea Ascender-Descender（libass mscale=1 分支）', () {
    final List<SfntFaceCellMetrics> faces = parseSfntCellMetrics(_buildFace(
        upem: 2048,
        hheaAsc: 1802,
        hheaDesc: -246,
        winAsc: null,
        winDesc: null));
    expect(faces, hasLength(1));
    expect(faces.single.cellPerEm, closeTo(2048 / 2048, 1e-9));
  });

  test('真实字体数值：Yu Gothic winCell 1.287em（BUG-897 病根量级）', () {
    // Yu Gothic：upem=2048 winAsc=... 合计 2636 → cellPerEm≈1.287（lineGap=1024 不参与，
    // 旧 TextPainter 行高近似会把它算进去得 ≈1.79——字号偏小 20%~40% 的根因）。
    final List<SfntFaceCellMetrics> faces = parseSfntCellMetrics(_buildFace(
        upem: 2048, hheaAsc: 1802, hheaDesc: -455, winAsc: 2000, winDesc: 636));
    expect(faces.single.cellPerEm, closeTo(2636 / 2048, 1e-9));
  });

  test('TTC：逐 face 解析、family 各归各', () {
    final Uint8List ttc = _wrapTtc(<Uint8List>[
      _buildFace(family: 'FamA', winAsc: 1000, winDesc: 0),
      _buildFace(family: 'FamB', winAsc: 1200, winDesc: 300),
    ]);
    final List<SfntFaceCellMetrics> faces = parseSfntCellMetrics(ttc);
    expect(faces, hasLength(2));
    expect(faces[0].families, contains('FamA'));
    expect(faces[0].cellPerEm, closeTo(1.0, 1e-9));
    expect(faces[1].families, contains('FamB'));
    expect(faces[1].cellPerEm, closeTo(1.5, 1e-9));
  });

  test('垃圾字节 / 越界不抛，返回空', () {
    expect(parseSfntCellMetrics(Uint8List(0)), isEmpty);
    expect(parseSfntCellMetrics(Uint8List.fromList(List<int>.filled(64, 0xAB))),
        isEmpty);
  });

  test('cellPerEmFromTables：异常区间（k<=0.5 或 >=4.0）返回 null', () {
    final Uint8List head = Uint8List(54);
    ByteData.sublistView(head).setUint16(18, 1000);
    final Uint8List hhea = Uint8List(36);
    ByteData.sublistView(hhea)
      ..setInt16(4, 100)
      ..setInt16(6, 0); // cell=100 → k=0.1 越界
    expect(
        cellPerEmFromTables(
            head: ByteData.sublistView(head), hhea: ByteData.sublistView(hhea)),
        isNull);
  });

  test('索引：大小写不敏感、内嵌先到先得、revision 递增', () {
    final AssFontCellIndex index = AssFontCellIndex.instance;
    index.debugReset();
    expect(index.revision.value, 0);
    index.registerFontBytes(
        _buildFace(family: 'TestFam', winAsc: 1100, winDesc: 300));
    expect(index.revision.value, 1);
    expect(index.cellPerEmOf('testfam'), closeTo(1.4, 1e-9));
    expect(index.cellPerEmOf('TESTFAM'), closeTo(1.4, 1e-9));
    // 同名再注册（不同数值）不覆盖（先到先得），revision 不再涨。
    index.registerFontBytes(
        _buildFace(family: 'TestFam', winAsc: 2000, winDesc: 0));
    expect(index.revision.value, 1);
    expect(index.cellPerEmOf('testfam'), closeTo(1.4, 1e-9));
    expect(index.cellPerEmOf('nosuch'), isNull);
    index.debugReset();
  });

  test('索引：aliases 把调用方注册名映射到首 face 系数（自定义字体路径）', () {
    final AssFontCellIndex index = AssFontCellIndex.instance;
    index.debugReset();
    index.registerFontBytes(
      _buildFace(family: 'InternalName', winAsc: 1100, winDesc: 300),
      aliases: const <String>['My Custom Font'],
    );
    expect(index.cellPerEmOf('my custom font'), closeTo(1.4, 1e-9));
    expect(index.cellPerEmOf('internalname'), closeTo(1.4, 1e-9));
    index.debugReset();
  });
}
