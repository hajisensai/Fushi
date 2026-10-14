import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 字形风格大类（字体库筛选用）。
enum FontStyleClass { serif, sansSerif, monospace }

/// 字体文件里**读得出来**的元数据：格式、大小、字重、语言覆盖、风格大类。
///
/// 只读 sfnt 表头与 `OS/2` / `post` / `fvar` 三张小表（随机读，不整文件载入——
/// CJK 字体动辄 20 MB）。WOFF 的表按 zlib 解压后同样解析；WOFF2 是 Brotli 压缩，
/// 这里不引入解码器，只给出格式与大小，其余字段为 null（UI 退回按名推断）。
@immutable
class FontFileMetadata {
  const FontFileMetadata({
    required this.format,
    required this.sizeBytes,
    this.weights = const <int>[],
    this.variableWeightRange,
    this.faceCount = 1,
    this.japanese,
    this.simplifiedChinese,
    this.traditionalChinese,
    this.styleClass,
  });

  /// 大写扩展名（TTF / OTF / TTC / WOFF / WOFF2）。
  final String format;
  final int? sizeBytes;

  /// 静态字面的字重（`OS/2.usWeightClass`），升序去重；TTC 是各子字体的并集。
  final List<int> weights;

  /// 可变字体 `wght` 轴范围；null = 静态字体。
  final (int, int)? variableWeightRange;

  /// TTC 里的子字体数（其余格式恒 1）。
  final int faceCount;

  /// `OS/2.ulCodePageRange1` 的 JIS / GB2312 / Big5 位；null = 表里没有（v0 或读不出）。
  final bool? japanese;
  final bool? simplifiedChinese;
  final bool? traditionalChinese;

  /// `post.isFixedPitch` / `OS/2.sFamilyClass` / PANOSE 推出的风格；null = 判不出。
  final FontStyleClass? styleClass;

  bool get isVariable => variableWeightRange != null;

  /// 列表里显示的「字重数」：可变字体按 100 一档数 wght 轴覆盖的标准字重。
  int get weightCount {
    final (int, int)? range = variableWeightRange;
    if (range != null) return fontVariableWeightSteps(range).length;
    return weights.isEmpty ? 1 : weights.length;
  }

  /// 详情页逐行渲染的字重：可变字体取轴内的标准字重，静态取实际字面。
  List<int> get displayWeights {
    final (int, int)? range = variableWeightRange;
    if (range != null) return fontVariableWeightSteps(range);
    return weights.isEmpty ? const <int>[400] : weights;
  }
}

/// 可变字重轴 [range] 内的标准字重（100 的整数倍）；轴太窄时至少给出默认档。
List<int> fontVariableWeightSteps((int, int) range) {
  final (int min, int max) = range;
  final List<int> steps = <int>[
    for (int w = 100; w <= 900; w += 100)
      if (w >= min && w <= max) w,
  ];
  if (steps.isEmpty) steps.add(((min + max) ~/ 2).clamp(100, 900));
  return steps;
}

