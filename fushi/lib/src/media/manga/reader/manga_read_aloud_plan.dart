/// 漫画朗读的「一页读什么、按什么顺序读」：纯函数，不碰播放器 / WebView。
///
/// 一句 = overlay 的一个句子分组（[mangaBlockSentenceGroups]，跨块的一句只读一次，
/// 组号原样用于高亮）。组间先后取组内**正文块**在 [computeReadingOrder] 里的最小
/// 名次；注音（振假名）块既不进朗读文本，也不参与排序——它们很小，会被聚进面板，
/// 干扰面板聚类。
library;

import 'package:fushi_engine/media/manga/mokuro_geometry.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/reading_order.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_text_split.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart';

/// 一页里要读的一句。
class MangaReadAloudUtterance {
  const MangaReadAloudUtterance({
    required this.pageIndex,
    required this.group,
    required this.displayText,
    required this.spokenChunks,
  });

  /// 0-based 页码。
  final int pageIndex;

  /// overlay 的句子分组号（`data-manga-sentence-group`），高亮用。
  final int group;

  /// OCR 原文（未经发音词典）。
  final String displayText;

  /// 送进引擎的文本：经发音词典替换、再按引擎单次输入上限切好的块。
  final List<String> spokenChunks;

  @override
  String toString() =>
      'MangaReadAloudUtterance(p$pageIndex g$group "$displayText")';
}

/// 至少含一个字母 / 数字（含假名、汉字）才值得读；纯标点 / 拟声符号气泡跳过。
final RegExp _speakable = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// [page] 按阅读顺序排好的朗读句。[rightToLeft] 是本卷翻页方向（日漫 RTL）。
List<MangaReadAloudUtterance> planMangaPageReadAloud(
  MokuroImage page, {
  required int pageIndex,
  required bool rightToLeft,
  required List<TtsPronunciationRule> pronunciation,
  required int maxInputLength,
}) {
  final List<MangaBlockSentence> groups = mangaBlockSentenceGroups(page);
  if (groups.isEmpty) return const <MangaReadAloudUtterance>[];

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

  final List<MangaReadAloudUtterance> out = <MangaReadAloudUtterance>[];
  for (final int group in orderedGroups) {
    final String text = groupText[group]!.trim();
    if (!_speakable.hasMatch(text)) continue;
    final List<String> chunks = splitTtsTextForInputLimit(
      applyTtsPronunciation(text, pronunciation),
      maxLength: maxInputLength,
    );
    if (chunks.isEmpty) continue;
    out.add(
      MangaReadAloudUtterance(
        pageIndex: pageIndex,
        group: group,
        displayText: text,
        spokenChunks: List<String>.unmodifiable(chunks),
      ),
    );
  }
  return out;
}

OcrRect _ocrRect(MokuroRect r) =>
    OcrRect(left: r.left, top: r.top, right: r.right, bottom: r.bottom);
