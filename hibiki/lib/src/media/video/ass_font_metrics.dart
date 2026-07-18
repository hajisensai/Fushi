import 'dart:io';

import 'package:flutter/foundation.dart';

/// ASS 字号语义的**真字体表**实现（BUG-897，对照 libass `ass_font.c::ass_face_set_size`）。
///
/// libass/VSFilter 把 ASS `Fontsize` 解释为字体 **OS/2 win cell 高**（`usWinAscent +
/// usWinDescent`，GDI 字符对齐盒）：先算 `mscale = hheaCell / winCell`，再以
/// `FT_SIZE_REQUEST_TYPE_REAL_DIM`（按 hhea `Ascender - Descender` 定标）请求
/// `Fontsize × mscale`——两处 hheaCell 相消，**净效果 `em = Fontsize × upem / winCell`**。
/// 无 OS/2（或 winCell 无效）时 mscale=1，净效果 `em = Fontsize × upem / hheaCell`。
///
/// 此前渲染层用 [TextPainter] 实测段落自然行高当 cell（`_assFontSizeToEm` 旧近似），但
/// 段落行高**含 hhea lineGap（leading）**：日文系统字体 lineGap 极大（Yu Gothic/Yu Mincho
/// lineGap=0.5em，win cell 1.287em → 自然行高 ≈1.6~1.79em），把字算小 20%~40%，正是用户
/// 报「字号比 mpv 小一截」的根因；MS Gothic（winCell=1.0、lineGap=0）恰好无差，故「有的
/// 字幕对有的不对」。段落 API 无法剥离 leading（SkParagraph 把 leading 折进 ascent/descent），
/// 根治只能像 libass 一样读真字体表——本文件提供 sfnt（ttf/otf/ttc）的 `head`/`hhea`/
/// `OS/2`/`name` 最小解析，产出「family 名（小写）→ cell/em 系数」索引：
/// - [AssFontCellIndex.registerFontBytes]：MKV 内嵌字体注册时同步喂入（字节已在内存，
///   且正是 .ass 点名的字体，优先级最高）；
/// - [AssFontCellIndex.ensureSystemScan]：懒惰后台 isolate 扫描各平台系统字体目录
///   （部分读取，不整读大 TTC）；扫不到/平台受限（iOS 沙箱）时索引为空，渲染层回退
///   旧 TextPainter 近似（诚实降级，行为与历史一致）。
///
/// 渲染层换算：`em = FontsizePx / cellPerEm`（`cellPerEm = winCell/upem`）。

/// sfnt 表 tag 常量。
const int _kTagTtcf = 0x74746366; // 'ttcf'
const int _kTagOtto = 0x4F54544F; // 'OTTO'（CFF/OpenType）
const int _kTagTrue = 0x74727565; // 'true'（旧 Mac TrueType）
const int _kTagHead = 0x68656164; // 'head'
const int _kTagHhea = 0x68686561; // 'hhea'
const int _kTagOs2 = 0x4F532F32; // 'OS/2'
const int _kTagName = 0x6E616D65; // 'name'

/// 单个 sfnt face 的字号换算要素：声明的 family 名集合 + cell/em 系数。
class SfntFaceCellMetrics {
  const SfntFaceCellMetrics({required this.families, required this.cellPerEm});

  /// name 表 nameID 1（Family）与 16（Typographic Family）的全部记录（含各语言本地化名，
  /// 如「游ゴシック」），与 Skia/DirectWrite 家族解析口径一致。
  final Set<String> families;

  /// `cell / upem`：cell 优先 OS/2 `usWinAscent+usWinDescent`（libass/VSFilter 语义），
  /// 缺 OS/2 / winCell 无效时回退 hhea `Ascender - Descender`。
  final double cellPerEm;
}

/// 从 `head`/`hhea`/`OS/2` 表字节算 cell/em 系数（纯函数，libass `ass_face_set_size`
/// 净语义）。表缺失 / 越界 / 结果超出合理区间（(0.5, 4.0)）返回 null（调用方回退近似）。
double? cellPerEmFromTables({
  required ByteData? head,
  required ByteData? hhea,
  ByteData? os2,
}) {
  if (head == null || head.lengthInBytes < 20) return null;
  if (hhea == null || hhea.lengthInBytes < 8) return null;
  final int upem = head.getUint16(18);
  if (upem <= 0) return null;
  // OS/2 usWinAscent(offset 74) + usWinDescent(offset 76)，均为无符号（规范如此）。
  int cell = 0;
  if (os2 != null && os2.lengthInBytes >= 78) {
    cell = os2.getUint16(74) + os2.getUint16(76);
  }
  if (cell <= 0) {
    // 无 OS/2：libass mscale=1，REAL_DIM 按 hhea cell 定标 → 净除数是 hheaCell。
    cell = hhea.getInt16(4) - hhea.getInt16(6);
  }
  if (cell <= 0) return null;
  final double k = cell / upem;
  return (k > 0.5 && k < 4.0) ? k : null;
}

