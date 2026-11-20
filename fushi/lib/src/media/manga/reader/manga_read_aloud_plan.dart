/// 漫画朗读的「一页读什么、按什么顺序读」：纯函数，不碰播放器 / WebView。
///
/// 一句 = overlay 的一个句子分组，跨块的一句只读一次，高亮框住组内全部块。句子与
/// 先后顺序取 [mangaPageSentencesInReadingOrder]（与「复制本页文本」同一份排序；
/// 注音块不进朗读文本、不参与排序）。
library;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:fushi_engine/tts/tts_text_split.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart'
    show mangaBlockSentenceGroups;
import 'package:fushi/src/media/manga/reader/manga_page_sentences.dart';

/// 一页里要读的一句。
class MangaReadAloudUtterance {
  const MangaReadAloudUtterance({
    required this.pageIndex,
    required this.group,
    required this.blocks,
    required this.displayText,
    required this.spokenChunks,
  });

  /// 0-based 页码。
  final int pageIndex;

  /// overlay 的句子分组号（`data-manga-sentence-group`），高亮用。
  final int group;

  /// 这句覆盖的 OCR 块下标（与 `page.blocks` 同下标，含注音块）：高亮框住全部。
  final List<int> blocks;

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
  List<TtsPronunciationRule> preSynthesis = const <TtsPronunciationRule>[],
  required int maxInputLength,
}) {
  final List<MangaPageSentence> sentences = mangaPageSentencesInReadingOrder(
    page,
    rightToLeft: rightToLeft,
  );

  final List<MangaReadAloudUtterance> out = <MangaReadAloudUtterance>[];
  final List<({int group, String sentence, bool ruby})> assignments =
      mangaBlockSentenceGroups(page);
  for (final MangaPageSentence sentence in sentences) {
    final int group = sentence.group;
    final String text = sentence.sentence.trim();
    if (!_speakable.hasMatch(text)) continue;
    final List<String> chunks = splitTtsTextForInputLimit(
      applyTtsSpokenRules(
        text,
        pronunciation: pronunciation,
        preSynthesis: preSynthesis,
      ),
      maxLength: maxInputLength,
    );
    if (chunks.isEmpty) continue;
    out.add(
      MangaReadAloudUtterance(
        pageIndex: pageIndex,
        group: group,
        blocks: List<int>.unmodifiable(<int>[
          for (int i = 0; i < assignments.length; i++)
            if (assignments[i].group == group) i,
        ]),
        displayText: text,
        spokenChunks: List<String>.unmodifiable(chunks),
      ),
    );
  }
  return out;
}
