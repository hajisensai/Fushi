import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show FileImage;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:hibiki/src/storage/app_paths.dart';

/// galgame 游戏库封面：默认封面（从游戏 exe 的 PE 资源里提取最大图标）与
/// 自定义封面（用户选图拷贝进 app 数据目录）的生成与落盘。
///
/// 默认封面走**纯 Dart PE 解析**（DOS→PE→资源目录→RT_GROUP_ICON/RT_ICON），
/// 不加原生依赖；ICO→PNG 解码复用既有 `image` 包（其 IcoDecoder 同时支持
/// PNG 压缩条目与经典 DIB 条目）。任何一步失败都返回 null 回退占位图标，
/// 绝不因封面失败阻塞添加/启动（Never break）。
///
/// 封面文件统一落 [AppPaths.gameCoversDirectory]（`<documents>/game_covers`），
/// 文件名由条目 id 派生：自动封面 `<id>.auto.png`、自定义封面 `<id>.custom.<ext>`，
/// 靠后缀区分渲染方式（自动=小图标用 contain，自定义=海报图用 cover）。

/// 按需读取字节段的回调：从 [offset] 起读至多 [length] 字节（可短读）。
/// PE 解析只碰头部与 `.rsrc` 段，用它避免把上百 MB 的加壳 exe 整个读进内存。
typedef ExeByteReader = Uint8List Function(int offset, int length);

/// 资源类型常量（PE 资源目录第一层 id）。
const int _kRtIcon = 3;
const int _kRtGroupIcon = 14;

/// 单条 PE 节区头里参与 RVA→文件偏移换算的三元组。
class _PeSection {
  const _PeSection(this.virtualAddress, this.virtualSize, this.rawPointer);

  final int virtualAddress;
  final int virtualSize;
  final int rawPointer;
}

/// 从 PE 可执行文件中提取「最大最清晰」的图标，重组为标准 .ico 文件字节。
/// 解析失败 / 无图标资源 / 结构异常一律返回 null（调用方回退默认占位）。
///
/// 纯函数（IO 由 [readAt] 注入），便于用手工构造的最小 PE 做单测。
Uint8List? extractExeIconIco(ExeByteReader readAt) {
  try {
    return _extractExeIconIco(readAt);
  } catch (_) {
    // 越界 / 结构损坏 / 恶意畸形文件：一律当「无图标」处理。
    return null;
  }
}