/// 从 `name` 表字节解析 family 名（nameID 1 / 16，各平台各语言记录都收）。
/// 越界 / 非法记录静默跳过（诚实降级）。
Set<String> familyNamesFromNameTable(ByteData? name) {
  final Set<String> out = <String>{};
  if (name == null || name.lengthInBytes < 6) return out;
  final int count = name.getUint16(2);
  final int stringStorage = name.getUint16(4);
  for (int i = 0; i < count; i++) {
    final int rec = 6 + i * 12;
    if (rec + 12 > name.lengthInBytes) break;
    final int platformId = name.getUint16(rec);
    final int nameId = name.getUint16(rec + 6);
    if (nameId != 1 && nameId != 16) continue;
    final int strLen = name.getUint16(rec + 8);
    final int strOff = stringStorage + name.getUint16(rec + 10);
    if (strLen <= 0 || strOff + strLen > name.lengthInBytes) continue;
    final String? decoded = _decodeNameString(platformId, name, strOff, strLen);
    if (decoded != null && decoded.trim().isNotEmpty) out.add(decoded.trim());
  }
  return out;
}

/// name 记录解码：Windows(3)/Unicode(0) 为 UTF-16BE；Mac(1) 等按 Latin1 近似
/// （ASCII 安全；日文 Mac 记录交给 UTF-16 记录兜底）。
String? _decodeNameString(int platformId, ByteData data, int off, int len) {
  try {
    if (platformId == 3 || platformId == 0) {
      if (len.isOdd) return null;
      final StringBuffer sb = StringBuffer();
      for (int i = 0; i + 1 < len; i += 2) {
        sb.writeCharCode(
            (data.getUint8(off + i) << 8) | data.getUint8(off + i + 1));
      }
      return sb.toString();
    }
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < len; i++) {
      sb.writeCharCode(data.getUint8(off + i));
    }
    return sb.toString();
  } catch (_) {
    return null;
  }
}

/// 解析**内存中的** sfnt 字体字节（ttf/otf/ttc）为逐 face 的 [SfntFaceCellMetrics] 列表
/// （纯函数，可单测；MKV 内嵌字体注册路径用）。非法/越界返回已解析到的部分，不抛。
List<SfntFaceCellMetrics> parseSfntCellMetrics(Uint8List bytes) {
  final List<SfntFaceCellMetrics> out = <SfntFaceCellMetrics>[];
  try {
    if (bytes.length < 12) return out;
    final ByteData data = ByteData.sublistView(bytes);
    final int tag = data.getUint32(0);
    final List<int> faceOffsets = <int>[];
    if (tag == _kTagTtcf) {
      final int numFonts = data.getUint32(8);
      if (numFonts <= 0 || numFonts > 64) return out;
      for (int i = 0; i < numFonts; i++) {
        final int offPos = 12 + i * 4;
        if (offPos + 4 > bytes.length) break;
        faceOffsets.add(data.getUint32(offPos));
      }
    } else if (tag == 0x00010000 || tag == _kTagOtto || tag == _kTagTrue) {
      faceOffsets.add(0);
    } else {
      return out;
    }
    for (final int base in faceOffsets) {
      final SfntFaceCellMetrics? face = _parseFaceFromBytes(data, base);
      if (face != null) out.add(face);
    }
  } catch (_) {
    // 非法字体：返回已解析到的部分。
  }
  return out;
}

