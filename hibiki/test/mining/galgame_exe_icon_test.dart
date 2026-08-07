import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_exe_icon.dart';
import 'package:image/image.dart' as img;

/// PE 图标提取（游戏库「自动获取封面」的兜底源）的纯字节测试。
///
/// 用**合成 PE** 覆盖：多尺寸挑最大、PNG 直通、DIB→PNG 重编码、minSize 过滤，
/// 以及三类坏输入（非 PE / 无 .rsrc / 资源段声明越界）必须 fail-safe 不抛。
void main() {
  group('parsePeIcons', () {
    test('解析出所有 RT_ICON 并读对尺寸（PNG 与 DIB 混合）', () {
      final Uint8List png = _png(64, 64);
      final Uint8List dib = _dib(32, 32);
      final List<PeIconEntry> icons =
          parsePeIcons(_buildPeWithIcons(<Uint8List>[dib, png]));

      expect(icons, hasLength(2));
      final PeIconEntry dibEntry =
          icons.firstWhere((PeIconEntry e) => !e.isPng);
      final PeIconEntry pngEntry = icons.firstWhere((PeIconEntry e) => e.isPng);
      expect(dibEntry.width, 32);
      // DIB 的 biHeight 含 AND 掩码（写入 64），解析后应还原成 32。
      expect(dibEntry.height, 32);
      expect(pngEntry.width, 64);
      expect(pngEntry.height, 64);
    });

    test('非 PE / 截断 / 无 .rsrc 都返回空列表，不抛', () {
      expect(parsePeIcons(Uint8List.fromList(<int>[1, 2, 3])), isEmpty);
      expect(parsePeIcons(Uint8List(0)), isEmpty);
      expect(parsePeIcons(_buildPeWithIcons(<Uint8List>[], omitRsrc: true)),
          isEmpty);

      // .rsrc 声明的大小远超文件实际长度：越界读必须被夹住而不是抛出。
      final Uint8List truncated =
          _buildPeWithIcons(<Uint8List>[_dib(32, 32)], inflateRsrcSize: true);
      expect(parsePeIcons(truncated), isNotNull);
    });
  });

  group('extractLargestIconPng', () {
    test('多尺寸时取面积最大的一张，PNG 资源原样直通', () {
      final Uint8List png = _png(128, 128);
      final Uint8List bytes =
          _buildPeWithIcons(<Uint8List>[_dib(32, 32), png, _dib(48, 48)]);

      final Uint8List? out = extractLargestIconPng(bytes);
      expect(out, isNotNull);
      // 128×128 的 PNG 资源最大，且不该被重新编码。
      expect(out, equals(png));
    });

    test('只有 DIB 图标时重编码成可解码的 PNG', () {
      final Uint8List bytes = _buildPeWithIcons(<Uint8List>[_dib(64, 64)]);

      final Uint8List? out = extractLargestIconPng(bytes);
      expect(out, isNotNull);
      final img.Image? decoded = img.decodePng(out!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 64);
      expect(decoded.height, 64);
    });

    test('所有图标都小于 minSize 时返回 null（不拿 32px 托盘图标当封面）', () {
      final Uint8List bytes =
          _buildPeWithIcons(<Uint8List>[_dib(16, 16), _dib(32, 32)]);
      expect(extractLargestIconPng(bytes, minSize: 48), isNull);
      // 放宽下限后同一份字节应能取到 32×32。
      expect(extractLargestIconPng(bytes, minSize: 16), isNotNull);
    });
  });
}

/// 生成一张真实可解码的 PNG（纯色）。
Uint8List _png(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(120, 90, 200));
  return img.encodePng(image);
}

/// 生成一段 32bpp 的图标 DIB：BITMAPINFOHEADER + BGRA 像素 + AND 掩码。
///
/// 图标 DIB 的 `biHeight` 按规范写成真实高度的两倍（图像 + 掩码）。
Uint8List _dib(int width, int height) {
  final int pixelBytes = width * height * 4;
  final int maskRowBytes = (((width + 31) ~/ 32)) * 4;
  final int maskBytes = maskRowBytes * height;
  final Uint8List out = Uint8List(40 + pixelBytes + maskBytes);
  final ByteData view = ByteData.sublistView(out);
  view.setUint32(0, 40, Endian.little); // biSize
  view.setInt32(4, width, Endian.little); // biWidth
  view.setInt32(8, height * 2, Endian.little); // biHeight（含掩码）
  view.setUint16(12, 1, Endian.little); // biPlanes
  view.setUint16(14, 32, Endian.little); // biBitCount
  for (int i = 0; i < pixelBytes; i += 4) {
    out[40 + i] = 200; // B
    out[40 + i + 1] = 90; // G
    out[40 + i + 2] = 120; // R
    out[40 + i + 3] = 255; // A
  }
  return out;
}

