import 'dart:typed_data';

import 'package:fushi/src/mining/pe_resources.dart';
import 'package:image/image.dart' as img;

/// 从 Windows PE 可执行文件（`.exe` / `.dll`）里**纯 Dart** 解析内嵌图标资源
/// （`RT_ICON`），供游戏库「自动获取封面」在游戏目录里找不到封面图时兜底。
///
/// 为什么不走 native：Win32 的 `ExtractIconEx` / `SHGetFileInfo` 只能拿到 `HICON`，
/// 还要一串 GDI 调用（`GetIconInfo` / `GetDIBits`）才能变成像素，且只有真机能跑、
/// 无法单测。PE 资源树是**纯字节结构**，解析它是确定性纯函数：三端都能跑测试，
/// 合成字节即可覆盖边界（截断 / 非 PE / 无 .rsrc / 多尺寸）。
///
/// 全部入口 **fail-safe**：任何越界、非法结构、解码失败都返回 null / 空列表，
/// 绝不抛给调用方（封面缺失是可接受降级，崩溃不是）。

/// PE 资源里的一个图标条目（已定位到真实字节）。
class PeIconEntry {
  const PeIconEntry({
    required this.width,
    required this.height,
    required this.bitCount,
    required this.isPng,
    required this.bytes,
  });

  /// 像素宽（PNG 取 IHDR，DIB 取 `biWidth`）。
  final int width;

  /// 像素高（DIB 的 `biHeight` 是图像高 + AND 掩码高的两倍，这里已折半还原）。
  final int height;

  /// 位深（PNG 统一记 32；DIB 取 `biBitCount`）。
  final int bitCount;

  /// true = 资源本身就是 PNG（Vista+ 的 256×256 图标常见），可直接落盘。
  final bool isPng;

  /// 图标资源原始字节（PNG 文件字节，或不含文件头的 DIB）。
  final Uint8List bytes;

  /// 面积，用于挑「最大」的一张。
  int get area => width * height;
}

const int _rtIcon = 3;
const List<int> _pngSignature = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A
];

/// 解析 [exeBytes] 里所有 `RT_ICON` 资源；非 PE / 无资源段 / 结构损坏返回空列表。
List<PeIconEntry> parsePeIcons(Uint8List exeBytes) {
  try {
    return _parsePeIconsUnsafe(exeBytes);
  } catch (_) {
    // 任何越界或格式假设不成立：当作「这个 exe 没有可用图标」。
    return const <PeIconEntry>[];
  }
}

/// 取 [exeBytes] 内**面积最大**（并列时位深更高）的图标并归一成 PNG 字节。
///
/// 资源本身是 PNG 时原样返回（零重编码）；是 DIB 时包成单帧 `.ico` 交
/// `package:image` 解码（它已处理 AND 掩码透明与自下而上行序）再编码 PNG。
/// [minSize] 是可用下限：小于它的图标（16/32 px 系统托盘图标）当封面太糊，返回 null。
Uint8List? extractLargestIconPng(Uint8List exeBytes, {int minSize = 48}) {
  final List<PeIconEntry> icons = parsePeIcons(exeBytes);
  if (icons.isEmpty) return null;
  PeIconEntry? best;
  for (final PeIconEntry icon in icons) {
    if (icon.width < minSize || icon.height < minSize) continue;
    if (best == null ||
        icon.area > best.area ||
        (icon.area == best.area && icon.bitCount > best.bitCount)) {
      best = icon;
    }
  }
  if (best == null) return null;
  if (best.isPng) return best.bytes;
  return _dibIconToPng(best);
}

/// DIB 图标 → PNG：包一层最小 `.ico` 容器再走 [img.IcoDecoder]。
///
/// 刻意**只塞这一帧**：`IcoDecoder.decodeImageLargest` 按 ICONDIRENTRY 的宽高字节挑帧，
/// 而 256px 图标在该字段里编码为 0（规范如此），会被它当成最小帧丢掉。我们已经在
/// PE 层知道真实尺寸，自己挑完只交一帧，绕开那个坑。
Uint8List? _dibIconToPng(PeIconEntry icon) {
  try {
    final BytesBuilder builder = BytesBuilder();
    final ByteData header = ByteData(6 + 16);
    header.setUint16(0, 0, Endian.little); // reserved
    header.setUint16(2, 1, Endian.little); // type = icon
    header.setUint16(4, 1, Endian.little); // count = 1
    // ICONDIRENTRY：宽高各占一字节，256 编码为 0（`& 0xFF` 天然满足）。
    header.setUint8(6, icon.width & 0xFF);
    header.setUint8(7, icon.height & 0xFF);
    header.setUint8(8, 0); // colorCount（>=8bpp 时为 0）
    header.setUint8(9, 0); // reserved
    header.setUint16(10, 1, Endian.little); // planes
    header.setUint16(12, icon.bitCount, Endian.little);
    header.setUint32(14, icon.bytes.length, Endian.little);
    header.setUint32(18, 22, Endian.little); // 数据偏移 = 6 + 16
    builder.add(header.buffer.asUint8List());
    builder.add(icon.bytes);
    final img.Image? decoded = img.IcoDecoder().decode(builder.toBytes());
    if (decoded == null) return null;
    return img.encodePng(decoded);
  } catch (_) {
    return null;
  }
}

List<PeIconEntry> _parsePeIconsUnsafe(Uint8List bytes) {
  // 资源树遍历与 RT_VERSION / RT_MANIFEST（转区判定）共用 `pe_resources.dart`；
  // 这里只剩「叶子字节 → 图标条目」这一步。
  final List<PeIconEntry> icons = <PeIconEntry>[];
  for (final PeResourceLeaf leaf in readPeResourceLeaves(bytes, _rtIcon)) {
    final PeIconEntry? icon = _describeIcon(leaf.bytes);
    if (icon != null) icons.add(icon);
  }
  return icons;
}

/// 判定一段图标资源是 PNG 还是 DIB，并读出尺寸/位深；都不像则返回 null。
PeIconEntry? _describeIcon(Uint8List blob) {
  if (blob.length >= 24 && _hasPngSignature(blob)) {
    final ByteData d = ByteData.sublistView(blob);
    return PeIconEntry(
      width: d.getUint32(16), // IHDR width（大端）
      height: d.getUint32(20),
      bitCount: 32,
      isPng: true,
      bytes: Uint8List.fromList(blob),
    );
  }
  if (blob.length < 40) return null;
  final ByteData d = ByteData.sublistView(blob);
  final int headerSize = d.getUint32(0, Endian.little);
  if (headerSize < 40) return null; // 只认 BITMAPINFOHEADER 及其扩展
  final int width = d.getInt32(4, Endian.little);
  final int doubledHeight = d.getInt32(8, Endian.little);
  final int bitCount = d.getUint16(14, Endian.little);
  if (width <= 0 || doubledHeight <= 0) return null;
  return PeIconEntry(
    // 图标 DIB 的高度含 AND 掩码，是真实高度的两倍。
    width: width,
    height: doubledHeight ~/ 2,
    bitCount: bitCount,
    isPng: false,
    bytes: Uint8List.fromList(blob),
  );
}

bool _hasPngSignature(Uint8List blob) {
  for (int i = 0; i < _pngSignature.length; i++) {
    if (blob[i] != _pngSignature[i]) return false;
  }
  return true;
}
