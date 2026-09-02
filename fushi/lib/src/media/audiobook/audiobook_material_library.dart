/// 有声书**素材库**索引：把一堆散落的字幕/正文文件按「作品身份」编成表，供
/// 下载完成后自动配齐「正文 + 字幕 + 音频」。
///
/// 身份键就是有声书目录（CoreAudio）的主键本身，素材文件名把它写在方括号里：
///
/// - `#真相をお話しします [B0B58GV92J].srt` → `B0B58GV92J`（Audible ASIN）
/// - `[01] MM9 [kikubon 139].srt`          → `kikubon 139`
/// - `[01] medium [audiobook.jp 259377].srt` → `audiobook.jp 259377`
///
/// **不为三套 id 各写一套分支**：取出文件名里全部方括号内容，逐个用同一条形态
/// 判据认键（[audiobookMaterialKeyOf]），卷号 `[01]` / `[1巻]` 天然不匹配。
///
/// 实测（TMW 字幕库 1716 个文件 × CoreAudio 目录 4223 条）：认出 1123 个身份键，
/// 其中 1120 个在目录里有对应音频，另外 3 个是合法的 `audiobook.jp` 编号但目录
/// 当前没有那本书——**零误报**。这也是形态判据比「拿目录主键当白名单」好的地方：
/// 离线可用，且目录新增条目后旧素材自动能配上，不必重扫。
///
/// 认不出键的素材退到**归一化标题**索引（EPUB 文件名通常不带主键，形如
/// `[作者] 书名.epub`），由调用方决定是否接受这种较弱的匹配。
library;

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_search_text.dart';

/// 作品身份键的形态判据。
///
/// 三种值域都来自有声书目录主键本身：Audible ASIN（`B0` + 8 位大写字母数字）、
/// `audiobook.jp <数字>`、`kikubon <数字>`。写成一条正则而不是三个分支——它们是
/// 同一个概念（作品身份）的三种书写，不是三种特殊情况。
final RegExp _materialKeyPattern = RegExp(
  r'^(?:B0[A-Z0-9]{8}|(?:audiobook\.jp|kikubon) \d+)$',
);

/// 从**文件名**里认出作品身份键；认不出返回 null。
///
/// 只看方括号内容，且要求整段匹配 [_materialKeyPattern]——`[01]`、`[1巻]`、
/// `[10.5巻]` 这类卷号不会被误当身份。同一文件名里有多个方括号时取第一个命中的。
String? audiobookMaterialKeyOf(String path) {
  final String name = p.basename(path);
  for (final RegExpMatch m in RegExp(r'\[([^\]]+)\]').allMatches(name)) {
    final String inner = m.group(1)!.trim();
    if (_materialKeyPattern.hasMatch(inner)) return inner;
  }
  return null;
}

/// 去掉文件名里的方括号段与扩展名后的归一化标题，用作弱匹配键。
///
/// `[今村昌弘] 屍人荘の殺人.epub` → 归一化后的 `屍人荘の殺人`。作者前缀同样住在
/// 方括号里，一并剥掉；剥完为空则退回整个 stem，避免把 `[B0...].srt` 这类
/// 只有方括号的名字归一成空串、让所有此类文件挤成同一个键。
String audiobookMaterialTitleKeyOf(String path) {
  final String stem = p.basenameWithoutExtension(path);
  final String stripped = stem.replaceAll(RegExp(r'\[[^\]]*\]'), ' ').trim();
  return normalizeMediaSearchText(stripped.isEmpty ? stem : stripped);
}

/// 一份素材库的索引（纯数据，无 IO）。
class AudiobookMaterialIndex {
  const AudiobookMaterialIndex({
    required this.subtitleByKey,
    required this.contentByKey,
    required this.contentByTitle,
    required this.subtitleByTitle,
  });

  const AudiobookMaterialIndex.empty()
    : subtitleByKey = const <String, String>{},
      contentByKey = const <String, String>{},
      contentByTitle = const <String, String>{},
      subtitleByTitle = const <String, String>{};

  /// 身份键 → 字幕绝对路径。
  final Map<String, String> subtitleByKey;

  /// 身份键 → 正文（EPUB/可转文本）绝对路径。
  final Map<String, String> contentByKey;

  /// 归一化标题 → 正文绝对路径（弱匹配）。
  final Map<String, String> contentByTitle;

