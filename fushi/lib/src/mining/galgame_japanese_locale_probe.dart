/// 转区判定的**证据探测器**（BUG-2047）：从 exe 字节、游戏目录顶层文件名与顶层文本文件
/// 里离线抽取 [GalJapaneseLocaleEvidence]，交给 [judgeJapaneseLocaleNeed] 裁决。
///
/// 分层纪律：`classify*` 全是纯函数（字节 / 文件名进，证据出），三端可用合成数据单测；
/// 只有 [probeGalJapaneseLocaleNeed] 做 IO，且**有界**（exe 前 16 MB、顶层目录 ≤ 2000 项、
/// 文本文件 ≤ 20 个 × ≤ 256 KB）。任何 IO 异常一律吞成「无该证据」——探测失败的正确
/// 结果是 `unknown`，绝不能让它阻塞或炸掉启动。
///
/// 阈值来源见 `docs/plans/2026-09-02-gal-japanese-locale-auto-need.md` §2：
/// - exe 非代码段的假名串段在两个非日文二进制上噪声上限是 0 条，取 ≥ 3 留余量；
/// - exe 里的「GB2312 区字节对」是噪声（纯英文 charmap.exe 也有 86 条），**不做**负向；
/// - 文本文件里的假名 / GB 统计是干净的（readme 1993 : 0），负向证据放在目录文本上。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/pe_resources.dart';
import 'package:path/path.dart' as p;

/// exe 只读前 16 MB：资源段与 `.rdata` 字符串几乎都在前部，读整个几 GB 的壳包没有意义。
const int kGalLocaleProbeExeReadLimit = 16 * 1024 * 1024;

/// 顶层目录最多看多少项（不递归）。
const int kGalLocaleProbeDirectoryEntryLimit = 2000;

/// 顶层文本文件最多读多少个。
const int kGalLocaleProbeTextFileLimit = 20;

/// 每个文本文件只读前 256 KB。
const int kGalLocaleProbeTextReadLimit = 256 * 1024;

/// 视为「文本文件」的扩展名（小写、不带点）。
const Set<String> kGalLocaleProbeTextExtensions = <String>{
  'txt',
  'ini',
  'cfg',
  'htm',
  'html',
  'nfo',
  'md',
};

const int _rtVersion = 16;
const int _rtManifest = 24;

/// Shift-JIS 假名对：0x82 0x9F–0xF1（平假名）、0x83 0x40–0x96（片假名）。
bool _isKanaPair(int lead, int trail) =>
    (lead == 0x82 && trail >= 0x9F && trail <= 0xF1) ||
    (lead == 0x83 && trail >= 0x40 && trail <= 0x96);

/// GB2312 汉字对：lead 0xB0–0xF7，trail 0xA1–0xFE。
bool _isGbPair(int lead, int trail) =>
    lead >= 0xB0 && lead <= 0xF7 && trail >= 0xA1 && trail <= 0xFE;

/// DBCS 首字节（Shift-JIS 与 GBK 共同的宽松范围）。
bool _isDbcsLead(int b) => b >= 0x81 && b <= 0xFE;

/// DBCS 尾字节（0x40–0xFE 去 0x7F）。
bool _isDbcsTrail(int b) => b >= 0x40 && b <= 0xFE && b != 0x7F;

bool _isKanaCodeUnit(int unit) => unit >= 0x3040 && unit <= 0x30FF;

/// 简体专用汉字（在日文常用字表里不存在的简化字形）。命中 ≥ 5 个且无假名 ⇒ 简体中文文本。
const String _simplifiedOnlyHanzi =
    '这们说时对为么还开关发经过让见觉应问题样电话请认识语汉书车东门马鸟长头处从'
    '图团园网选择设载运动补简启击错误显无检测结页键标输现实际边讨论谢亲爱欢达级纪线终转权'
    '听视频兴义艺术习乐华专业严丽举亚产亿仅众优传伤戏员间战层岁币师带张录态总户报据换损敌'
    '极构档气汇泽济满灵热爷环疗监确种积竞笔签类紧纳纸组络统继续维编缓罗职联脑脸节荣获营虑'
    '观规计订议记许译词诉该详读调谈责败账质购贴费资赛赞跃踪轻较辑迁进远违连迟适递逻遗邮释'
    '针钟钱铁银销锁镜闭闲阅阶陆险随隐难项顺须预领颜额风饭饰馆驱验鱼鲜龙齐';
final Set<int> _simplifiedOnlySet = _simplifiedOnlyHanzi.codeUnits.toSet();