Uint8List? _extractExeIconIco(ExeByteReader readAt) {
  // ---- DOS 头 → PE 头 ----
  final Uint8List dos = readAt(0, 0x40);
  if (dos.length < 0x40 || dos[0] != 0x4D || dos[1] != 0x5A) {
    return null; // 无 'MZ'
  }
  final int peOffset = _u32(dos, 0x3C);
  final Uint8List pe = readAt(peOffset, 24);
  if (pe.length < 24 ||
      pe[0] != 0x50 ||
      pe[1] != 0x45 ||
      pe[2] != 0 ||
      pe[3] != 0) {
    return null; // 无 'PE\0\0'
  }
  final int numberOfSections = _u16(pe, 6);
  final int sizeOfOptionalHeader = _u16(pe, 20);
  final int optOffset = peOffset + 24;
  final Uint8List opt = readAt(optOffset, sizeOfOptionalHeader);
  if (opt.length < 96) return null;

  // ---- 可选头：区分 PE32 / PE32+，取资源数据目录（index 2） ----
  final int magic = _u16(opt, 0);
  final int dataDirsOffset;
  final int numRvaOffset;
  if (magic == 0x10B) {
    numRvaOffset = 92;
    dataDirsOffset = 96;
  } else if (magic == 0x20B) {
    numRvaOffset = 108;
    dataDirsOffset = 112;
  } else {
    return null;
  }
  if (opt.length < dataDirsOffset + 3 * 8) return null;
  final int numRva = _u32(opt, numRvaOffset);
  if (numRva < 3) return null; // 没有资源目录槽位
  final int resourceRva = _u32(opt, dataDirsOffset + 2 * 8);
  if (resourceRva == 0) return null;

  // ---- 节区表：RVA→文件偏移 ----
  final int sectionsOffset = optOffset + sizeOfOptionalHeader;
  final Uint8List sectionTable = readAt(sectionsOffset, numberOfSections * 40);
  if (sectionTable.length < numberOfSections * 40) return null;
  final List<_PeSection> sections = <_PeSection>[
    for (int i = 0; i < numberOfSections; i++)
      _PeSection(
        _u32(sectionTable, i * 40 + 12),
        // 取 VirtualSize 与 SizeOfRawData 的较大者作段跨度（对齐差异兜底）。
        _u32(sectionTable, i * 40 + 8) > _u32(sectionTable, i * 40 + 16)
            ? _u32(sectionTable, i * 40 + 8)
            : _u32(sectionTable, i * 40 + 16),
        _u32(sectionTable, i * 40 + 20),
      ),
  ];
  int? rvaToOffset(int rva) {
    for (final _PeSection s in sections) {
      if (rva >= s.virtualAddress && rva < s.virtualAddress + s.virtualSize) {
        return s.rawPointer + (rva - s.virtualAddress);
      }
    }
    return null;
  }

  final int? resBase = rvaToOffset(resourceRva);
  if (resBase == null) return null;

  // ---- 资源目录三层遍历（type → name/id → language → data entry） ----
  // 目录/条目偏移均相对资源段起点；高位 0x80000000 表示指向子目录。
  Uint8List dirEntries(int relOffset) {
    final Uint8List head = readAt(resBase + relOffset, 16);
    if (head.length < 16) return Uint8List(0);
    final int count = _u16(head, 12) + _u16(head, 14);
    return readAt(resBase + relOffset + 16, count * 8);
  }

  /// 在 [relOffset] 目录里找 id == [id] 的条目（[id] 为 null 取第一条），
  /// 返回其 OffsetToData 原始值（含子目录高位）。
  int? findEntry(int relOffset, int? id) {
    final Uint8List entries = dirEntries(relOffset);
    for (int i = 0; i * 8 + 8 <= entries.length; i++) {
      final int entryId = _u32(entries, i * 8);
      final int data = _u32(entries, i * 8 + 4);
      if (id == null || entryId == id) return data;
    }
    return null;
  }

  /// 解出某资源 leaf 的 (fileOffset, size)：沿 language 层到 data entry。
  (int, int)? resolveData(int subdirOffset) {
    final int? langEntry = findEntry(subdirOffset & 0x7FFFFFFF, null);
    if (langEntry == null) return null;
    // language 层条目一般直接指 data entry；仍带子目录位就再下钻一层兜底。
    final int dataEntryOffset = (langEntry & 0x80000000) != 0
        ? (findEntry(langEntry & 0x7FFFFFFF, null) ?? -1)
        : langEntry;
    if (dataEntryOffset < 0 || (dataEntryOffset & 0x80000000) != 0) return null;
    final Uint8List dataEntry = readAt(resBase + dataEntryOffset, 16);
    if (dataEntry.length < 16) return null;
    final int dataRva = _u32(dataEntry, 0);
    final int size = _u32(dataEntry, 4);
    final int? off = rvaToOffset(dataRva);
    if (off == null || size <= 0 || size > 16 * 1024 * 1024) return null;
    return (off, size);
  }

  // type 层：先 RT_GROUP_ICON 选出主图标组。
  final int? groupTypeDir = findEntry(0, _kRtGroupIcon);
  if (groupTypeDir == null || (groupTypeDir & 0x80000000) == 0) return null;
  final int? firstGroup = findEntry(groupTypeDir & 0x7FFFFFFF, null);
  if (firstGroup == null || (firstGroup & 0x80000000) == 0) return null;
  final (int, int)? groupLoc = resolveData(firstGroup);
  if (groupLoc == null) return null;
  final Uint8List group = readAt(groupLoc.$1, groupLoc.$2);
  if (group.length < 6 || _u16(group, 2) != 1) return null; // idType 必须是图标

  // ---- GRPICONDIR：挑最大（再比色深）的条目 ----
  final int count = _u16(group, 4);
  int bestScore = -1;
  int bestId = -1;
  Uint8List? bestEntry;
  for (int i = 0; i < count; i++) {
    final int off = 6 + i * 14;
    if (off + 14 > group.length) break;
    final int width = group[off] == 0 ? 256 : group[off];
    final int height = group[off + 1] == 0 ? 256 : group[off + 1];
    final int bitCount = _u16(group, off + 6);
    final int score = width * height * 64 + bitCount;
    if (score > bestScore) {
      bestScore = score;
      bestId = _u16(group, off + 12);
      bestEntry = Uint8List.sublistView(group, off, off + 14);
    }
  }
  if (bestEntry == null || bestId < 0) return null;

  // ---- RT_ICON：按组条目里的资源 id 取真实图像字节 ----
  final int? iconTypeDir = findEntry(0, _kRtIcon);
  if (iconTypeDir == null || (iconTypeDir & 0x80000000) == 0) return null;
  final int? iconNameDir = findEntry(iconTypeDir & 0x7FFFFFFF, bestId);
  if (iconNameDir == null || (iconNameDir & 0x80000000) == 0) return null;
  final (int, int)? iconLoc = resolveData(iconNameDir);
  if (iconLoc == null) return null;
  final Uint8List iconBytes = readAt(iconLoc.$1, iconLoc.$2);
  if (iconBytes.length < iconLoc.$2) return null;

  // ---- 重组单图 .ico：ICONDIR(6) + ICONDIRENTRY(16) + 图像数据 ----
  final BytesBuilder ico = BytesBuilder();
  ico.add(<int>[0, 0, 1, 0, 1, 0]); // reserved=0, type=1(icon), count=1
  final Uint8List entry = Uint8List(16);
  entry[0] = bestEntry[0]; // width
  entry[1] = bestEntry[1]; // height
  entry[2] = bestEntry[2]; // colorCount
  entry[3] = 0; // reserved
  entry[4] = bestEntry[4]; // planes lo
  entry[5] = bestEntry[5]; // planes hi
  entry[6] = bestEntry[6]; // bitCount lo
  entry[7] = bestEntry[7]; // bitCount hi
  _putU32(entry, 8, iconBytes.length); // bytesInRes = 实际字节数
  _putU32(entry, 12, 6 + 16); // imageOffset
  ico.add(entry);
  ico.add(iconBytes);
  return ico.toBytes();
}

