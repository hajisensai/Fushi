/// TTS 朗读的整书分句计划：每句的显示文本、合成文本（ruby 换读音）与三套坐标。
///
/// 坐标不混用：
/// - 原文 UTF-16（`chapterPlainTextWithRuby` 的 text）——切句用；
/// - 归一化匹配偏移（[AudioTextNormalizer]）——编进 cue 的 `fushi-cue://` 片段，
///   阅读器正文高亮 / 跨章跟随靠它；
/// - 阅读进度单位（[ReaderAudioPositionIndex]）——「从当前位置读」与目录定位。
///
/// 整书解析在后台 isolate 里做（大书逐章解析 DOM 要几百毫秒到数秒）。
library;

import 'dart:isolate';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';

import 'package:fushi/src/reader/reader_audio_position.dart';

class TtsPlanSentence {
  const TtsPlanSentence({
    required this.section,
    required this.href,
    required this.text,
    required this.spokenText,
    required this.matchStart,
    required this.matchEnd,
    required this.studyStart,
    required this.studyEnd,
    this.endsParagraph = false,
    this.sceneBreakAfter = false,
  });

  final int section;
  final String href;

  /// 显示 / 制卡用的原文（底本文字）。
  final String text;

  /// 送去合成的文本（ruby 底本换成读音）。
  final String spokenText;
  final int matchStart;
  final int matchEnd;
  final int studyStart;
  final int studyEnd;

  /// 本句是所在块级元素（段落 / 标题 / 列表项…）的最后一句。制作有声书按它加段落
  /// 停顿；朗读不看。
  final bool endsParagraph;

  /// 本句与同章下一句之间有场景分隔（`<hr>` / 空段落 / `◇◇◇` 这类分隔块）。
  final bool sceneBreakAfter;
}

class TtsBookPlan {
  const TtsBookPlan(this.sentences);

  final List<TtsPlanSentence> sentences;

  bool get isEmpty => sentences.isEmpty;
  int get length => sentences.length;

  /// 阅读位置（章 + 进度单位偏移）所在或之后的第一句；越过全书末尾返回 -1。
  int indexAtStudyOffset(int section, int studyOffset) {
    for (int i = 0; i < sentences.length; i++) {
      final TtsPlanSentence s = sentences[i];
      if (s.section > section ||
          (s.section == section && s.studyEnd > studyOffset)) {
        return i;
      }
    }
    return -1;
  }

  /// 断点（章 + 句首匹配偏移）对应的句；原句不在了取同章其后最近一句。
  int indexAtMatchStart(int section, int matchStart) {
    for (int i = 0; i < sentences.length; i++) {
      final TtsPlanSentence s = sentences[i];
      if (s.section > section ||
          (s.section == section && s.matchEnd > matchStart)) {
        return i;
      }
    }
    return -1;
  }
}

/// 在后台 isolate 构建整书计划。章节 HTML 惰性读盘，随 [book.chapters] 一起过界。
Future<TtsBookPlan> buildTtsBookPlan(
  EpubBook book, {
  required int maxLength,
  List<TtsPronunciationRule> pronunciation = const <TtsPronunciationRule>[],
}) {
  final EpubBook light = EpubBook(title: book.title, chapters: book.chapters);
  return Isolate.run(
    () => buildTtsBookPlanSync(
      light,
      maxLength: maxLength,
      pronunciation: pronunciation,
    ),
  );
}

TtsBookPlan buildTtsBookPlanSync(
  EpubBook book, {
  required int maxLength,
  List<TtsPronunciationRule> pronunciation = const <TtsPronunciationRule>[],
}) {
  final List<TtsPlanSentence> out = <TtsPlanSentence>[];
  for (int section = 0; section < book.chapters.length; section++) {
    if (book.isChapterNav(section)) continue;
    final EpubPlainTextWithRuby input = book.chapterPlainTextWithRuby(section);
    if (input.text.trim().isEmpty) continue;
    final ReaderAudioPositionIndex index =
        ReaderAudioPositionIndex.fromChapterHtml(book.chapters[section].html);
    int rawCursor = 0;
    int normCursor = 0;
    final int chapterFirst = out.length;
    final List<({int start, int end})> raw = <({int start, int end})>[];
    for (final TtsTextSegment seg in splitTtsText(
      input,
      maxLength: maxLength,
    )) {
      normCursor += AudioTextNormalizer.normalize(
        input.text.substring(rawCursor, seg.start),
      ).length;
      final int matchStart = normCursor;
      normCursor += AudioTextNormalizer.normalize(seg.text).length;
      rawCursor = seg.end;
      // 整句没有可匹配字符（纯标点 / 符号）：阅读器高亮不到，也不值得读。
      if (normCursor == matchStart) continue;
      final ({int offset, int length})? study = index.studyRangeForFragment(
        matchableStart: matchStart,
        matchableEnd: normCursor,
      );
      out.add(
        TtsPlanSentence(
          section: section,
          href: book.chapters[section].href,
          text: seg.text,
          spokenText: applyTtsPronunciation(seg.spokenText, pronunciation),
          matchStart: matchStart,
          matchEnd: normCursor,
          studyStart: study?.offset ?? 0,
          studyEnd: (study?.offset ?? 0) + (study?.length ?? 0),
        ),
      );
      raw.add((start: seg.start, end: seg.end));
    }
    final List<({bool endsParagraph, bool sceneBreakAfter})> marks =
        ttsSentenceBoundaryMarks(
      sentences: raw,
      blockEnds: input.blockEnds,
      sceneBreaks: input.sceneBreaks,
    );
    for (int k = 0; k < marks.length; k++) {
      final TtsPlanSentence s = out[chapterFirst + k];
      out[chapterFirst + k] = TtsPlanSentence(
        section: s.section,
        href: s.href,
        text: s.text,
        spokenText: s.spokenText,
        matchStart: s.matchStart,
        matchEnd: s.matchEnd,
        studyStart: s.studyStart,
        studyEnd: s.studyEnd,
        endsParagraph: marks[k].endsParagraph,
        sceneBreakAfter: marks[k].sceneBreakAfter,
      );
    }
  }
  return TtsBookPlan(out);
}