/// 读 [path] 的字体元数据；文件不存在 / 解析失败时只返回格式与大小（或 null）。
///
/// 表读取本身是同步的（只读表头与三张小表，几百字节），与 CSS 生成器读字重
/// （[readFontFaceWeightSync]）共用同一套解析；对外保持 Future 签名不变。
Future<FontFileMetadata?> readFontFileMetadata(String path) async {
  final File file = File(path);
  RandomAccessFile? raf;
  try {
    if (!file.existsSync()) return null;
    final int size = file.lengthSync();
    final String ext = p.extension(path).replaceFirst('.', '').toUpperCase();
    raf = file.openSync();
    final _FontReader reader = _FontReader(raf, size);
    final Uint8List head = reader.read(0, 12);
    if (head.length < 12) {
      return FontFileMetadata(format: ext, sizeBytes: size);
    }
    final ByteData h = ByteData.sublistView(head);
    final int tag = h.getUint32(0);
    if (tag == _tagTtcf) {
      final int numFonts = h.getUint32(8);
      final int faces = numFonts.clamp(1, 64);
      final Uint8List offsetsBytes = reader.read(12, faces * 4);
      final ByteData offsets = ByteData.sublistView(offsetsBytes);
      final Set<int> weights = <int>{};
      _SfntFacts? first;
      for (int i = 0; i < faces && (i + 1) * 4 <= offsetsBytes.length; i++) {
        // 只细读前 16 个子字体的字重；大集合（如 Noto CJK 全家 TTC）够用了。
        if (i >= 16) break;
        final _SfntFacts? facts = _factsOf(
          _openSfnt(reader, offsets.getUint32(i * 4)),
        );
        if (facts == null) continue;
        first ??= facts;
        if (facts.weight != null) weights.add(facts.weight!);
      }
      return _compose(
        format: ext.isEmpty ? 'TTC' : ext,
        size: size,
        facts: first,
        weights: weights,
        faceCount: numFonts,
      );
    }
    if (tag == _tagWoff) {
      final _SfntFacts? facts = _factsOf(_openWoff(reader));
      return _compose(
        format: 'WOFF',
        size: size,
        facts: facts,
        weights: <int>{if (facts?.weight != null) facts!.weight!},
      );
    }
    if (tag == _tagWoff2) {
      return FontFileMetadata(format: 'WOFF2', sizeBytes: size);
    }
    final _SfntFacts? facts = _factsOf(_openSfnt(reader, 0));
    return _compose(
      format: ext.isEmpty ? 'TTF' : ext,
      size: size,
      facts: facts,
      weights: <int>{if (facts?.weight != null) facts!.weight!},
    );
  } catch (e) {
    debugPrint('[fushi-fonts] metadata read failed for $path: $e');
    try {
      return FontFileMetadata(
        format: p.extension(path).replaceFirst('.', '').toUpperCase(),
        sizeBytes: file.lengthSync(),
      );
    } catch (_) {
      return null;
    }
  } finally {
    raf?.closeSync();
  }
}

/// 一个字体文件**被 `@font-face` 加载的那张字面**声明的字重：静态字体 `min == max`
/// （`OS/2.usWeightClass`），可变字体是 `wght` 轴范围。
typedef FontFaceWeight = ({int min, int max});

/// 读 [path] 被 `@font-face` 实际加载的字面（TTF/OTF/WOFF 整个文件；TTC 是第 0 个
/// 子字体——`@font-face src` 指向集合时浏览器只取它）的字重。
///
/// 读不出（WOFF2 的表是 Brotli 压缩、文件坏、没有 OS/2 表）返回 null，调用方此时
/// 不声明字重（等价于 CSS 默认 `normal`，与改动前一致）。同步：只读表头与两张小表。
FontFaceWeight? readFontFaceWeightSync(String path) {
  return _withFirstFace(path, (_TableReader? tables) {
    final _SfntFacts? facts = _factsOf(tables);
    if (facts == null) return null;
    final (int, int)? variable = facts.variableWeightRange;
    if (variable != null) return (min: variable.$1, max: variable.$2);
    final int? weight = facts.weight;
    return weight == null ? null : (min: weight, max: weight);
  });
}

/// 读 [path] 第一张字面在 `name` 表里声明的**家族名**：Typographic Family
/// （nameID 16）优先，没有再取 Family（nameID 1）；记录按 Windows 英语 →
/// 其余 Windows → Unicode → Mac 的顺序取第一条可解码的。
///
/// 为什么要 16 优先：同一家族的非 RIBBI 字重（Klee One SemiBold）把字重写进了
/// nameID 1（`Klee One SemiBold`），只有 nameID 16 才是两份文件共同的 `Klee One`。
/// 导入时用它当目录名，同一家族的多个字重文件才会落成同名条目、合进同一个
/// CSS 家族（各自 `@font-face` 声明真实字重）。读不出时返回 null。
String? readFontFamilyNameSync(String path) {
  return _withFirstFace(path, (_TableReader? tables) {
    final ByteData? name = tables?.call(_tagName, 1 << 18);
    return name == null ? null : _preferredFamilyName(name);
  });
}

