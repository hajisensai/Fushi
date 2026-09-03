import 'dart:typed_data';

/// Windows PE（`.exe` / `.dll`）的**纯 Dart** 结构读取：段表与 `.rsrc` 资源树。
///
/// 从 `galgame_exe_icon.dart` 抽出来，因为 RT_ICON（封面兜底）与 RT_VERSION /
/// RT_MANIFEST（转区判定，BUG-2047）走的是同一棵三层资源树；两份遍历只会各自
/// 长出各自的越界 bug。资源树是确定性字节结构，三端都能用合成字节单测。
///
/// 全部入口 **fail-safe**：任何越界、非法结构都返回空列表，绝不抛给调用方。

/// 一个 PE 段（section）头里我们关心的字段。
class PeSection {
  const PeSection({
    required this.name,
    required this.virtualAddress,
    required this.virtualSize,
    required this.rawOffset,
    required this.rawSize,
    required this.characteristics,
  });

  final String name;
  final int virtualAddress;
  final int virtualSize;
  final int rawOffset;
  final int rawSize;

  /// `IMAGE_SECTION_HEADER.Characteristics`。
  final int characteristics;

  /// `IMAGE_SCN_MEM_EXECUTE`：代码段。
  bool get isExecutable => characteristics & 0x20000000 != 0;
}

/// 资源树的一个叶子（已定位到真实字节）。
class PeResourceLeaf {
  const PeResourceLeaf({
    required this.nameId,
    required this.langId,
    required this.bytes,
  });

  /// Level 2 的资源 id；命名资源（高位置 1 的字符串名）记 -1。
  final int nameId;

  /// Level 3 的语言 id（如 0x0409 / 0x0411）；Level 2 直接挂数据时记 0。
  final int langId;

  /// 资源数据（文件字节的视图，不复制）。
  final Uint8List bytes;
}

/// 读 [bytes] 的段表；非 PE / 截断 / 段表越界返回空列表。
List<PeSection> readPeSections(Uint8List bytes) {
  try {
    return _readSectionsUnsafe(bytes);
  } catch (_) {
    return const <PeSection>[];
  }
}

/// 读 [bytes] 里资源类型为 [typeId]（如 RT_ICON=3 / RT_VERSION=16 / RT_MANIFEST=24）
/// 的全部叶子；非 PE / 无 `.rsrc` / 结构损坏返回空列表。
List<PeResourceLeaf> readPeResourceLeaves(Uint8List bytes, int typeId) {
  try {
    return _readLeavesUnsafe(bytes, typeId);
  } catch (_) {
    return const <PeResourceLeaf>[];
  }
}

List<PeSection> _readSectionsUnsafe(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  if (bytes.length < 0x40) return const <PeSection>[];
  if (bytes[0] != 0x4D || bytes[1] != 0x5A) {
    return const <PeSection>[]; // 不是 'MZ'
  }
  final int peOffset = data.getUint32(0x3C, Endian.little);
  if (peOffset <= 0 || peOffset + 24 > bytes.length) {
    return const <PeSection>[];
  }
  if (bytes[peOffset] != 0x50 ||
      bytes[peOffset + 1] != 0x45 ||
      bytes[peOffset + 2] != 0 ||
      bytes[peOffset + 3] != 0) {
    return const <PeSection>[]; // 不是 'PE\0\0'
  }
  final int coff = peOffset + 4;
  final int sectionCount = data.getUint16(coff + 2, Endian.little);
  final int optionalHeaderSize = data.getUint16(coff + 16, Endian.little);
  final int sectionTable = coff + 20 + optionalHeaderSize;
  if (sectionCount <= 0 || sectionTable + sectionCount * 40 > bytes.length) {
    return const <PeSection>[];
  }
  final List<PeSection> out = <PeSection>[];
  for (int i = 0; i < sectionCount; i++) {
    final int base = sectionTable + i * 40;
    final String name = String.fromCharCodes(
      bytes.sublist(base, base + 8).takeWhile((int b) => b != 0),
    );
    out.add(
      PeSection(
        name: name,
        virtualSize: data.getUint32(base + 8, Endian.little),
        virtualAddress: data.getUint32(base + 12, Endian.little),
        rawSize: data.getUint32(base + 16, Endian.little),
        rawOffset: data.getUint32(base + 20, Endian.little),
        characteristics: data.getUint32(base + 36, Endian.little),
      ),
    );
  }
  return out;
}

List<PeResourceLeaf> _readLeavesUnsafe(Uint8List bytes, int typeId) {
  final ByteData data = ByteData.sublistView(bytes);
  // 找 .rsrc 段：资源树里的所有偏移都相对该段，叶子里的 RVA 也在该段内。
  PeSection? rsrc;
  for (final PeSection section in _readSectionsUnsafe(bytes)) {
    if (section.name == '.rsrc') {
      rsrc = section;
      break;
    }
  }
  if (rsrc == null || rsrc.rawOffset >= bytes.length) {
    return const <PeResourceLeaf>[];
  }
  final int rsrcRva = rsrc.virtualAddress;
  final int rsrcFileOffset = rsrc.rawOffset;
  final int rsrcEnd = rsrcFileOffset + rsrc.rawSize > bytes.length
      ? bytes.length
      : rsrcFileOffset + rsrc.rawSize;

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

  final List<PeResourceLeaf> leaves = <PeResourceLeaf>[];
  for (final (int type, int typeOffset, bool typeIsDir) in readDirectory(0)) {
    if (type != typeId || !typeIsDir) continue;
    // Level 2：每个资源 id；Level 3：语言。叶子才是数据条目。
    for (final (int nameId, int nameOffset, bool nameIsDir) in readDirectory(
      typeOffset,
    )) {
      final List<(int, int, bool)> languages = nameIsDir
          ? readDirectory(nameOffset)
          : <(int, int, bool)>[(0, nameOffset, false)];
      for (final (int langId, int leafOffset, bool leafIsDir) in languages) {
        if (leafIsDir) continue;
        final int leaf = rsrcFileOffset + leafOffset;
        if (leaf < rsrcFileOffset || leaf + 8 > rsrcEnd) continue;
        final int dataRva = data.getUint32(leaf, Endian.little);
        final int dataSize = data.getUint32(leaf + 4, Endian.little);
        final int dataOffset = rvaToFile(dataRva);
        if (dataOffset < 0 || dataSize <= 0) continue;
        final int end = dataOffset + dataSize;
        if (end > bytes.length) continue;
        leaves.add(
          PeResourceLeaf(
            nameId: nameId,
            langId: langId,
            bytes: Uint8List.sublistView(bytes, dataOffset, end),
          ),
        );
      }
    }
  }
  return leaves;
}
