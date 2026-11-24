/// 存量小说卡片「回到出处」坐标的重定位（拍板 hSZjfrcejt，BUG-5049 的存量修复）。
///
/// BUG-5049 修复（6463f4cf00）之前，制卡把**音频匹配坐标**（JS `getMatchableOffset`：
/// 白名单 UTF-16 码元数，拉丁 / 数字逐字母计）写进了 `CardSourceLink.charOffset /
/// charLength` 与制卡历史 `mined_sentences.norm_char_offset / length`；回看按**学习
/// 单位坐标**（`getNormalizedOffset`）落位，句前有拉丁串 / 数字的卡高亮整体错位。
/// 链接本身不带口径标记，旧值与新值无从分辨，所以按卡上存的句子文本在原章里核对：
///
/// 1. **学习单位口径核对通过**：存的区间按学习单位读出来的文字落在卡上某段文字里
///    → 已是对的（新卡、或句前没有拉丁串的旧卡，两套坐标恰好相等），不动。
/// 2. **匹配坐标口径核对通过**：存的区间按匹配坐标读出来的文字落在卡上某段文字里
///    → 旧坐标，精确换算成学习单位区间（与有声书 cue 换算同一张表）。
/// 3. 两种口径都对不上（书改过、旧版解析不同）→ 按文字在章里重新找：取卡上能在本章
///    找到的最长一段文字，多处出现取离旧起点最近的一处。
/// 4. 还找不到 → 定位不到，保留原值。
///
/// 结果幂等：第 2、3 步写回的区间再跑一遍会在第 1 步核对通过。
///
/// 章节文本口径与 [validateReaderSourceLocator] / 阅读器 `nodeStartOffsets` 相同（DOM
/// 文本节点逐个计、去掉 `<rt>` / `<rp>`），由 [ReaderAudioPositionIndex] 一次 FFI 建好。
library;

import 'package:fushi_audio/fushi_audio.dart' show AudioTextNormalizer;
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';

import 'package:fushi/src/reader/reader_audio_position.dart';

/// 第 3 步按文字重新找时，卡上文字归一化后至少要这么长才拿来找（太短的词在章里到处都是，
/// 找到的不代表那张卡）。第 1、2 步是核对已有区间，不受此限。
const int kReaderSourceRelocationMinSearchLength = 2;

/// 一条待核对的出处。
class ReaderSourceRelocationRequest {
  const ReaderSourceRelocationRequest({
    required this.chapterIndex,
    required this.offset,
    required this.length,
    required this.texts,
  });

  final int chapterIndex;
  final int offset;

  /// 存的区间长度；旧链接可能没有（null / 0），此时只能走第 3 步。
  final int? length;

  /// 卡上可能是原句的纯文字（例句、制卡历史的 sentence 列、词条……），已去标签。
  final List<String> texts;
}

enum ReaderSourceRelocationStatus {
  /// 存的区间已经是学习单位坐标，不用改。
  verified,

  /// 改写成了 [ReaderSourceRelocation.offset] / [ReaderSourceRelocation.length]。
  relocated,

  /// 章不在 / 卡上文字在本章找不到：保留原值。
  notLocated,
}

class ReaderSourceRelocation {
  const ReaderSourceRelocation.verified()
    : status = ReaderSourceRelocationStatus.verified,
      offset = null,
      length = null;

  const ReaderSourceRelocation.notLocated()
    : status = ReaderSourceRelocationStatus.notLocated,
      offset = null,
      length = null;

  const ReaderSourceRelocation.relocated({
    required int this.offset,
    required int this.length,
  }) : status = ReaderSourceRelocationStatus.relocated;

  final ReaderSourceRelocationStatus status;
  final int? offset;
  final int? length;

  @override
  bool operator ==(Object other) =>
      other is ReaderSourceRelocation &&
      other.status == status &&
      other.offset == offset &&
      other.length == length;

  @override
  int get hashCode => Object.hash(status, offset, length);

  @override
  String toString() => switch (status) {
    ReaderSourceRelocationStatus.relocated =>
      'ReaderSourceRelocation.relocated($offset, $length)',
    _ => 'ReaderSourceRelocation.${status.name}()',
  };
}

