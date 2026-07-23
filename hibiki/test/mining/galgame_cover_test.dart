import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_cover.dart';
import 'package:image/image.dart' as img;

/// galgame 默认封面（exe 图标提取）纯函数守卫：手工构造最小 PE32（含
/// RT_GROUP_ICON / RT_ICON 资源），验证 [extractExeIconIco] 能选出最大
/// 图标并重组为 `image` 包可解码的 .ico；畸形输入一律 null 不抛。
void main() {
  group('extractExeIconIco', () {
    test('提取唯一图标并重组为可解码 ico', () {
      final Uint8List png = _pngBytes(width: 4, height: 4);
      final Uint8List pe = _buildTestPe(<_TestIcon>[
        _TestIcon(id: 1, width: 4, height: 4, bitCount: 32, bytes: png),
      ]);
      final Uint8List? ico = extractExeIconIco(_readerFor(pe));
      expect(ico, isNotNull);
      final img.Image? decoded = img.decodeIco(ico!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 4);
      expect(decoded.height, 4);
    });

    test('多尺寸图标组选面积最大的条目', () {
      final Uint8List small = _pngBytes(width: 4, height: 4);
      final Uint8List big = _pngBytes(width: 8, height: 8);
      final Uint8List pe = _buildTestPe(<_TestIcon>[
        _TestIcon(id: 1, width: 4, height: 4, bitCount: 32, bytes: small),
        _TestIcon(id: 2, width: 8, height: 8, bitCount: 32, bytes: big),
      ]);
      final Uint8List? ico = extractExeIconIco(_readerFor(pe));
      expect(ico, isNotNull);
      final img.Image? decoded = img.decodeIco(ico!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 8);
    });

    test('非 PE 字节返回 null 不抛', () {
      expect(extractExeIconIco(_readerFor(Uint8List(0))), isNull);
      expect(
        extractExeIconIco(_readerFor(Uint8List.fromList(<int>[1, 2, 3]))),
        isNull,
      );
      final Uint8List junk = Uint8List(4096);
      junk[0] = 0x4D;
      junk[1] = 0x5A; // MZ 但 PE 头指向垃圾
      expect(extractExeIconIco(_readerFor(junk)), isNull);
    });

    test('无图标资源的 PE 返回 null', () {
      final Uint8List pe = _buildTestPe(const <_TestIcon>[]);
      expect(extractExeIconIco(_readerFor(pe)), isNull);
    });
  });

  group('封面文件名与类型判定', () {
    test('auto/custom 命名与 isGalgameAutoCover 一致', () {
      expect(galgameAutoCoverName('42'), '42.auto.png');
      expect(galgameCustomCoverName('42', '.jpg'), '42.custom.jpg');
      expect(isGalgameAutoCover(r'D:\data\game_covers\42.auto.png'), isTrue);
      expect(isGalgameAutoCover(r'D:\data\game_covers\42.AUTO.PNG'), isTrue);
      expect(isGalgameAutoCover(r'D:\data\game_covers\42.custom.jpg'), isFalse);
      expect(isGalgameAutoCover(r'D:\somewhere\poster.png'), isFalse);
    });
  });
}

/// 生成 [width]x[height] 的纯色 PNG 字节（作 ico 的 PNG 压缩条目）。
Uint8List _pngBytes({required int width, required int height}) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgba8(200, 40, 40, 255));
  return img.encodePng(image);
}

/// 把整段字节适配成 [ExeByteReader]（越界返回短读，与真实文件语义一致）。
ExeByteReader _readerFor(Uint8List bytes) {
  return (int offset, int length) {
    if (offset < 0 || offset >= bytes.length || length <= 0) {
      return Uint8List(0);
    }
    final int end =
        (offset + length > bytes.length) ? bytes.length : offset + length;
    return Uint8List.sublistView(bytes, offset, end);
  };
}

class _TestIcon {
  const _TestIcon({
    required this.id,
    required this.width,
    required this.height,
    required this.bitCount,
    required this.bytes,
  });

  final int id;
  final int width;
  final int height;
  final int bitCount;
  final Uint8List bytes;
}