/// 一章里各句（原文区间，升序）与下一句之间有没有段落 / 场景边界。
///
/// 边界位置落在「本句末尾 .. 下一句开头」（含两端；块之间可能没有空白）就归本句；
/// 最后一句的「下一句开头」是章末。被计划跳过的纯符号段（`◇◇◇`）夹在两句之间，
/// 它的场景分隔自然落进前一句的区间。
List<({bool endsParagraph, bool sceneBreakAfter})> ttsSentenceBoundaryMarks({
  required List<({int start, int end})> sentences,
  required List<int> blockEnds,
  required List<int> sceneBreaks,
}) {
  // 各句区间升序、边界列表升序：两个游标单调前移，整章线性。
  int b = 0;
  int s = 0;
  bool advance(List<int> sorted, int cursor, int from, int to,
      void Function(int) save) {
    while (cursor < sorted.length && sorted[cursor] < from) {
      cursor++;
    }
    save(cursor);
    return cursor < sorted.length && sorted[cursor] <= to;
  }

  final List<({bool endsParagraph, bool sceneBreakAfter})> out =
      <({bool endsParagraph, bool sceneBreakAfter})>[];
  for (int k = 0; k < sentences.length; k++) {
    final int from = sentences[k].end;
    final bool last = k + 1 == sentences.length;
    final int to = last ? 1 << 40 : sentences[k + 1].start;
    final bool paragraph =
        advance(blockEnds, b, from, to, (int c) => b = c);
    final bool scene =
        advance(sceneBreaks, s, from, to, (int c) => s = c);
    out.add((endsParagraph: paragraph, sceneBreakAfter: !last && scene));
  }
  return out;
}

class TtsTextSegment {
  const TtsTextSegment({
    required this.start,
    required this.end,
    required this.text,
    required this.spokenText,
  });

  /// 章内原文 UTF-16 区间。
  final int start;
  final int end;
  final String text;
  final String spokenText;
}

const String _sentenceEnders = '。！？!?…\n';
const String _closers = '」』”’）)]】〉》»';

/// 台词引号的收尾（同时也在 [_closers] 里，紧跟句末标点时照常并入上一句）。
const String _quoteEnders = '」』';

/// 软切点：句子超长时优先在这些字后断开（读起来仍自然）。
const String _softBreaks = '、，,；;：:';