/// 在整字体字节的 [base] 偏移处解析单 face（表目录 → head/hhea/OS/2/name → 要素）。
SfntFaceCellMetrics? _parseFaceFromBytes(ByteData data, int base) {
  final int length = data.lengthInBytes;
  if (base < 0 || base + 12 > length) return null;
  final int numTables = data.getUint16(base + 4);
  if (numTables <= 0 || numTables > 512) return null;
  ByteData? tableAt(int wantTag) {
    for (int i = 0; i < numTables; i++) {
      final int rec = base + 12 + i * 16;
      if (rec + 16 > length) return null;
      if (data.getUint32(rec) != wantTag) continue;
      final int off = data.getUint32(rec + 8);
      final int len = data.getUint32(rec + 12);
      if (off < 0 || len <= 0 || off + len > length) return null;
      return ByteData.sublistView(
          data.buffer.asUint8List(data.offsetInBytes + off, len));
    }
    return null;
  }

  final double? cellPerEm = cellPerEmFromTables(
    head: tableAt(_kTagHead),
    hhea: tableAt(_kTagHhea),
    os2: tableAt(_kTagOs2),
  );
  if (cellPerEm == null) return null;
  final Set<String> families = familyNamesFromNameTable(tableAt(_kTagName));
  if (families.isEmpty) return null;
  return SfntFaceCellMetrics(families: families, cellPerEm: cellPerEm);
}

/// 各平台系统字体目录（存在性由扫描方判定；iOS 沙箱下不可读 → 空索引 → 渲染层回退近似）。
List<String> systemFontDirectories() {
  try {
    if (Platform.isWindows) {
      final String win = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String? local = Platform.environment['LOCALAPPDATA'];
      return <String>[
        '$win\\Fonts',
        if (local != null) '$local\\Microsoft\\Windows\\Fonts',
      ];
    }
    if (Platform.isAndroid) {
      return const <String>['/system/fonts', '/system/font', '/product/fonts'];
    }
    if (Platform.isMacOS) {
      final String? home = Platform.environment['HOME'];
      return <String>[
        '/System/Library/Fonts',
        '/System/Library/Fonts/Supplemental',
        '/Library/Fonts',
        if (home != null) '$home/Library/Fonts',
      ];
    }
    if (Platform.isIOS) return const <String>['/System/Library/Fonts'];
    if (Platform.isLinux) {
      final String? home = Platform.environment['HOME'];
      return <String>[
        '/usr/share/fonts',
        '/usr/local/share/fonts',
        if (home != null) '$home/.local/share/fonts',
        if (home != null) '$home/.fonts',
      ];
    }
  } catch (_) {
    // Platform 查询异常（测试特殊环境）：返回空。
  }
  return const <String>[];
}

/// isolate 入口：扫描 [dirs] 下全部字体文件，返回「family 名（小写）→ cellPerEm」映射。
/// 部分读取（表目录 + 4 张小表），不把大 TTC 整读进内存。同名 family 先到先得
/// （同族各字重面的 win cell 几乎一致，先到先得足够）。
Future<Map<String, double>> scanSystemFontCellMetrics(List<String> dirs) async {
  final Map<String, double> out = <String, double>{};
  for (final String dir in dirs) {
    try {
      final Directory d = Directory(dir);
      if (!d.existsSync()) continue;
      await for (final FileSystemEntity e
          in d.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final String lower = e.path.toLowerCase();
        if (!lower.endsWith('.ttf') &&
            !lower.endsWith('.otf') &&
            !lower.endsWith('.ttc') &&
            !lower.endsWith('.otc')) {
          continue;
        }
        await _indexFontFile(e, out);
      }
    } catch (_) {
      // 目录不可读（权限/沙箱）：跳过该目录。
    }
  }
  return out;
}