/// 文件名负向：汉化 / 中文 / 简体 / 繁体 / 繁體 / CHS / CHT / chinese / hanhua（大小写不敏感）。
/// 汉字标记裸子串即可；ASCII 标记必须是独立词元（前后不能紧挨字母），否则
/// `fuchsia.dll` / `watchtower.ogg` 这类普通英文名会被 `chs` / `cht` 假阳性判成汉化。
final RegExp _chinesePatchNamePattern = RegExp(
  r'汉化|中文|简体|繁体|繁體|(?<![a-z])(?:chs|cht|chinese|hanhua)(?![a-z])',
  caseSensitive: false,
);

/// manifest 里 `<activeCodePage ...>UTF-8</activeCodePage>`（元素可带 xmlns 属性）。
final RegExp _manifestUtf8Pattern = RegExp(
  r'activecodepage[^>]*>\s*utf-?8\s*<',
);

/// 用户声明的内容语言（BCP-47）→ 人工真值证据；空/未声明 → null。
GalJapaneseLocaleEvidence? classifyUserLanguageForLocale(String? language) {
  final String trimmed = language?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final String primary = trimmed.split(RegExp(r'[-_]')).first.toLowerCase();
  return primary == 'ja' || primary == 'jpn'
      ? GalJapaneseLocaleEvidence.userLanguageJapanese
      : GalJapaneseLocaleEvidence.userLanguageOther;
}

/// 一个文本文件的字节 → 至多一条目录文本证据；纯 ASCII / 看不出来 → null。
///
/// 带 BOM（UTF-8 / UTF-16）或**严格合法的 UTF-8** 走 Unicode 路径：只查「简体专用汉字
/// ≥ 5 且无假名」。UTF-8 里的假名**不算**正向证据——它只说明 readme 是日文，说明不了
/// 引擎按 CP932 解字符串（KiriKiri Z 多语言版就附带 UTF-8 日文 readme）。
/// 其余按 DBCS 字节对统计：假名对 ≥ 20 且 GB 对 ≈ 0 ⇒ Shift-JIS；反之 ⇒ GBK。
GalJapaneseLocaleEvidence? classifyTextBytesForLocale(Uint8List bytes) {
  final String? unicode = _decodeUnicodeText(bytes);
  if (unicode != null) {
    int kana = 0;
    int simplified = 0;
    for (final int unit in unicode.codeUnits) {
      if (_isKanaCodeUnit(unit)) {
        kana++;
      } else if (_simplifiedOnlySet.contains(unit)) {
        simplified++;
      }
    }
    if (kana == 0 && simplified >= 5) {
      return GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi;
    }
    return null;
  }
  final _DbcsPairCounts counts = _countDbcsPairs(bytes, 0, bytes.length);
  // 「≈ 0」按比例而不是绝对值：Shift-JIS 二级汉字（lead 0xE0–0xEA）会落进 GB 首字节
  // 区，日文 readme 里零星几个不该把整份文件判成「不像 Shift-JIS」。
  if (counts.kana >= 20 && counts.gb * 20 <= counts.kana) {
    return GalJapaneseLocaleEvidence.dirTextShiftJis;
  }
  if (counts.gb >= 20 && counts.kana * 20 <= counts.gb) {
    return GalJapaneseLocaleEvidence.dirTextGbk;
  }
  return null;
}

/// 顶层文件名（basename）集合 → 目录文件名证据（正负可同时命中，由裁决层定优先级）。
Set<GalJapaneseLocaleEvidence> classifyFileNamesForLocale(
  Iterable<String> names,
) {
  final Set<GalJapaneseLocaleEvidence> out = <GalJapaneseLocaleEvidence>{};
  for (final String name in names) {
    if (_chinesePatchNamePattern.hasMatch(name)) {
      out.add(GalJapaneseLocaleEvidence.dirFileNameChinesePatch);
    }
    if (name.codeUnits.any(_isKanaCodeUnit)) {
      out.add(GalJapaneseLocaleEvidence.dirFileNameJapanese);
    }
  }
  return out;
}

