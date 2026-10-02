import 'dart:convert';

import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi/src/sync/position_converter.dart';
import 'package:path/path.dart' as p;

/// `normCharOffset` 的满刻度（章内 0..10000）。
const int _kMaxNormOffset = 10000;

/// 阅读器自动标记读完的阈值（`reader_fushi/navigation.part.dart`：最后一章且
/// 章内进度 ≥ 0.999）。导入保留这条判据（Hoshi「标记已读」写的就是末章末尾）。
const int _kCompletedNormThreshold = 9990;

/// 导入额外认的「读完」：书签处已读字数占全书 ≥ 99%（BUG-2870）。
///
/// 阅读器是**边读边判**——翻过最后一页就记下读完；导入只拿到 Hoshi 的一张书签快照。
/// 轻小说正文后常挂着后记 / 奥付 / 广告页这几节短章（实测几十到三百字、或纯图 0 字），
/// 用户读完正文就不再往后翻，书签停在正文最后一章，「末章末尾」一条就把这些读完的书
/// 全漏掉（用户库里 18 本 99.6%–100% 的書一本都没标读完）。剩下不到 1% 的字数
/// 只可能是这些尾页，不会是正文。
const double _kCompletedBookRatio = 0.99;

/// Fushi `EpubBooks.chaptersJson` 里的一章（只取映射要用的两个字段）。
class FushiChapterRef {
  const FushiChapterRef({required this.href, required this.characters});

  /// 相对解压根的完整路径（`OEBPS/Text/ch1.xhtml` 形态，已 percent-decode）。
  final String href;
  final int characters;
}

/// 书签映射走的是哪条路（进导入报告 / 测试断言）。
enum ExternalReaderPositionMethod {
  /// 按 manifest 路径对上了 Fushi 的章节。
  chapterHref,

  /// 章节对不上，按全书字符比例换算。
  bookRatio,

  /// 没有 bookinfo，只能直接信 spine 下标（Fushi 章节表与 spine 通常一致）。
  spineIndex,
}

class ExternalReaderMappedPosition {
  const ExternalReaderMappedPosition({
    required this.sectionIndex,
    required this.normCharOffset,
    required this.method,
    required this.completed,
  });

  final int sectionIndex;
  final int normCharOffset;
  final ExternalReaderPositionMethod method;

  /// 映射后已在最后一章末尾，或已读字数占全书 ≥ 99%（见 [_kCompletedBookRatio]）。
  final bool completed;
}

/// 解析 `EpubBooks.chaptersJson`；形态不对（漫画书写的是 `'[]'`）返回空表。
List<FushiChapterRef> parseFushiChapterRefs(String chaptersJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(chaptersJson);
  } on FormatException {
    return const <FushiChapterRef>[];
  }
  if (decoded is! List) return const <FushiChapterRef>[];
  return <FushiChapterRef>[
    for (final Object? item in decoded)
      if (item is Map)
        FushiChapterRef(
          href: item['href'] is String ? item['href'] as String : '',
          characters: item['characters'] is num
              ? (item['characters'] as num).toInt()
              : 0,
        ),
  ];
}

/// 把 Hoshi 书签映射成 Fushi 的 `(sectionIndex, normCharOffset)`。
///
/// **不能直接用 `bookmark.chapterIndex` 当 sectionIndex**：它是 spine 下标，而
/// Fushi 解析 spine 时会静默跳过非 HTML / 缺文件的 itemref（`_parseSpine`），两边
/// 下标会错位。优先级：
/// 1. 在 `bookinfo.chapterInfo` 里找到书签所在章（先按 spineIndex，再按字符区间），
///    用它的 manifest 路径对上 Fushi 的章节 href；章内比例用字符偏移
///    `(characterCount − currentTotal) / chapterCount` 算（两边字数口径都是ッツ系，
///    比 `progress` 这种滚动比例更稳），越界才退回 `progress`。
/// 2. 章节对不上时，按全书字符比例 × Fushi 总字数经 [fromExploredCharCount] 换算。
/// 3. 没有 bookinfo 时只能信 spine 下标（越界则放弃）。
///
/// [chapters] 为空（漫画 / 无章节）返回 null——没有可落的阅读位置。
ExternalReaderMappedPosition? mapExternalReaderBookmark({
  required ExternalReaderBookmark bookmark,
  required ExternalReaderBookInfo? bookInfo,
  required List<FushiChapterRef> chapters,
}) {
  if (chapters.isEmpty) return null;

  if (bookInfo != null && bookInfo.chapters.isNotEmpty) {
    final ExternalReaderChapterSpan? span = _spanForBookmark(
      bookmark,
      bookInfo,
    );
    if (span != null) {
      final int? index = matchFushiChapterIndex(span.manifestPath, chapters);
      if (index != null) {
        return _position(
          sectionIndex: index,
          fraction: _inChapterFraction(bookmark, span),
          method: ExternalReaderPositionMethod.chapterHref,
          chapters: chapters,
        );
      }
    }
  }

  final int sourceTotal = bookInfo?.characterCount ?? 0;
  if (sourceTotal > 0) {
    final double ratio = (bookmark.characterCount / sourceTotal).clamp(
      0.0,
      1.0,
    );
    final List<ChapterCharInfo> infos = <ChapterCharInfo>[
      for (final FushiChapterRef c in chapters)
        ChapterCharInfo(characters: c.characters),
    ];
    final int fushiTotal = totalCharacterCount(infos);
    if (fushiTotal > 0) {
      final ({int sectionIndex, int normCharOffset}) mapped =
          fromExploredCharCount(
            exploredCharCount: (ratio * fushiTotal).round(),
            chapters: infos,
          );
      return ExternalReaderMappedPosition(
        sectionIndex: mapped.sectionIndex,
        normCharOffset: mapped.normCharOffset,
        method: ExternalReaderPositionMethod.bookRatio,
        completed: _isCompleted(
          mapped.sectionIndex,
          mapped.normCharOffset,
          chapters,
        ),
      );
    }
  }

  if (bookInfo == null &&
      bookmark.chapterIndex >= 0 &&
      bookmark.chapterIndex < chapters.length) {
    return _position(
      sectionIndex: bookmark.chapterIndex,
      fraction: bookmark.progress,
      method: ExternalReaderPositionMethod.spineIndex,
      chapters: chapters,
    );
  }
  return null;
}

