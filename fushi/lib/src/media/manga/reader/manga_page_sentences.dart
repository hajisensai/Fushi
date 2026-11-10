/// 漫画一页 OCR 文本的「句子」视图：纯函数，不碰 WebView / 剪贴板。
///
/// 一句 = overlay 的一个句子分组（[mangaBlockSentenceGroups]，跨块的一句只算一次，
/// 组号与 overlay 的 `data-manga-sentence-group` 同源）。组间先后取组内**正文块**
/// 在 [computeReadingOrder] 里的最小名次；注音（振假名）块既不进句子文本，也不参与
/// 排序——它们很小，会被聚进面板，干扰面板聚类。
///
/// 朗读（manga_read_aloud_plan.dart）与「复制 OCR 文本」（反馈 hjUlprxxKI）共用这
/// 一份排序，复制出来的整页文本与朗读顺序一致。
library;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/reading_order.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart';

/// 一页里的一句：[group] 是 overlay 的句子分组号，[sentence] 是整句 OCR 原文
/// （不含注音块）。
typedef MangaPageSentence = ({int group, String sentence});

/// [page] 按阅读顺序排好的句子。[rightToLeft] 是本卷翻页方向（日漫 RTL）。
List<MangaPageSentence> mangaPageSentencesInReadingOrder(
  MokuroImage page, {
  required bool rightToLeft,
}) {
  final List<MangaBlockSentence> groups = mangaBlockSentenceGroups(page);
  if (groups.isEmpty) return const <MangaPageSentence>[];

  // 只拿正文块排序。
  final List<int> bodyBlocks = <int>[
    for (int i = 0; i < groups.length; i++)
      if (!groups[i].ruby) i,
  ];
  final List<OcrRect> rects = <OcrRect>[
    for (final int i in bodyBlocks) _ocrRect(page.blocks[i].rectangle),
  ];
  final List<int> order = computeReadingOrder(rects, rightToLeft: rightToLeft);
  final Map<int, int> rankOfBlock = <int, int>{
    for (int rank = 0; rank < order.length; rank++)
      bodyBlocks[order[rank]]: rank,
  };

  // 组 → 组内正文块的最小名次 + 整句文本。
  final Map<int, int> groupRank = <int, int>{};
  final Map<int, String> groupText = <int, String>{};
  for (int i = 0; i < groups.length; i++) {
    final int? rank = rankOfBlock[i];
    if (rank == null) continue;
    final int group = groups[i].group;
    groupText[group] = groups[i].sentence;
    final int? best = groupRank[group];
    if (best == null || rank < best) groupRank[group] = rank;
  }
  final List<int> orderedGroups = groupRank.keys.toList()
    ..sort((int a, int b) {
      final int byRank = groupRank[a]!.compareTo(groupRank[b]!);
      return byRank != 0 ? byRank : a.compareTo(b);
    });
  return <MangaPageSentence>[
    for (final int group in orderedGroups)
      (group: group, sentence: groupText[group]!),
  ];
}

/// 「复制文本」：句子分组 [group] 的整句（跨列 / 跨块合成一句，不含注音）。
/// 组号不存在或整句是空白时返回 null。
String? mangaSentenceGroupCopyText(MokuroImage page, int group) {
  for (final MangaBlockSentence assignment in mangaBlockSentenceGroups(page)) {
    if (assignment.group != group) continue;
    final String text = assignment.sentence.trim();
    return text.isEmpty ? null : text;
  }
  return null;
}

/// 「复制本页文本」：本页全部句子按阅读顺序一行一句；没有任何文字时返回 null。
String? mangaPageCopyText(MokuroImage page, {required bool rightToLeft}) {
  final List<String> lines = <String>[
    for (final MangaPageSentence s in mangaPageSentencesInReadingOrder(
      page,
      rightToLeft: rightToLeft,
    ))
      if (s.sentence.trim().isNotEmpty) s.sentence.trim(),
  ];
  return lines.isEmpty ? null : lines.join('\n');
}

OcrRect _ocrRect(MokuroRect r) =>
    OcrRect(left: r.left, top: r.top, right: r.right, bottom: r.bottom);