/// exe 字节（可以只是前 16 MB）→ exe 层证据：
/// RT_VERSION 语言（0x0411 / 中文各变体）、RT_MANIFEST `activeCodePage=UTF-8`、
/// 非代码段里的 Shift-JIS 假名串段（≥ 3 条）。非 PE / 损坏 → 空集。
Set<GalJapaneseLocaleEvidence> classifyPeForLocale(Uint8List bytes) {
  final Set<GalJapaneseLocaleEvidence> out = <GalJapaneseLocaleEvidence>{};
  try {
    final Set<int> languages = <int>{};
    for (final PeResourceLeaf leaf in readPeResourceLeaves(bytes, _rtVersion)) {
      if (leaf.langId > 0) languages.add(leaf.langId);
      _collectVersionTranslations(leaf.bytes, languages);
    }
    for (final int lang in languages) {
      if (lang == 0x0411) {
        out.add(GalJapaneseLocaleEvidence.versionInfoJapanese);
      } else if (lang == 0x0804 ||
          lang == 0x0404 ||
          lang == 0x0C04 ||
          lang == 0x1004) {
        out.add(GalJapaneseLocaleEvidence.versionInfoChinese);
      }
    }
    for (final PeResourceLeaf leaf in readPeResourceLeaves(
      bytes,
      _rtManifest,
    )) {
      if (_manifestUtf8Pattern.hasMatch(
        latin1.decode(leaf.bytes).toLowerCase(),
      )) {
        out.add(GalJapaneseLocaleEvidence.manifestUtf8CodePage);
        break;
      }
    }
    if (countShiftJisStringSegments(bytes, limit: 3) >= 3) {
      out.add(GalJapaneseLocaleEvidence.exeShiftJisStrings);
    }
  } catch (_) {
    // 任何越界 / 结构假设不成立：已收集到的证据照常返回，未收集到的当作没有。
  }
  return out;
}

/// 数 PE 非代码段里「NUL 终止、长度 ≥ 6、全由可打印 ASCII 或 DBCS 对组成，且假名对 ≥ 2、
/// GB2312 对 = 0」的串段；到 [limit] 条即提前返回。公开只为单测与调阈值。
int countShiftJisStringSegments(Uint8List bytes, {int limit = 1 << 30}) {
  int segments = 0;
  for (final PeSection section in readPeSections(bytes)) {
    if (section.isExecutable || section.rawSize <= 0) continue;
    final int start = section.rawOffset;
    if (start >= bytes.length) continue;
    final int end = start + section.rawSize > bytes.length
        ? bytes.length
        : start + section.rawSize;
    segments += _countShiftJisSegmentsIn(bytes, start, end, limit - segments);
    if (segments >= limit) return segments;
  }
  return segments;
}

int _countShiftJisSegmentsIn(Uint8List bytes, int start, int end, int limit) {
  int segments = 0;
  int length = 0;
  int kana = 0;
  int gb = 0;
  bool valid = true;
  int i = start;
  while (i < end) {
    final int b = bytes[i];
    if (b == 0) {
      if (valid && length >= 6 && kana >= 2 && gb == 0) {
        segments++;
        if (segments >= limit) return segments;
      }
      length = 0;
      kana = 0;
      gb = 0;
      valid = true;
      i++;
      continue;
    }
    if (!valid) {
      i++;
      continue;
    }
    if (b >= 0x20 && b <= 0x7E) {
      length++;
      i++;
      continue;
    }
    if (_isDbcsLead(b) && i + 1 < end && _isDbcsTrail(bytes[i + 1])) {
      final int trail = bytes[i + 1];
      if (_isKanaPair(b, trail)) {
        kana++;
      } else if (_isGbPair(b, trail)) {
        gb++;
      }
      length += 2;
      i += 2;
      continue;
    }
    valid = false;
    i++;
  }
  return segments;
}

class _DbcsPairCounts {
  int kana = 0;
  int gb = 0;
}

/// 顺序扫描：ASCII 走一字节，DBCS 首字节 + 合法尾字节走两字节并归类，其余跳过一字节。
_DbcsPairCounts _countDbcsPairs(Uint8List bytes, int start, int end) {
  final _DbcsPairCounts counts = _DbcsPairCounts();
  int i = start;
  while (i < end) {
    final int b = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    if (_isDbcsLead(b) && i + 1 < end && _isDbcsTrail(bytes[i + 1])) {
      final int trail = bytes[i + 1];
      if (_isKanaPair(b, trail)) {
        counts.kana++;
      } else if (_isGbPair(b, trail)) {
        counts.gb++;
      }
      i += 2;
      continue;
    }
    i++;
  }
  return counts;
}