T? _withFirstFace<T>(String path, T? Function(_TableReader? tables) body) {
  RandomAccessFile? raf;
  try {
    final File file = File(path);
    if (!file.existsSync()) return null;
    raf = file.openSync();
    final _FontReader reader = _FontReader(raf, raf.lengthSync());
    final Uint8List head = reader.read(0, 12);
    if (head.length < 12) return null;
    final ByteData h = ByteData.sublistView(head);
    final int tag = h.getUint32(0);
    if (tag == _tagWoff2) return null;
    if (tag == _tagWoff) return body(_openWoff(reader));
    if (tag == _tagTtcf) {
      // TTC 头：'ttcf' major minor numFonts，第 0 个子字体的偏移紧随其后（@12）。
      final Uint8List first = reader.read(12, 4);
      if (first.length < 4) return null;
      return body(_openSfnt(reader, ByteData.sublistView(first).getUint32(0)));
    }
    return body(_openSfnt(reader, 0));
  } catch (e) {
    debugPrint('[fushi-fonts] face read failed for $path: $e');
    return null;
  } finally {
    raf?.closeSync();
  }
}

FontFileMetadata _compose({
  required String format,
  required int size,
  required _SfntFacts? facts,
  required Set<int> weights,
  int faceCount = 1,
}) {
  final List<int> sorted = weights.toList()..sort();
  return FontFileMetadata(
    format: format,
    sizeBytes: size,
    weights: sorted,
    variableWeightRange: facts?.variableWeightRange,
    faceCount: faceCount,
    japanese: facts?.japanese,
    simplifiedChinese: facts?.simplifiedChinese,
    traditionalChinese: facts?.traditionalChinese,
    styleClass: facts?.styleClass,
  );
}

const int _tagTtcf = 0x74746366; // 'ttcf'
const int _tagWoff = 0x774F4646; // 'wOFF'
const int _tagWoff2 = 0x774F4632; // 'wOF2'
const int _tagOs2 = 0x4F532F32; // 'OS/2'
const int _tagPost = 0x706F7374; // 'post'
const int _tagFvar = 0x66766172; // 'fvar'
const int _tagWght = 0x77676874; // 'wght'
const int _tagName = 0x6E616D65; // 'name'

class _FontReader {
  _FontReader(this._raf, this.length);

  final RandomAccessFile _raf;
  final int length;

  Uint8List read(int offset, int count) {
    if (offset < 0 || offset >= length || count <= 0) return Uint8List(0);
    final int safe = count.clamp(0, length - offset);
    _raf.setPositionSync(offset);
    return _raf.readSync(safe);
  }
}

/// 一张字面的表访问器：按 tag 取表（最多 [maxLength] 字节），没有该表返回 null。
typedef _TableReader = ByteData? Function(int tag, int maxLength);

_SfntFacts? _factsOf(_TableReader? tables) {
  if (tables == null) return null;
  return _factsFromTables(
    os2: tables(_tagOs2, 100),
    post: tables(_tagPost, 32),
    fvar: tables(_tagFvar, 4096),
  );
}

class _SfntFacts {
  const _SfntFacts({
    this.weight,
    this.variableWeightRange,
    this.japanese,
    this.simplifiedChinese,
    this.traditionalChinese,
    this.styleClass,
  });

  final int? weight;
  final (int, int)? variableWeightRange;
  final bool? japanese;
  final bool? simplifiedChinese;
  final bool? traditionalChinese;
  final FontStyleClass? styleClass;
}