/// 在 [chapter]（null = 章不存在）里核对 / 重定位一条出处。纯函数。
ReaderSourceRelocation relocateReaderSourceSpan(
  ReaderAudioPositionIndex? chapter,
  ReaderSourceRelocationRequest request,
) {
  if (chapter == null) return const ReaderSourceRelocation.notLocated();
  final List<String> needles =
      <String>{
          for (final String text in request.texts)
            if (AudioTextNormalizer.normalize(text) case final String n
                when n.isNotEmpty)
              n,
        }.toList()
        // 长的在前：第 3 步优先用整句，找不到才退到更短的文字。
        ..sort((String a, String b) => b.length.compareTo(a.length));
  if (needles.isEmpty) return const ReaderSourceRelocation.notLocated();
  bool onCard(String? fragment) =>
      fragment != null &&
      fragment.isNotEmpty &&
      needles.any((String n) => n.contains(fragment));

  final int offset = request.offset;
  final int length = request.length ?? 0;
  // 1. 学习单位口径。
  if (length > 0 && onCard(chapter.matchableTextForStudySpan(offset, length))) {
    return const ReaderSourceRelocation.verified();
  }
  // 2. 匹配坐标口径（BUG-5049 之前的旧值）：精确换算。
  final String text = chapter.matchableText;
  if (length > 0 &&
      offset >= 0 &&
      offset + length <= text.length &&
      onCard(text.substring(offset, offset + length))) {
    final ({int offset, int length})? span = chapter.studyRangeForFragment(
      matchableStart: offset,
      matchableEnd: offset + length,
    );
    if (span != null && span.length > 0) return _result(request, span);
  }
  // 3. 按文字重新找：最长的、能找到的那段；多处出现取离旧起点最近的。
  for (final String needle in needles) {
    if (needle.length < kReaderSourceRelocationMinSearchLength) continue;
    final List<int> hits = chapter.matchableOccurrences(needle);
    if (hits.isEmpty) continue;
    int best = hits.first;
    for (final int at in hits) {
      if ((at - offset).abs() < (best - offset).abs()) best = at;
    }
    final ({int offset, int length})? span = chapter.studyRangeForFragment(
      matchableStart: best,
      matchableEnd: best + needle.length,
    );
    if (span != null && span.length > 0) return _result(request, span);
  }
  return const ReaderSourceRelocation.notLocated();
}

ReaderSourceRelocation _result(
  ReaderSourceRelocationRequest request,
  ({int offset, int length}) span,
) => span.offset == request.offset && span.length == request.length
    ? const ReaderSourceRelocation.verified()
    : ReaderSourceRelocation.relocated(
        offset: span.offset,
        length: span.length,
      );

/// [book] 里一批出处的核对结果（与 [requests] 等长同序）。每章的索引只建一次。
List<ReaderSourceRelocation> relocateReaderSourceSpansInBook(
  EpubBook book,
  List<ReaderSourceRelocationRequest> requests,
) {
  final Map<int, ReaderAudioPositionIndex?> chapters =
      <int, ReaderAudioPositionIndex?>{};
  ReaderAudioPositionIndex? chapter(int index) => chapters.putIfAbsent(
    index,
    () => index < 0 || index >= book.chapters.length
        ? null
        : ReaderAudioPositionIndex.fromChapterHtml(book.chapters[index].html),
  );
  return <ReaderSourceRelocation>[
    for (final ReaderSourceRelocationRequest r in requests)
      relocateReaderSourceSpan(chapter(r.chapterIndex), r),
  ];
}

/// 后台 isolate 入口：解析解压目录里的书再核对（解析整本 EPUB 与建索引都不该在 UI
/// isolate 上跑）。书解析失败时整批 [ReaderSourceRelocationStatus.notLocated]。
List<ReaderSourceRelocation> relocateReaderSourceSpansInExtractedBook(
  ({String extractDir, List<ReaderSourceRelocationRequest> requests}) args,
) {
  final EpubBook book;
  try {
    book = EpubParser.parseFromExtracted(args.extractDir);
  } on FormatException {
    return <ReaderSourceRelocation>[
      for (final ReaderSourceRelocationRequest _ in args.requests)
        const ReaderSourceRelocation.notLocated(),
    ];
  }
  return relocateReaderSourceSpansInBook(book, args.requests);
}