/// BOM 或严格合法 UTF-8（含非 ASCII）→ 解码文本；否则 null（交给 DBCS 统计）。
String? _decodeUnicodeText(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes, 2, Endian.little);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes, 2, Endian.big);
  }
  bool ascii = true;
  for (final int b in bytes) {
    if (b >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return '';
  // 只读了前 N KB 时尾部可能截在多字节序列中间：最多切掉 3 个尾字节再试。
  for (int cut = 0; cut <= 3 && cut < bytes.length; cut++) {
    try {
      return utf8.decode(
        cut == 0 ? bytes : bytes.sublist(0, bytes.length - cut),
      );
    } on FormatException {
      continue;
    }
  }
  return null;
}

String _decodeUtf16(Uint8List bytes, int start, Endian endian) {
  final ByteData data = ByteData.sublistView(bytes);
  final int count = (bytes.length - start) ~/ 2;
  final List<int> units = List<int>.generate(
    count,
    (int i) => data.getUint16(start + i * 2, endian),
    growable: false,
  );
  return String.fromCharCodes(units);
}

/// 从 VS_VERSIONINFO 里读 `VarFileInfo\Translation` 的语言字：找 UTF-16LE 的
/// `Translation\0` 键，按 Var 结构（wLength / wValueLength / wType / szKey / 4 字节对齐
/// 后的 DWORD 数组）取每个 DWORD 的低字。
void _collectVersionTranslations(Uint8List blob, Set<int> languages) {
  const String key = 'Translation';
  final List<int> needle = <int>[];
  for (final int unit in key.codeUnits) {
    needle
      ..add(unit)
      ..add(0);
  }
  needle
    ..add(0)
    ..add(0);
  final int index = _indexOfBytes(blob, needle);
  if (index < 6) return;
  final ByteData data = ByteData.sublistView(blob);
  final int valueLength = data.getUint16(index - 4, Endian.little);
  int cursor = index + needle.length;
  cursor = (cursor + 3) & ~3;
  final int count = valueLength ~/ 4;
  for (int i = 0; i < count; i++) {
    final int at = cursor + i * 4;
    if (at + 2 > blob.length) break;
    languages.add(data.getUint16(at, Endian.little));
  }
}

int _indexOfBytes(Uint8List haystack, List<int> needle) {
  final int last = haystack.length - needle.length;
  outer:
  for (int i = 0; i <= last; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// 有界 IO 探测 + 裁决。[language] 是 `GalgameEntry.language`：一旦声明就是人工真值，
/// **零 IO** 直接裁决。其余顺序：exe 前 16 MB → 顶层文件名 → 顶层文本文件。
/// 任何一步失败只丢那一步的证据，永不抛出。
Future<GalJapaneseLocaleVerdict> probeGalJapaneseLocaleNeed({
  required String exePath,
  String? language,
}) async {
  final GalJapaneseLocaleEvidence? declared = classifyUserLanguageForLocale(
    language,
  );
  if (declared != null) {
    return judgeJapaneseLocaleNeed(<GalJapaneseLocaleEvidence>[declared]);
  }
  final Set<GalJapaneseLocaleEvidence> evidence = <GalJapaneseLocaleEvidence>{};
  evidence.addAll(await _probeExe(exePath));
  evidence.addAll(await _probeDirectory(exePath));
  return judgeJapaneseLocaleNeed(evidence);
}

Future<Set<GalJapaneseLocaleEvidence>> _probeExe(String exePath) async {
  final Uint8List? head = await _readHead(exePath, kGalLocaleProbeExeReadLimit);
  if (head == null) return const <GalJapaneseLocaleEvidence>{};
  return classifyPeForLocale(head);
}

Future<Set<GalJapaneseLocaleEvidence>> _probeDirectory(String exePath) async {
  final Set<GalJapaneseLocaleEvidence> out = <GalJapaneseLocaleEvidence>{};
  final List<String> names = <String>[];
  final List<String> textFiles = <String>[];
  try {
    final Directory directory = File(exePath).parent;
    int seen = 0;
    await for (final FileSystemEntity entity in directory.list(
      followLinks: false,
    )) {
      if (++seen > kGalLocaleProbeDirectoryEntryLimit) break;
      final String name = p.basename(entity.path);
      names.add(name);
      if (entity is File &&
          textFiles.length < kGalLocaleProbeTextFileLimit &&
          kGalLocaleProbeTextExtensions.contains(
            p.extension(name).replaceFirst('.', '').toLowerCase(),
          )) {
        textFiles.add(entity.path);
      }
    }
  } catch (_) {
    // 目录读不了（权限 / 网络盘掉线 / 被删）：已经拿到的文件名照常参与判定。
  }
  out.addAll(classifyFileNamesForLocale(names));
  for (final String path in textFiles) {
    final Uint8List? head = await _readHead(path, kGalLocaleProbeTextReadLimit);
    if (head == null) continue;
    final GalJapaneseLocaleEvidence? evidence = classifyTextBytesForLocale(
      head,
    );
    if (evidence != null) out.add(evidence);
  }
  return out;
}

/// 读文件前 [limit] 字节；任何异常返回 null。
Future<Uint8List?> _readHead(String path, int limit) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final int length = await file.length();
    final int count = length < limit ? length : limit;
    if (count <= 0) return Uint8List(0);
    return await file.read(count);
  } catch (_) {
    return null;
  } finally {
    try {
      await file?.close();
    } catch (_) {
      // 关闭失败没有可做的事。
    }
  }
}