  /// 归一化标题 → 字幕绝对路径（弱匹配）。
  final Map<String, String> subtitleByTitle;

  bool get isEmpty =>
      subtitleByKey.isEmpty &&
      contentByKey.isEmpty &&
      contentByTitle.isEmpty &&
      subtitleByTitle.isEmpty;

  /// 库里认得的作品数（按身份键去重，两类素材取并集）。
  int get identifiedWorkCount =>
      <String>{...subtitleByKey.keys, ...contentByKey.keys}.length;
}

/// 一次配对的结果；[contentIsWeakMatch] 标记正文是靠标题猜的而非身份键命中。
class AudiobookMaterialMatch {
  const AudiobookMaterialMatch({
    this.subtitlePath,
    this.contentPath,
    this.contentIsWeakMatch = false,
    this.subtitleIsWeakMatch = false,
  });

  final String? subtitlePath;
  final String? contentPath;
  final bool contentIsWeakMatch;
  final bool subtitleIsWeakMatch;

  bool get hasSubtitle => subtitlePath != null;
  bool get isEmpty => subtitlePath == null && contentPath == null;
}

/// 素材分类：字幕看 [subtitleExtensions]，正文看 [contentExtensions]。
///
/// 两个集合由调用方注入既有真相源（`kDiscoverySubtitleExtensions` /
/// `TextToEpub.supportedExtensions` + epub），本层不自造副本。
AudiobookMaterialIndex indexAudiobookMaterials(
  Iterable<String> filePaths, {
  required Set<String> subtitleExtensions,
  required Set<String> contentExtensions,
}) {
  final Map<String, String> subtitleByKey = <String, String>{};
  final Map<String, String> contentByKey = <String, String>{};
  final Map<String, String> contentByTitle = <String, String>{};
  final Map<String, String> subtitleByTitle = <String, String>{};
  for (final String path in filePaths) {
    final String ext = p.extension(path).toLowerCase();
    final bool subtitle = subtitleExtensions.contains(ext);
    final bool content = contentExtensions.contains(ext);
    if (!subtitle && !content) continue;
    final Map<String, String> byKey = subtitle ? subtitleByKey : contentByKey;
    final Map<String, String> byTitle = subtitle
        ? subtitleByTitle
        : contentByTitle;
    final String? key = audiobookMaterialKeyOf(path);
    // 先到先得：同一作品有多份素材时保留第一份，避免后来的覆盖掉已配好的。
    if (key != null) {
      byKey.putIfAbsent(key, () => path);
      continue;
    }
    final String title = audiobookMaterialTitleKeyOf(path);
    if (title.isNotEmpty) byTitle.putIfAbsent(title, () => path);
  }
  return AudiobookMaterialIndex(
    subtitleByKey: subtitleByKey,
    contentByKey: contentByKey,
    contentByTitle: contentByTitle,
    subtitleByTitle: subtitleByTitle,
  );
}

/// 给一部作品配素材。[key] 是它在有声书目录里的主键，[title] 是显示名。
///
/// 身份键命中优先；没有键或键没货时才退到标题弱匹配，并如实标记
/// [AudiobookMaterialMatch.contentIsWeakMatch] —— 正文是猜的这件事必须能传到
/// UI，不能让用户以为拿到的是原书。
AudiobookMaterialMatch matchAudiobookMaterial(
  AudiobookMaterialIndex index, {
  String? key,
  String? title,
}) {
  final String? titleKey = (title == null || title.trim().isEmpty)
      ? null
      : normalizeMediaSearchText(title);
  String? subtitlePath = key == null ? null : index.subtitleByKey[key];
  bool subtitleWeak = false;
  if (subtitlePath == null && titleKey != null) {
    subtitlePath = index.subtitleByTitle[titleKey];
    subtitleWeak = subtitlePath != null;
  }
  String? contentPath = key == null ? null : index.contentByKey[key];
  bool contentWeak = false;
  if (contentPath == null && titleKey != null) {
    contentPath = index.contentByTitle[titleKey];
    contentWeak = contentPath != null;
  }
  return AudiobookMaterialMatch(
    subtitlePath: subtitlePath,
    contentPath: contentPath,
    contentIsWeakMatch: contentWeak,
    subtitleIsWeakMatch: subtitleWeak,
  );
}