/// 从磁盘上的 exe 提取图标 .ico 字节；文件打不开 / 无图标返回 null。
/// 用 [RandomAccessFile] 按需读段，不整读大文件。
Uint8List? extractExeIconIcoFromFile(String exePath) {
  RandomAccessFile? raf;
  try {
    raf = File(exePath).openSync();
    final RandomAccessFile file = raf;
    final int length = file.lengthSync();
    return extractExeIconIco((int offset, int size) {
      if (offset < 0 || offset >= length || size <= 0) return Uint8List(0);
      file.setPositionSync(offset);
      final int capped = size > length - offset ? length - offset : size;
      return file.readSync(capped);
    });
  } catch (_) {
    return null;
  } finally {
    raf?.closeSync();
  }
}

/// 自动封面文件名（exe 图标提取产物，恒 PNG）。
String galgameAutoCoverName(String entryId) => '$entryId.auto.png';

/// 自定义封面文件名（保留原扩展名，统一小写）。
String galgameCustomCoverName(String entryId, String extension) =>
    '$entryId.custom$extension';

/// 该封面路径是否是自动提取的 exe 图标（据文件名后缀判断；用于渲染时选
/// contain（小图标）还是 cover（海报图））。纯函数。
bool isGalgameAutoCover(String coverPath) =>
    p.basename(coverPath).toLowerCase().endsWith('.auto.png');

/// 生成某游戏的自动封面：提取 exe 图标 → 解码 ICO → 编码 PNG → 写入
/// `<documents>/game_covers/<id>.auto.png`。任一步失败返回 null。
Future<String?> generateGalgameAutoCover({
  required String exePath,
  required String entryId,
}) async {
  try {
    final Uint8List? ico = extractExeIconIcoFromFile(exePath);
    if (ico == null) return null;
    final img.Image? icon = img.decodeIco(ico);
    if (icon == null || icon.width <= 0 || icon.height <= 0) return null;
    final Uint8List png = img.encodePng(icon);
    final Directory dir = await AppPaths.gameCoversDirectory();
    await dir.create(recursive: true);
    final String out = p.join(dir.path, galgameAutoCoverName(entryId));
    await File(out).writeAsBytes(png, flush: true);
    // 同路径覆盖写后必须 evict：Image.file 按路径缓存，不清会一直显示旧图
    //（恢复默认封面重新提取时命中）。
    await FileImage(File(out)).evict();
    return out;
  } catch (_) {
    return null;
  }
}

/// 导入用户自选封面图：拷贝进 `<documents>/game_covers/<id>.custom.<ext>`，
/// 并顺手清掉同 id 其它自定义封面文件（换扩展名时不留孤儿）。失败返回 null。
Future<String?> importGalgameCustomCover({
  required String sourcePath,
  required String entryId,
}) async {
  try {
    final String ext = p.extension(sourcePath).toLowerCase();
    if (ext.isEmpty) return null;
    final Directory dir = await AppPaths.gameCoversDirectory();
    await dir.create(recursive: true);
    // 清掉旧自定义封面（可能是别的扩展名）。
    await for (final FileSystemEntity e in dir.list()) {
      final String base = p.basename(e.path).toLowerCase();
      if (e is File &&
          base.startsWith('$entryId.custom'.toLowerCase()) &&
          base != galgameCustomCoverName(entryId, ext).toLowerCase()) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    final String out = p.join(dir.path, galgameCustomCoverName(entryId, ext));
    await File(sourcePath).copy(out);
    // 同扩展名换图落在同一路径：evict 掉 ImageCache 里的旧封面。
    await FileImage(File(out)).evict();
    return out;
  } catch (_) {
    return null;
  }
}

/// best-effort 删除一个封面文件——**仅当**它确实位于 game_covers 目录内
/// （绝不删用户自己目录里的原图）。
Future<void> deleteGalgameCoverFile(String? coverPath) async {
  if (coverPath == null || coverPath.isEmpty) return;
  try {
    final Directory dir = await AppPaths.gameCoversDirectory();
    if (!p.isWithin(dir.path, coverPath)) return;
    final File f = File(coverPath);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

void _putU32(Uint8List b, int o, int v) {
  b[o] = v & 0xFF;
  b[o + 1] = (v >> 8) & 0xFF;
  b[o + 2] = (v >> 16) & 0xFF;
  b[o + 3] = (v >> 24) & 0xFF;
}
