/// 从文件名 / 文件夹名得来的媒体标题清洗：全部媒体共用的唯一实现。
///
/// 两层，各管各的：
///
/// - **显示层** [cleanImportedTitle]：只去掉**一定不是标题的部分**——末尾的已知媒体 /
///   压缩包扩展名、末尾（可连续多段）的 8 位十六进制 CRC 标签 `[xxxxxxxx]` /
///   `(xxxxxxxx)`、首尾空白与连续空白。出版社标签 `(電撃文庫)`、版本标签、
///   `BOOK☆WALKER限定書き下ろしショートストーリー`、`『』`、卷号一律不动：它们有含义
///   （特典短篇去掉标签就和正篇同名）。
/// - **检索 / 键层原语**（[kImportedTitleFileExtensions]、[kCrcHexSource]、
///   [kCrcTagSource] 等）：分卷归组键（`book_series_key.dart`）、追踪检索词
///   （`local_title_clean.dart`）、下载版本分组（`video_resource_version_groups.dart`）
///   各自在这些原语之上再叠自己的规则，不再各写一份「什么是 CRC / 扩展名」。
///
/// **CRC 判据取各处并集**：恰好 8 位十六进制、大小写都认、方括号或圆括号成对包住。
/// 此前分卷键只认方括号、显示层只认小写方括号、追踪只认圆括号里的小写（方括号整段
/// 另有规则去掉）、下载分组认 `[` / `(` 混配——同一个 CRC 在一处算、在另一处不算。
/// **扩展名取并集**：书 / 漫画 / 压缩包 / 字幕 / 视频 / 音频（追踪原来那张小表 ∪
/// 引擎 `kVideoExtensions` ∪ `kAudioExtensions`，后两张由引擎测试钉死是本表子集）。
///
/// 住在 fushi_core（而不是引擎）是因为存量标题清理是 schema 迁移步（v172），迁移
/// 只能用 core 里的代码；引擎经 `package:fushi_engine/media/titles/media_title_clean.dart`
/// 原样转出，引擎与 app 都从那里引用。纯 Dart，无 IO。
library;

/// 文件名标题末尾可能残留的扩展名（不带点、小写）。
///
/// 书 / 漫画 / 压缩包 / 字幕 / 视频 / 音频的并集。新增导入格式时加在这里；视频 /
/// 音频两张表由引擎测试（`media_title_clean_test.dart`）钉死必须是本表子集。
const Set<String> kImportedTitleFileExtensions = <String>{
  // 书 / 漫画 / 压缩包。
  'epub', 'kepub', 'pdf', 'mobi', 'azw', 'azw3', 'txt', 'html', 'htm',
  'mokuro', 'cbz', 'cbr', 'cb7', 'cbt', 'zip', 'rar', '7z', 'tar',
  // 字幕 / 歌词。
  'srt', 'ass', 'ssa', 'vtt', 'lrc',
  // 视频（⊇ 引擎 kVideoExtensions）。
  'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', 'ts', 'm2ts', 'mts', 'flv',
  'wmv', 'mpg', 'mpeg', 'ogv', 'rmvb', 'rm', 'vob',
  // 音频（⊇ 引擎 kAudioExtensions）。
  'flac', 'm4a', 'm4b', 'alac', 'mp3', 'mp2', 'mpa', 'ogg', 'oga', 'opus',
  'wav', 'aiff', 'aif', 'aifc', 'ape', 'wv', 'tak', 'tta', 'mpc', 'dsf',
  'dff', 'aac', 'ac3', 'eac3', 'ec3', 'mka', 'caf', 'w64', 'wma',
};

/// [kImportedTitleFileExtensions] 的正则交替式（长的在前，`azw3` 先于 `azw`）。
final String kImportedTitleExtensionSource = () {
  final List<String> sorted = kImportedTitleFileExtensions.toList()
    ..sort((String a, String b) => b.length.compareTo(a.length));
  return '(?:${sorted.map(RegExp.escape).join('|')})';
}();

/// 末尾的已知扩展名（点前必须有非空白字符：`Title.epub`；大小写不敏感）。
final RegExp importedTitleExtensionPattern = RegExp(
  '(?<=\\S)\\.$kImportedTitleExtensionSource\$',
  caseSensitive: false,
);

/// CRC 本体：恰好 8 位十六进制（大小写都认）。用来拼各处自己的正则。
const String kCrcHexSource = '[0-9a-fA-F]{8}';

/// 一个 CRC 标签：`[xxxxxxxx]` 或 `(xxxxxxxx)`（括号成对）。
const String kCrcTagSource = '(?:\\[$kCrcHexSource\\]|\\($kCrcHexSource\\))';

/// 末尾的一段或多段 CRC 标签（连同前面的空白与尾随空白）。
final RegExp trailingCrcTagsPattern = RegExp('(?:\\s*$kCrcTagSource)+\\s*\$');

final RegExp _crcHexExact = RegExp('^$kCrcHexSource\$');

/// [value] 是否恰好是一个 CRC 本体（不含括号，`3574f94a` / `E0914585`）。
bool isCrcHex(String value) => _crcHexExact.hasMatch(value);

/// 去掉末尾的 CRC 标签（可连续多段）；没有原样返回。不做空串回退。
String stripTrailingCrcTags(String title) =>
    title.replaceFirst(trailingCrcTagsPattern, '');

/// 去掉末尾一个已知扩展名；没有原样返回。不做空串回退。
String stripImportedFileExtension(String title) =>
    title.replaceFirst(importedTitleExtensionPattern, '');

final RegExp _asciiWhitespaceRun = RegExp(r'[ \t\r\n\f\v]+');

/// 显示层清洗：从文件名 / 文件夹名得来的标题去掉一定不是标题的部分。
///
/// 依次（直到不再变化）去掉末尾扩展名与末尾 CRC 标签，再把连续的 ASCII 空白折成
/// 一个空格、去首尾空白（全角空格 U+3000 是排版的一部分，不折）。只动末尾：中段的
/// `[3574f94a]`、出版社 / 版本标签、`『』`、卷号都保留。
///
/// 清洗后为空（整个标题就是一个 CRC / 扩展名）时原样返回 [raw]：宁可显示原名也不
/// 显示空标题。幂等：`cleanImportedTitle(cleanImportedTitle(x)) == cleanImportedTitle(x)`。
String cleanImportedTitle(String raw) {
  String s = raw.trim();
  while (true) {
    final String next = stripTrailingCrcTags(
      stripImportedFileExtension(s),
    ).trim();
    if (next == s) break;
    s = next;
  }
  s = s.replaceAll(_asciiWhitespaceRun, ' ').trim();
  return s.isEmpty ? raw : s;
}