/// 手工构造最小 PE32：DOS 头 + PE 头 + 224 字节可选头（资源目录指向 0x1000）+
/// 单节区 `.rsrc`（文件偏移 0x200）。资源树：root → {RT_ICON, RT_GROUP_ICON}
/// → id → language → data entry。icons 为空时生成**无资源目录**的 PE。
Uint8List _buildTestPe(List<_TestIcon> icons) {
  const int peOffset = 0x40;
  const int optSize = 224; // 标准 PE32 可选头
  const int rsrcVa = 0x1000;
  const int rsrcRaw = 0x200;
  final int n = icons.length;

  // ---- .rsrc 布局（相对段起点） ----
  // root(16+2*8) → iconNames(16+n*8) → groupNames(16+8) → n 个 iconLang(24)
  // → groupLang(24) → n 个 iconDataEntry(16) → groupDataEntry(16) → 载荷。
  const int rootOff = 0;
  const int iconNamesOff = rootOff + 16 + 2 * 8;
  final int groupNamesOff = iconNamesOff + 16 + n * 8;
  final int iconLangOff0 = groupNamesOff + 16 + 8;
  final int groupLangOff = iconLangOff0 + n * 24;
  final int iconDataEntryOff0 = groupLangOff + 24;
  final int groupDataEntryOff = iconDataEntryOff0 + n * 16;
  int payloadOff = groupDataEntryOff + 16;

  final List<int> iconPayloadOffs = <int>[];
  for (final _TestIcon icon in icons) {
    iconPayloadOffs.add(payloadOff);
    payloadOff += icon.bytes.length;
  }
  final int groupPayloadOff = payloadOff;
  final int groupPayloadLen = 6 + n * 14;
  final int rsrcSize = groupPayloadOff + groupPayloadLen;

  final Uint8List rsrc = Uint8List(rsrcSize);
  void ru16(int off, int v) {
    rsrc[off] = v & 0xFF;
    rsrc[off + 1] = (v >> 8) & 0xFF;
  }

  void ru32(int off, int v) {
    ru16(off, v & 0xFFFF);
    ru16(off + 2, (v >> 16) & 0xFFFF);
  }

  // root：2 个 id 条目（RT_ICON=3、RT_GROUP_ICON=14，均指子目录）。
  ru16(rootOff + 14, 2);
  ru32(rootOff + 16, 3);
  ru32(rootOff + 20, 0x80000000 | iconNamesOff);
  ru32(rootOff + 24, 14);
  ru32(rootOff + 28, 0x80000000 | groupNamesOff);

  // RT_ICON name 层：每个图标 id → language 子目录。
  ru16(iconNamesOff + 14, n);
  for (int i = 0; i < n; i++) {
    ru32(iconNamesOff + 16 + i * 8, icons[i].id);
    ru32(iconNamesOff + 20 + i * 8, 0x80000000 | (iconLangOff0 + i * 24));
  }

  // RT_GROUP_ICON name 层：单组 id=100。
  ru16(groupNamesOff + 14, 1);
  ru32(groupNamesOff + 16, 100);
  ru32(groupNamesOff + 20, 0x80000000 | groupLangOff);

  // language 层：lang 0 → data entry（无子目录位）。
  for (int i = 0; i < n; i++) {
    final int off = iconLangOff0 + i * 24;
    ru16(off + 14, 1);
    ru32(off + 16, 0);
    ru32(off + 20, iconDataEntryOff0 + i * 16);
  }
  ru16(groupLangOff + 14, 1);
  ru32(groupLangOff + 16, 0);
  ru32(groupLangOff + 20, groupDataEntryOff);

  // data entry：RVA 指向载荷。
  for (int i = 0; i < n; i++) {
    final int off = iconDataEntryOff0 + i * 16;
    ru32(off, rsrcVa + iconPayloadOffs[i]);
    ru32(off + 4, icons[i].bytes.length);
  }
  ru32(groupDataEntryOff, rsrcVa + groupPayloadOff);
  ru32(groupDataEntryOff + 4, groupPayloadLen);

  // 图标载荷 + GRPICONDIR。
  for (int i = 0; i < n; i++) {
    rsrc.setRange(
      iconPayloadOffs[i],
      iconPayloadOffs[i] + icons[i].bytes.length,
      icons[i].bytes,
    );
  }
  ru16(groupPayloadOff + 2, 1); // idType = icon
  ru16(groupPayloadOff + 4, n);
  for (int i = 0; i < n; i++) {
    final int off = groupPayloadOff + 6 + i * 14;
    rsrc[off] = icons[i].width == 256 ? 0 : icons[i].width;
    rsrc[off + 1] = icons[i].height == 256 ? 0 : icons[i].height;
    ru16(off + 4, 1); // planes
    ru16(off + 6, icons[i].bitCount);
    ru32(off + 8, icons[i].bytes.length);
    ru16(off + 12, icons[i].id);
  }

  // ---- 整文件拼装 ----
  final Uint8List file = Uint8List(rsrcRaw + rsrcSize);
  void fu16(int off, int v) {
    file[off] = v & 0xFF;
    file[off + 1] = (v >> 8) & 0xFF;
  }

  void fu32(int off, int v) {
    fu16(off, v & 0xFFFF);
    fu16(off + 2, (v >> 16) & 0xFFFF);
  }

  file[0] = 0x4D; // 'M'
  file[1] = 0x5A; // 'Z'
  fu32(0x3C, peOffset);
  file[peOffset] = 0x50; // 'P'
  file[peOffset + 1] = 0x45; // 'E'
  fu16(peOffset + 6, 1); // NumberOfSections
  fu16(peOffset + 20, optSize);
  const int optOff = peOffset + 24;
  fu16(optOff, 0x10B); // PE32
  fu32(optOff + 92, 16); // NumberOfRvaAndSizes
  if (icons.isNotEmpty) {
    fu32(optOff + 96 + 2 * 8, rsrcVa); // 资源目录 RVA
    fu32(optOff + 96 + 2 * 8 + 4, rsrcSize);
  }
  const int secOff = optOff + optSize;
  fu32(secOff + 8, rsrcSize); // VirtualSize
  fu32(secOff + 12, rsrcVa); // VirtualAddress
  fu32(secOff + 16, rsrcSize); // SizeOfRawData
  fu32(secOff + 20, rsrcRaw); // PointerToRawData
  file.setRange(rsrcRaw, rsrcRaw + rsrcSize, rsrc);
  return file;
}