/// 未压缩 sfnt（TTF/OTF 或 TTC 子字体）：表目录在 [offset] 处。
_TableReader? _openSfnt(_FontReader reader, int offset) {
  final Uint8List header = reader.read(offset, 12);
  if (header.length < 12) return null;
  final int numTables = ByteData.sublistView(header).getUint16(4);
  if (numTables == 0 || numTables > 512) return null;
  final Uint8List dirBytes = reader.read(offset + 12, numTables * 16);
  final ByteData dir = ByteData.sublistView(dirBytes);
  final Map<int, (int, int)> tables = <int, (int, int)>{};
  for (int i = 0; i < numTables && (i + 1) * 16 <= dirBytes.length; i++) {
    final int base = i * 16;
    tables[dir.getUint32(base)] = (
      dir.getUint32(base + 8),
      dir.getUint32(base + 12),
    );
  }
  return (int tag, int maxLength) {
    final (int, int)? entry = tables[tag];
    if (entry == null) return null;
    final (int at, int len) = entry;
    final Uint8List bytes = reader.read(at, len.clamp(0, maxLength));
    return bytes.isEmpty ? null : ByteData.sublistView(bytes);
  };
}

/// WOFF 1.0：表按 zlib 压缩（compLength < origLength 时）。压缩表只能整张解，
/// 这里的上限是压缩长度 1 MiB，`maxLength` 不再截断（与改动前同语义）。
_TableReader? _openWoff(_FontReader reader) {
  final Uint8List header = reader.read(0, 44);
  if (header.length < 44) return null;
  final int numTables = ByteData.sublistView(header).getUint16(12);
  if (numTables == 0 || numTables > 512) return null;
  final Uint8List dirBytes = reader.read(44, numTables * 20);
  final ByteData dir = ByteData.sublistView(dirBytes);
  return (int wanted, int _) {
    for (int i = 0; i < numTables && (i + 1) * 20 <= dirBytes.length; i++) {
      final int base = i * 20;
      if (dir.getUint32(base) != wanted) continue;
      final int at = dir.getUint32(base + 4);
      final int compLength = dir.getUint32(base + 8);
      final int origLength = dir.getUint32(base + 12);
      if (compLength > 1 << 20) return null;
      final Uint8List raw = reader.read(at, compLength);
      final List<int> bytes = compLength < origLength ? zlib.decode(raw) : raw;
      return bytes.isEmpty
          ? null
          : ByteData.sublistView(Uint8List.fromList(bytes));
    }
    return null;
  };
}

/// `name` 表里家族名的首选记录：nameID 16 优先于 1；同一 nameID 内按
/// Windows 英语(3/0x409) → 其余 Windows(3) → Unicode(0) → Mac(1) 排序。
String? _preferredFamilyName(ByteData name) {
  if (name.lengthInBytes < 6) return null;
  final int count = name.getUint16(2);
  final int storage = name.getUint16(4);
  String? best;
  int bestRank = 1 << 30;
  for (int i = 0; i < count; i++) {
    final int rec = 6 + i * 12;
    if (rec + 12 > name.lengthInBytes) break;
    final int platformId = name.getUint16(rec);
    final int languageId = name.getUint16(rec + 4);
    final int nameId = name.getUint16(rec + 6);
    if (nameId != 16 && nameId != 1) continue;
    final int platformRank = switch (platformId) {
      3 when languageId == 0x409 => 0,
      3 => 1,
      0 => 2,
      1 => 3,
      _ => -1,
    };
    if (platformRank < 0) continue;
    final int rank = (nameId == 16 ? 0 : 10) + platformRank;
    if (rank >= bestRank) continue;
    final int length = name.getUint16(rec + 8);
    final int start = storage + name.getUint16(rec + 10);
    if (length <= 0 || start + length > name.lengthInBytes) continue;
    final String? decoded = _decodeNameRecord(
      platformId,
      Uint8List.sublistView(name, start, start + length),
    );
    final String? trimmed = decoded?.trim();
    if (trimmed == null || trimmed.isEmpty) continue;
    best = trimmed;
    bestRank = rank;
  }
  return best;
}