/// 部分读取单个字体文件，把各 face 的 family→cellPerEm 并入 [out]（先到先得）。
Future<void> _indexFontFile(File file, Map<String, double> out) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final int fileLen = await raf.length();
    Future<ByteData?> readAt(int off, int len) async {
      if (off < 0 || len <= 0 || off + len > fileLen) return null;
      await raf!.setPosition(off);
      final Uint8List b = await raf.read(len);
      return b.length == len ? ByteData.sublistView(b) : null;
    }

    final ByteData? header = await readAt(0, 12);
    if (header == null) return;
    final int tag = header.getUint32(0);
    final List<int> faceOffsets = <int>[];
    if (tag == _kTagTtcf) {
      final int numFonts = header.getUint32(8);
      if (numFonts <= 0 || numFonts > 64) return;
      final ByteData? offs = await readAt(12, numFonts * 4);
      if (offs == null) return;
      for (int i = 0; i < numFonts; i++) {
        faceOffsets.add(offs.getUint32(i * 4));
      }
    } else if (tag == 0x00010000 || tag == _kTagOtto || tag == _kTagTrue) {
      faceOffsets.add(0);
    } else {
      return;
    }

    for (final int base in faceOffsets) {
      final ByteData? dirHead = await readAt(base, 12);
      if (dirHead == null) continue;
      final int numTables = dirHead.getUint16(4);
      if (numTables <= 0 || numTables > 512) continue;
      final ByteData? dir = await readAt(base + 12, numTables * 16);
      if (dir == null) continue;
      Future<ByteData?> tableAt(int wantTag, {int maxLen = 1 << 20}) async {
        for (int i = 0; i < numTables; i++) {
          final int rec = i * 16;
          if (dir.getUint32(rec) != wantTag) continue;
          final int off = dir.getUint32(rec + 8);
          final int len = dir.getUint32(rec + 12);
          if (len <= 0 || len > maxLen) return null;
          return readAt(off, len);
        }
        return null;
      }

      final double? cellPerEm = cellPerEmFromTables(
        head: await tableAt(_kTagHead, maxLen: 1024),
        hhea: await tableAt(_kTagHhea, maxLen: 1024),
        os2: await tableAt(_kTagOs2, maxLen: 4096),
      );
      if (cellPerEm == null) continue;
      final Set<String> families =
          familyNamesFromNameTable(await tableAt(_kTagName));
      for (final String family in families) {
        out.putIfAbsent(family.toLowerCase(), () => cellPerEm);
      }
    }
  } catch (_) {
    // 单文件损坏/不可读：跳过。
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

/// compute() 顶层入口（isolate 内跑全量系统扫描）。
Future<Map<String, double>> _scanSystemFontsEntry(List<String> dirs) {
  return scanSystemFontCellMetrics(dirs);
}

/// 进程级「family 名 → cell/em 系数」索引单例。
///
/// 双层：内嵌字体（[registerFontBytes]，MKV attachment——正是 .ass 点名的字体）优先于
/// 系统扫描（[ensureSystemScan]，懒惰、一次、后台 isolate）。任一层更新都 bump
/// [revision]，渲染层监听它清缓存重算（扫描完成前先用旧近似渲染，就绪后自动校正）。
class AssFontCellIndex {
  AssFontCellIndex._();

  static final AssFontCellIndex instance = AssFontCellIndex._();

  /// 索引内容代次；每次内嵌注册 / 系统扫描完成 +1。渲染层监听清 k 缓存。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final Map<String, double> _embedded = <String, double>{};
  Map<String, double> _system = const <String, double>{};
  bool _scanStarted = false;

  /// 测试钩子：重置单例状态（系统扫描标记 / 两层映射 / revision）。
  @visibleForTesting
  void debugReset() {
    _embedded.clear();
    _system = const <String, double>{};
    _scanStarted = false;
    revision.value = 0;
  }

  /// 懒惰踢一次系统字体目录扫描（后台 isolate；幂等）。完成后 bump [revision]。
  /// 失败静默（索引保持空，渲染层继续近似）。
  void ensureSystemScan() {
    if (_scanStarted) return;
    _scanStarted = true;
    final List<String> dirs = systemFontDirectories();
    if (dirs.isEmpty) return;
    compute(_scanSystemFontsEntry, dirs).then((Map<String, double> result) {
      if (result.isEmpty) return;
      _system = result;
      revision.value++;
    }).catchError((Object _) {
      // isolate 失败：保持空索引。
    });
  }

  /// 解析并登记一份内存字体（MKV 内嵌字体 / 用户自定义字体注册路径同步调用）。
  /// [aliases]：调用方额外用来注册进 [FontLoader] 的家族别名（用户自定义字体常用
  /// 自选名而非字体内部名），一并映射到首个 face 的系数。有新 family 时 bump
  /// [revision]。解析失败静默。
  void registerFontBytes(Uint8List bytes,
      {Iterable<String> aliases = const <String>[]}) {
    bool added = false;
    double? firstCellPerEm;
    for (final SfntFaceCellMetrics face in parseSfntCellMetrics(bytes)) {
      firstCellPerEm ??= face.cellPerEm;
      for (final String family in face.families) {
        final String key = family.toLowerCase();
        if (_embedded.containsKey(key)) continue;
        _embedded[key] = face.cellPerEm;
        added = true;
      }
    }
    if (firstCellPerEm != null) {
      for (final String alias in aliases) {
        final String key = alias.toLowerCase();
        if (key.isEmpty || _embedded.containsKey(key)) continue;
        _embedded[key] = firstCellPerEm;
        added = true;
      }
    }
    if (added) revision.value++;
  }

  /// 查 [family]（大小写不敏感）的 cell/em 系数；内嵌层优先。未知返回 null。
  double? cellPerEmOf(String family) {
    final String key = family.toLowerCase();
    return _embedded[key] ?? _system[key];
  }
}