ExternalReaderChapterSpan? _spanForBookmark(
  ExternalReaderBookmark bookmark,
  ExternalReaderBookInfo info,
) {
  for (final ExternalReaderChapterSpan span in info.chapters) {
    if (span.spineIndex == bookmark.chapterIndex) return span;
  }
  // spineIndex 缺失（老版本 bookinfo）时按字符区间找，同 Hoshi 自己的
  // `resolveCharacterPosition`：落在 [currentTotal, currentTotal + chapterCount)。
  for (final ExternalReaderChapterSpan span in info.chapters) {
    if (span.chapterCount <= 0) continue;
    if (bookmark.characterCount >= span.currentTotal &&
        bookmark.characterCount < span.currentTotal + span.chapterCount) {
      return span;
    }
  }
  return null;
}

double _inChapterFraction(
  ExternalReaderBookmark bookmark,
  ExternalReaderChapterSpan span,
) {
  if (span.chapterCount > 0) {
    final int within = bookmark.characterCount - span.currentTotal;
    if (within >= 0 && within <= span.chapterCount) {
      return within / span.chapterCount;
    }
  }
  return bookmark.progress;
}

ExternalReaderMappedPosition _position({
  required int sectionIndex,
  required double fraction,
  required ExternalReaderPositionMethod method,
  required List<FushiChapterRef> chapters,
}) {
  final int norm = (fraction.clamp(0.0, 1.0) * _kMaxNormOffset).round().clamp(
    0,
    _kMaxNormOffset,
  );
  return ExternalReaderMappedPosition(
    sectionIndex: sectionIndex,
    normCharOffset: norm,
    method: method,
    completed: _isCompleted(sectionIndex, norm, chapters),
  );
}

bool _isCompleted(int sectionIndex, int norm, List<FushiChapterRef> chapters) {
  if (sectionIndex == chapters.length - 1 && norm >= _kCompletedNormThreshold) {
    return true;
  }
  int total = 0;
  int read = 0;
  for (int i = 0; i < chapters.length; i++) {
    final int characters = chapters[i].characters < 0
        ? 0
        : chapters[i].characters;
    total += characters;
    if (i < sectionIndex) read += characters;
    if (i == sectionIndex) read += characters * norm ~/ _kMaxNormOffset;
  }
  // 全书 0 字（纯图）没有字数比例可言，只认上面的末章末尾。
  return total > 0 && read >= total * _kCompletedBookRatio;
}

/// Hoshi 的 manifest 路径（相对 OPF 目录）对上 Fushi 章节 href（相对解压根）。
///
/// 两侧先归一化（容错 percent-decode、`\`→`/`、去前导 `/`、去 `#`/`?` 尾巴、
/// posix normalize），再依次：完全相等 → 忽略大小写相等 → 按路径段边界的唯一后缀
/// （覆盖「一边相对 OPF、一边相对 zip 根」）→ 唯一文件名。任何一步出现多个候选
/// 即视为歧义，返回 null 交给比例换算，不猜。
int? matchFushiChapterIndex(
  String manifestPath,
  List<FushiChapterRef> chapters,
) {
  final String key = normalizeChapterHref(manifestPath);
  if (key.isEmpty) return null;
  final List<String> hrefs = <String>[
    for (final FushiChapterRef c in chapters) normalizeChapterHref(c.href),
  ];

  int? unique(bool Function(String href) test) {
    int? found;
    for (int i = 0; i < hrefs.length; i++) {
      if (hrefs[i].isEmpty || !test(hrefs[i])) continue;
      if (found != null) return -1;
      found = i;
    }
    return found;
  }

  final String lowerKey = key.toLowerCase();
  final String keyBase = p.posix.basename(lowerKey);
  final List<bool Function(String)> tests = <bool Function(String)>[
    (String h) => h == key,
    (String h) => h.toLowerCase() == lowerKey,
    (String h) {
      final String lh = h.toLowerCase();
      return lh.endsWith('/$lowerKey') || lowerKey.endsWith('/$lh');
    },
    (String h) => p.posix.basename(h.toLowerCase()) == keyBase,
  ];
  for (final bool Function(String) test in tests) {
    final int? hit = unique(test);
    if (hit == -1) return null;
    if (hit != null) return hit;
  }
  return null;
}

/// 章节路径的比较口径（见 [matchFushiChapterIndex]）。
String normalizeChapterHref(String raw) {
  String value = raw.trim();
  try {
    value = Uri.decodeFull(value);
  } on ArgumentError {
    // 非法 percent 序列：按原串比较。
  } on FormatException {
    // 同上。
  }
  value = value.replaceAll('\\', '/');
  final int cut = value.indexOf(RegExp(r'[#?]'));
  if (cut >= 0) value = value.substring(0, cut);
  while (value.startsWith('/')) {
    value = value.substring(1);
  }
  if (value.isEmpty) return '';
  final String normalized = p.posix.normalize(value);
  return normalized == '.' ? '' : normalized;
}