/// Windows / Unicode 平台是 UTF-16BE；Mac 记录按 Latin-1 兜底（ASCII 安全）。
String? _decodeNameRecord(int platformId, Uint8List raw) {
  if (platformId == 3 || platformId == 0) {
    if (raw.length.isOdd) return null;
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i + 1 < raw.length; i += 2) {
      sb.writeCharCode((raw[i] << 8) | raw[i + 1]);
    }
    return sb.toString();
  }
  return String.fromCharCodes(raw);
}

_SfntFacts _factsFromTables({
  required ByteData? os2,
  required ByteData? post,
  required ByteData? fvar,
}) {
  int? weight;
  bool? japanese;
  bool? simplified;
  bool? traditional;
  FontStyleClass? style;

  if (os2 != null && os2.lengthInBytes >= 6) {
    final int w = os2.getUint16(4);
    if (w >= 1 && w <= 1000) weight = w;
  }
  if (os2 != null && os2.lengthInBytes >= 82) {
    final int version = os2.getUint16(0);
    if (version >= 1) {
      final int codePages = os2.getUint32(78);
      japanese = codePages & (1 << 17) != 0;
      simplified = codePages & (1 << 18) != 0;
      traditional = codePages & (1 << 20) != 0;
    }
  }
  final bool fixedPitch =
      post != null && post.lengthInBytes >= 16 && post.getUint32(12) != 0;
  if (fixedPitch) {
    style = FontStyleClass.monospace;
  } else if (os2 != null && os2.lengthInBytes >= 42) {
    // PANOSE：bFamilyType 2 = 拉丁正文；bProportion 9 = 等宽；
    // bSerifStyle 2..10 衬线、11..15 无衬线。
    final int familyType = os2.getUint8(32);
    final int serifStyle = os2.getUint8(33);
    final int proportion = os2.getUint8(35);
    final int familyClass = os2.getUint8(30); // sFamilyClass 高字节
    if (familyType == 2 && proportion == 9) {
      style = FontStyleClass.monospace;
    } else if (familyType == 2 && serifStyle >= 2 && serifStyle <= 10) {
      style = FontStyleClass.serif;
    } else if (familyType == 2 && serifStyle >= 11 && serifStyle <= 15) {
      style = FontStyleClass.sansSerif;
    } else if (familyClass >= 1 && familyClass <= 7 && familyClass != 6) {
      style = FontStyleClass.serif;
    } else if (familyClass == 8) {
      style = FontStyleClass.sansSerif;
    }
  }

  (int, int)? variable;
  if (fvar != null && fvar.lengthInBytes >= 16) {
    final int axesOffset = fvar.getUint16(4);
    final int axisCount = fvar.getUint16(8);
    final int axisSize = fvar.getUint16(10);
    for (int i = 0; i < axisCount; i++) {
      final int base = axesOffset + i * axisSize;
      if (base + 16 > fvar.lengthInBytes) break;
      if (fvar.getUint32(base) != _tagWght) continue;
      final int min = (fvar.getInt32(base + 4) / 65536).round();
      final int max = (fvar.getInt32(base + 12) / 65536).round();
      if (min > 0 && max >= min) variable = (min, max);
      break;
    }
  }

  return _SfntFacts(
    weight: weight,
    variableWeightRange: variable,
    japanese: japanese,
    simplifiedChinese: simplified,
    traditionalChinese: traditional,
    styleClass: style,
  );
}

// ── 按名推断（系统字体与读不出表的文件字体共用） ──────────────────────────────

final RegExp _jaName = RegExp(
  r'(\bjp\b|japan|mincho|gothic|ゴシック|明朝|meiryo|メイリオ|\byu ?(gothic|mincho)|'
  r'游ゴシック|游明朝|hiragino|ヒラギノ|\bms ?(p?gothic|p?mincho|ui gothic)|'
  r'klee|shippori|\bzen |kosugi|sawarabi|m ?plus|\bipa|biz ?ud|源ノ|hina|'
  r'kiwi maru|dela gothic|rocknroll|yomogi|toppan|morisawa|モリサワ)',
  caseSensitive: false,
);