/// 按句末标点切句；块级元素边界与场景分隔（[EpubPlainTextWithRuby.blockEnds] /
/// `sceneBreaks`）也是句界；ruby 底本是不可拆的整体（合成用读音，显示用底本）；
/// 单句合成文本不超过 [maxLength]（超长句先在逗号类软切点断，再硬断）。
List<TtsTextSegment> splitTtsText(
  EpubPlainTextWithRuby input, {
  required int maxLength,
}) {
  if (maxLength < 8) throw ArgumentError.value(maxLength, 'maxLength');
  final String text = input.text;
  final Map<int, EpubRubyAnnotation> rubyAt = <int, EpubRubyAnnotation>{};
  int lastEnd = 0;
  for (final EpubRubyAnnotation ruby in input.rubies) {
    if (ruby.start < lastEnd ||
        ruby.start < 0 ||
        ruby.end > text.length ||
        ruby.end <= ruby.start ||
        ruby.reading.trim().isEmpty ||
        ruby.reading.length > maxLength ~/ 2) {
      continue;
    }
    rubyAt[ruby.start] = ruby;
    lastEnd = ruby.end;
  }

  // 原子：一个码点或一整个 ruby。
  final List<({int start, int end, String spoken})> atoms =
      <({int start, int end, String spoken})>[];
  int cursor = 0;
  while (cursor < text.length) {
    final EpubRubyAnnotation? ruby = rubyAt[cursor];
    if (ruby != null) {
      atoms.add((start: cursor, end: ruby.end, spoken: ruby.reading));
      cursor = ruby.end;
      continue;
    }
    final int unit = text.codeUnitAt(cursor);
    final bool pair =
        unit >= 0xD800 &&
        unit <= 0xDBFF &&
        cursor + 1 < text.length &&
        (text.codeUnitAt(cursor + 1) & 0xFC00) == 0xDC00;
    final int end = cursor + (pair ? 2 : 1);
    atoms.add((start: cursor, end: end, spoken: text.substring(cursor, end)));
    cursor = end;
  }

  final List<TtsTextSegment> result = <TtsTextSegment>[];
  void emit(int from, int to) {
    while (from < to && atoms[from].spoken.trim().isEmpty) {
      from++;
    }
    while (to > from && atoms[to - 1].spoken.trim().isEmpty) {
      to--;
    }
    if (to <= from) return;
    final int start = atoms[from].start;
    final int end = atoms[to - 1].end;
    result.add(
      TtsTextSegment(
        start: start,
        end: end,
        text: text.substring(start, end),
        spokenText: <String>[
          for (int i = from; i < to; i++) atoms[i].spoken,
        ].join(),
      ),
    );
  }

  // 块边界 / 场景分隔是硬句界：不带句末标点的标题、`◇◇◇` 这类分隔行不能和下一
  // 段并成一句（否则分隔符被读出来，段落停顿也落不到正确位置）。
  final List<int> hardBreaks = <int>{
    ...input.blockEnds,
    ...input.sceneBreaks,
  }.toList()
    ..sort();
  int hb = 0;

  int first = 0;
  while (first < atoms.length) {
    int i = first;
    int spoken = 0;
    int lastSoft = -1;
    bool ended = false;
    bool hardStop = false;
    while (hb < hardBreaks.length && hardBreaks[hb] <= atoms[first].start) {
      hb++;
    }
    final int nextBreak = hb < hardBreaks.length ? hardBreaks[hb] : 1 << 40;
    while (i < atoms.length) {
      if (i > first && atoms[i].start >= nextBreak) {
        hardStop = true;
        break;
      }
      final String original = text.substring(atoms[i].start, atoms[i].end);
      if (ended &&
          !_closers.contains(original) &&
          !_sentenceEnders.contains(original)) {
        break;
      }
      if (spoken + atoms[i].spoken.length > maxLength) break;
      spoken += atoms[i].spoken.length;
      i++;
      // 引号收尾也是句界：台词末尾常不带句号（「……ないわー」「うるせ……」），
      // 不在这里断就会把两个人的台词并成一句读。
      if (_sentenceEnders.contains(original) ||
          _quoteEnders.contains(original)) {
        ended = true;
      }
      if (_softBreaks.contains(original)) lastSoft = i;
    }
    if (i == first) i = first + 1; // 单个原子就超长（畸形 ruby 已在上面过滤）。
    final bool overflowed = !ended && !hardStop && i < atoms.length;
    final int cut = overflowed && lastSoft > first ? lastSoft : i;
    emit(first, cut);
    first = cut;
  }
  return result;
}
/// 朗读用：把同一段落里相邻的过短句子并成一次合成。
///
/// 自建引擎每次请求有约 2 秒的固定开销（实测 GPT-SoVITS v5：7 字的句子 2.2 秒出声、
/// 实时率 2 以上），倍速朗读时短句一多就跟不上。并句只发生在同一章、同一段落内，
/// 不跨段 / 场景分隔，合并后合成文本不超过 [maxLength]；高亮覆盖合并后的整段。
///
/// **制作有声书不用它**：选角表按单句记说话人，并句会让两个角色的台词共用一个声音。
TtsBookPlan mergeShortTtsSentences(
  TtsBookPlan plan, {
  required int maxLength,
  int minLength = 16,
}) {
  final List<TtsPlanSentence> out = <TtsPlanSentence>[];
  for (final TtsPlanSentence s in plan.sentences) {
    final TtsPlanSentence? last = out.isEmpty ? null : out.last;
    final bool canMerge = last != null &&
        last.section == s.section &&
        !last.endsParagraph &&
        !last.sceneBreakAfter &&
        (last.spokenText.length < minLength || s.spokenText.length < minLength) &&
        last.spokenText.length + s.spokenText.length <= maxLength;
    if (!canMerge) {
      out.add(s);
      continue;
    }
    out[out.length - 1] = TtsPlanSentence(
      section: last.section,
      href: last.href,
      text: last.text + s.text,
      spokenText: last.spokenText + s.spokenText,
      matchStart: last.matchStart,
      matchEnd: s.matchEnd,
      studyStart: last.studyStart,
      studyEnd: s.studyEnd,
      endsParagraph: s.endsParagraph,
      sceneBreakAfter: s.sceneBreakAfter,
    );
  }
  return TtsBookPlan(out);
}
