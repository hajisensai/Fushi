import 'dart:typed_data';

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
  final ByteData data = ByteData.sublistView(bytes);
  if (bytes.length < 0x40) return const <PeIconEntry>[];
  if (bytes[0] != 0x4D || bytes[1] != 0x5A) {
    return const <PeIconEntry>[]; // 不是 'MZ'
  }
  final int peOffset = data.getUint32(0x3C, Endian.little);
  if (peOffset <= 0 || peOffset + 24 > bytes.length) {
    return const <PeIconEntry>[];
  }
  if (bytes[peOffset] != 0x50 ||
      bytes[peOffset + 1] != 0x45 ||
      bytes[peOffset + 2] != 0 ||
      bytes[peOffset + 3] != 0) {
    return const <PeIconEntry>[]; // 不是 'PE\0\0'
  }
  final int coff = peOffset + 4;
  final int sectionCount = data.getUint16(coff + 2, Endian.little);
  final int optionalHeaderSize = data.getUint16(coff + 16, Endian.little);
  final int sectionTable = coff + 20 + optionalHeaderSize;
  if (sectionCount <= 0 || sectionTable + sectionCount * 40 > bytes.length) {
    return const <PeIconEntry>[];
  }

  // 找 .rsrc 段：资源树里的所有偏移都相对该段，叶子里的 RVA 也在该段内。
  int rsrcRva = -1;
  int rsrcFileOffset = -1;
  int rsrcSize = 0;
  for (int i = 0; i < sectionCount; i++) {
    final int base = sectionTable + i * 40;
    final String name = String.fromCharCodes(
      bytes.sublist(base, base + 8).takeWhile((int b) => b != 0),
    );
    if (name == '.rsrc') {
      rsrcRva = data.getUint32(base + 12, Endian.little);
      rsrcSize = data.getUint32(base + 16, Endian.little);
      rsrcFileOffset = data.getUint32(base + 20, Endian.little);
      break;
    }
  }
  if (rsrcRva < 0 || rsrcFileOffset < 0 || rsrcFileOffset >= bytes.length) {
    return const <PeIconEntry>[];
  }
  final int rsrcEnd = rsrcFileOffset + rsrcSize > bytes.length
      ? bytes.length
      : rsrcFileOffset + rsrcSize;

  /// 资源段内 RVA → 文件偏移；越界返回 -1。
  int rvaToFile(int rva) {
    final int offset = rva - rsrcRva + rsrcFileOffset;
    if (offset < rsrcFileOffset || offset >= rsrcEnd) return -1;
    return offset;
  }

  /// 读一层资源目录的所有条目：`(id 或 -1, 相对 .rsrc 的偏移, 是否子目录)`。
  List<(int, int, bool)> readDirectory(int relativeOffset) {
    final int dir = rsrcFileOffset + relativeOffset;
    if (dir < rsrcFileOffset || dir + 16 > rsrcEnd) {
      return const <(int, int, bool)>[];
    }
    final int namedCount = data.getUint16(dir + 12, Endian.little);
    final int idCount = data.getUint16(dir + 14, Endian.little);
    final int total = namedCount + idCount;
    final List<(int, int, bool)> out = <(int, int, bool)>[];
    for (int i = 0; i < total; i++) {
      final int entry = dir + 16 + i * 8;
      if (entry + 8 > rsrcEnd) break;
      final int nameField = data.getUint32(entry, Endian.little);
      final int offsetField = data.getUint32(entry + 4, Endian.little);
      final bool isNamed = nameField & 0x80000000 != 0;
      final bool isDirectory = offsetField & 0x80000000 != 0;
      out.add((
        isNamed ? -1 : nameField,
        offsetField & 0x7FFFFFFF,
        isDirectory,
      ));
    }
    return out;
  }

  final List<PeIconEntry> icons = <PeIconEntry>[];
  for (final (int typeId, int typeOffset, bool typeIsDir) in readDirectory(0)) {
    if (typeId != _rtIcon || !typeIsDir) continue;
    // Level 2：每个图标资源 id；Level 3：语言。叶子才是数据条目。
    for (final (int _, int nameOffset, bool nameIsDir)
        in readDirectory(typeOffset)) {
      final List<(int, int, bool)> languages = nameIsDir
          ? readDirectory(nameOffset)
          : <(int, int, bool)>[(0, nameOffset, false)];
      for (final (int _, int leafOffset, bool leafIsDir) in languages) {
        if (leafIsDir) continue;
        final int leaf = rsrcFileOffset + leafOffset;
        if (leaf < rsrcFileOffset || leaf + 8 > rsrcEnd) continue;
        final int dataRva = data.getUint32(leaf, Endian.little);
        final int dataSize = data.getUint32(leaf + 4, Endian.little);
        final int dataOffset = rvaToFile(dataRva);
        if (dataOffset < 0 || dataSize <= 0) continue;
        final int end = dataOffset + dataSize;
        if (end > bytes.length) continue;
        final PeIconEntry? icon =
            _describeIcon(Uint8List.sublistView(bytes, dataOffset, end));
        if (icon != null) icons.add(icon);
      }
    }
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
