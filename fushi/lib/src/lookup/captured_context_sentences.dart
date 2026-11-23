// 拍板台 rf--UcsGta：应用外查词「抓取上下文」拿到的整段文本 → 前后句。
//
// 抓取上下文（Windows UI Automation / macOS AX / Linux AT-SPI，见
// `SelectionCapture.captureForegroundContext`）交给 Dart 的是「选区 + 两侧各至多
// maxExpand 个字符」的一段平文本。以前只从里面截出选区所在的那一句当 `{sentence}`，
// 其余丢掉；这里把同一段文本按**同一个切句器**（[sentenceBoundsAt]，句读表与阅读器
// 一致）切成「前文句 / 当前句 / 后文句」，供高级制卡的句子分区加减前后句——与小说、
// 视频、漫画页同一个 [AdvancedMiningSentenceSection] 契约、同一份
// [MiningSentenceDraft] 草稿，不另做对话框。
//
// 缓冲两端是按字符数截的，最外侧那句多半只剩半句：两端被截断（选区到该端的距离
// 达到 maxExpand）时丢掉贴着那一端的句子，不把半句塞进卡片。

import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';

/// 抓取上下文切出来的句子：当前句 + 它前后的完整句（都已 trim、去掉空白句）。
class CapturedSentenceContext {
  const CapturedSentenceContext({
    required this.before,
    required this.current,
    required this.after,
    this.currentSelStart,
  });

  /// 当前句之前的句子，阅读顺序（紧挨当前句的那句在末尾）。
  final List<String> before;

  /// 选区所在的那一句（与 [extractSentenceAt] 的结果相同）。
  final String current;

  /// 选区在 [current] 里的起始 UTF-16 偏移（预览高亮用）；未知为 null。
  final int? currentSelStart;

  /// 当前句之后的句子，阅读顺序（紧挨当前句的那句在 [0]）。
  final List<String> after;

  /// 有没有可加的前后句（没有就不给句子分区，对话框保持原样）。
  bool get hasNeighbours => before.isNotEmpty || after.isNotEmpty;

  /// 紧挨当前句的「上 [prevCount] 句 / 下 [nextCount] 句」（阅读顺序），超出可用
  /// 句数时取到头为止。
  ({List<String> prev, List<String> next}) around({
    required int prevCount,
    required int nextCount,
  }) {
    final int p = prevCount.clamp(0, before.length);
    final int n = nextCount.clamp(0, after.length);
    return (
      prev: List<String>.unmodifiable(before.sublist(before.length - p)),
      next: List<String>.unmodifiable(after.sublist(0, n)),
    );
  }
}

/// 把抓取上下文的缓冲 [contextText]（选区 `[selStart, selStart+selLen)`，UTF-16 下标）
/// 切成 [CapturedSentenceContext]。缓冲为空或选区越界返回 null。
///
/// [maxExpand] 是抓取时两侧各取的字符上限：选区到某一端的距离达到它，说明那一端是
/// 截断的，贴着那一端的句子不完整，丢掉。null = 不知道（两端都当完整）。
CapturedSentenceContext? splitCapturedContext({
  required String contextText,
  required int selStart,
  required int selLen,
  int? maxExpand,
}) {
  final int len = contextText.length;
  if (len == 0 || selLen <= 0 || selStart < 0 || selStart + selLen > len) {
    return null;
  }
  final int selEnd = selStart + selLen;
  final bool leadingCut = maxExpand != null && selStart >= maxExpand;
  final bool trailingCut = maxExpand != null && len - selEnd >= maxExpand;

  final SentenceExtractionResult current = extractSentenceAt(
    contextText,
    selStart,
    selLen,
  );
  final ({int start, int end}) cur = sentenceBoundsAt(
    contextText,
    selStart,
    selEnd,
  );

  // 前文：从当前句起点往回一句一句切。起点之前是上一句的句末标点（后面可能还跟着
  // 归上一句的闭括号），越过闭括号以那个标点为锚取上一句的边界；终点夹到下一句起点，
  // 与当前句的切法不重叠。
  final List<String> before = <String>[];
  int cursor = cur.start;
  while (cursor > 0) {
    int anchor = cursor - 1;
    while (anchor > 0 &&
        kTrailingSentenceChars.contains(contextText[anchor]) &&
        !kSentenceDelimiters.contains(contextText[anchor])) {
      anchor--;
    }
    final ({int start, int end}) b = sentenceBoundsAt(
      contextText,
      anchor,
      anchor,
    );
    if (b.start == 0 && leadingCut) break;
    final String s = contextText.substring(b.start, cursor).trim();
    if (s.isNotEmpty) before.insert(0, s);
    cursor = b.start;
  }

  // 后文：从当前句终点往后切，起点不早于上一句终点（句末标点后的闭括号已归上一句）。
  final List<String> after = <String>[];
  cursor = cur.end;
  while (cursor < len) {
    final ({int start, int end}) b = sentenceBoundsAt(
      contextText,
      cursor,
      cursor,
    );
    // 截断端的最后一段只有真碰到句末标点（[kSentenceDelimiters]）才算完整句：
    // 以「、」「）」「」」之类收尾的是被截在句中的半句，同样丢掉。
    if (b.end == len &&
        trailingCut &&
        !_containsDelimiter(contextText, cursor, b.end)) {
      break;
    }
    final String s = contextText.substring(cursor, b.end).trim();
    if (s.isNotEmpty) after.add(s);
    cursor = b.end;
  }

  return CapturedSentenceContext(
    before: List<String>.unmodifiable(before),
    current: current.sentence,
    currentSelStart: current.sentence.isEmpty ? null : current.selStart,
    after: List<String>.unmodifiable(after),
  );
}

/// `text[from, to)` 里有没有句末标点。[sentenceBoundsAt] 的前向扫描停在第一个句末
/// 标点（再吞掉其后的闭括号），所以一段切到缓冲尾的句子含句末标点 = 它是完整的。
bool _containsDelimiter(String text, int from, int to) {
  for (int i = from; i < to; i++) {
    if (kSentenceDelimiters.contains(text[i])) return true;
  }
  return false;
}

/// 高级制卡的句子分区：前后句来自 [context]，选择落进 [draft]（与阅读器 / 视频 /
/// 歌词同一份草稿语义：整体设置上下文、按原句记手改与移除）。
AdvancedMiningSentenceSection capturedContextSentenceSection({
  required MiningSentenceDraft draft,
  required CapturedSentenceContext context,
}) => AdvancedMiningSentenceSection(
  fetchPreview: () async => buildSentenceContextPreview(
    draft: draft,
    current: context.current,
    currentOffset: context.currentSelStart,
  ),
  setContext: (int prevCount, int nextCount) async {
    final ({List<String> prev, List<String> next}) picked = context.around(
      prevCount: prevCount,
      nextCount: nextCount,
    );
    draft.setContext(
      prev: <MiningDraftSentence>[
        for (final String s in picked.prev) MiningDraftSentence(sentence: s),
      ],
      next: <MiningDraftSentence>[
        for (final String s in picked.next) MiningDraftSentence(sentence: s),
      ],
    );
    return draft.length;
  },
  editSentence: (SentenceContextSlot slot, int index, String text) async {
    draft.editSentence(slot: slot, index: index, text: text);
  },
  removeSentence: (SentenceContextSlot slot, int index, bool removed) async {
    draft.setSentenceRemoved(slot: slot, index: index, removed: removed);
  },
);