final RegExp _zhName = RegExp(
  r'(\b(sc|tc|hk|cn)\b|simsun|simhei|nsimsun|songti|heiti|kaiti|fangsong|'
  r'yahei|pingfang|dengxian|lisu|youyuan|stsong|stheiti|stkaiti|lxgw|wenkai|'
  r'jhenghei|mingliu|pmingliu|宋|黑体|黑體|楷|仿宋|雅黑|苹方|等线|霞鹜|思源)',
  caseSensitive: false,
);

final RegExp _monoName = RegExp(
  r'(mono|code|consol|courier|terminal|等宽|等幅|fixed)',
  caseSensitive: false,
);

final RegExp _serifName = RegExp(
  r'(serif(?! ?sans)|mincho|明朝|song|宋|\bming|times|georgia|garamond|'
  r'baskerville|palatino|cambria|book antiqua|minion|caslon|bodoni)',
  caseSensitive: false,
);

final RegExp _sansName = RegExp(
  r'(sans|gothic|ゴシック|\bhei\b|heiti|黑|meiryo|yahei|pingfang|arial|'
  r'helvetica|segoe|roboto|inter\b|verdana|tahoma|calibri|dengxian|等线|'
  r'jhenghei|maru|丸)',
  caseSensitive: false,
);

/// 字体库一行的筛选特征：语言覆盖 + 风格大类。文件里读得出的元数据优先，
/// 读不出（系统字体、WOFF2、OS/2 v0）时按名字推断。
@immutable
class FontLibraryTraits {
  const FontLibraryTraits({
    required this.japanese,
    required this.chinese,
    required this.styleClass,
  });

  final bool japanese;
  final bool chinese;
  final FontStyleClass? styleClass;
}

FontLibraryTraits fontLibraryTraitsFor({
  required String name,
  FontFileMetadata? metadata,
  bool? systemSupportsJapanese,
}) {
  final bool nameJa = _jaName.hasMatch(name);
  final bool nameZh = _zhName.hasMatch(name);
  final bool japanese = metadata?.japanese ?? systemSupportsJapanese ?? nameJa;
  final bool? metaZh =
      metadata?.simplifiedChinese == null &&
          metadata?.traditionalChinese == null
      ? null
      : (metadata?.simplifiedChinese ?? false) ||
            (metadata?.traditionalChinese ?? false);
  final bool chinese = metaZh ?? nameZh;
  FontStyleClass? style = metadata?.styleClass;
  if (style == null) {
    if (_monoName.hasMatch(name)) {
      style = FontStyleClass.monospace;
    } else if (_serifName.hasMatch(name)) {
      style = FontStyleClass.serif;
    } else if (_sansName.hasMatch(name)) {
      style = FontStyleClass.sansSerif;
    }
  }
  return FontLibraryTraits(
    japanese: japanese,
    chinese: chinese,
    styleClass: style,
  );
}

/// 字体库筛选 chip。
enum FontLibraryFilter {
  all,
  imported,
  system,
  japanese,
  chinese,
  serif,
  sansSerif,
  monospace,
}

bool fontLibraryFilterMatches(
  FontLibraryFilter filter, {
  required bool isFile,
  required FontLibraryTraits traits,
}) => switch (filter) {
  FontLibraryFilter.all => true,
  FontLibraryFilter.imported => isFile,
  FontLibraryFilter.system => !isFile,
  FontLibraryFilter.japanese => traits.japanese,
  FontLibraryFilter.chinese => traits.chinese,
  FontLibraryFilter.serif => traits.styleClass == FontStyleClass.serif,
  FontLibraryFilter.sansSerif => traits.styleClass == FontStyleClass.sansSerif,
  FontLibraryFilter.monospace => traits.styleClass == FontStyleClass.monospace,
};