/// 组装一个最小但结构合法的 PE：DOS 头 + PE 签名 + COFF 头 + 一个 `.rsrc` 段，
/// 段内是三层资源树（type=RT_ICON → 每图标一个 id → 语言叶子）。
///
/// [omitRsrc] 把段名改成 `.text`（模拟没有资源段的 exe）；[inflateRsrcSize] 把段
/// 声明大小写成远超文件长度的值（模拟被截断/损坏的文件）。
Uint8List _buildPeWithIcons(
  List<Uint8List> icons, {
  bool omitRsrc = false,
  bool inflateRsrcSize = false,
}) {
  const int peOffset = 0x80;
  const int optionalHeaderSize = 0xE0;
  const int sectionTableOffset = peOffset + 4 + 20 + optionalHeaderSize;
  const int rsrcFileOffset = sectionTableOffset + 40;
  const int rsrcRva = 0x1000;

  // 资源段布局：L1 目录 → L2 目录 → 每个图标一层语言目录 → 叶子 → 数据。
  final int count = icons.length;
  const int l1 = 0;
  const int l1Size = 16 + 8; // 只有 RT_ICON 一个类型条目
  const int l2 = l1 + l1Size;
  final int l2Size = 16 + 8 * count;
  final int langBase = l2 + l2Size;
  const int langSize = 16 + 8; // 每个图标一个语言条目
  final int leafBase = langBase + langSize * count;
  const int leafSize = 16;
  final int dataBase = leafBase + leafSize * count;

  int dataCursor = dataBase;
  final List<int> dataOffsets = <int>[];
  for (final Uint8List icon in icons) {
    dataOffsets.add(dataCursor);
    dataCursor += icon.length;
  }
  final int rsrcSize = dataCursor;

  final Uint8List out = Uint8List(rsrcFileOffset + rsrcSize);
  final ByteData view = ByteData.sublistView(out);

  // DOS 头：'MZ' + e_lfanew。
  out[0] = 0x4D;
  out[1] = 0x5A;
  view.setUint32(0x3C, peOffset, Endian.little);
  // PE 签名 + COFF 头。
  out[peOffset] = 0x50;
  out[peOffset + 1] = 0x45;
  view.setUint16(peOffset + 4 + 2, 1, Endian.little); // NumberOfSections
  view.setUint16(
      peOffset + 4 + 16, optionalHeaderSize, Endian.little); // SizeOfOptional

  // 段头。
  final String sectionName = omitRsrc ? '.text' : '.rsrc';
  for (int i = 0; i < sectionName.length; i++) {
    out[sectionTableOffset + i] = sectionName.codeUnitAt(i);
  }
  view.setUint32(
      sectionTableOffset + 8, rsrcSize, Endian.little); // VirtualSize
  view.setUint32(sectionTableOffset + 12, rsrcRva, Endian.little);
  view.setUint32(
    sectionTableOffset + 16,
    inflateRsrcSize ? rsrcSize + 0x100000 : rsrcSize,
    Endian.little,
  );
  view.setUint32(sectionTableOffset + 20, rsrcFileOffset, Endian.little);

  int abs(int relative) => rsrcFileOffset + relative;

  // L1：一个 RT_ICON(3) 类型条目，指向 L2 子目录。
  view.setUint16(abs(l1) + 14, 1, Endian.little); // NumberOfIdEntries
  view.setUint32(abs(l1) + 16, 3, Endian.little); // type id = RT_ICON
  view.setUint32(abs(l1) + 20, 0x80000000 | l2, Endian.little);

  // L2：每个图标一个 id 条目，指向自己的语言目录。
  view.setUint16(abs(l2) + 14, count, Endian.little);
  for (int i = 0; i < count; i++) {
    final int entry = abs(l2) + 16 + i * 8;
    view.setUint32(entry, i + 1, Endian.little); // 图标资源 id
    view.setUint32(
      entry + 4,
      0x80000000 | (langBase + langSize * i),
      Endian.little,
    );
    // 语言目录：一个条目指向叶子（无高位 = 数据条目）。
    final int lang = abs(langBase + langSize * i);
    view.setUint16(lang + 14, 1, Endian.little);
    view.setUint32(lang + 16, 1033, Endian.little); // LANG_ENGLISH
    view.setUint32(lang + 20, leafBase + leafSize * i, Endian.little);
    // 叶子：数据 RVA + 大小。
    final int leaf = abs(leafBase + leafSize * i);
    view.setUint32(leaf, rsrcRva + dataOffsets[i], Endian.little);
    view.setUint32(leaf + 4, icons[i].length, Endian.little);
    out.setRange(
        abs(dataOffsets[i]), abs(dataOffsets[i]) + icons[i].length, icons[i]);
  }
  return out;
}
