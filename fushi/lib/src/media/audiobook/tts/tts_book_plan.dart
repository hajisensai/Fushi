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
import 'package:fushi_compute/fushi_compute.dart';
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
    final int chapterFirst = out.length;
    final List<({int start, int end})> raw = <({int start, int end})>[];
    final ({List<TtsTextSegment> segments, List<String> spoken}) fitted =
        splitTtsTextWithPronunciation(
          input,
          maxLength: maxLength,
          pronunciation: pronunciation,
        );
    final List<TtsTextSegment> segments = fitted.segments;
    // 每句之前的间隙与句子本身各占一段，整章一次归一化（一次 FFI）：第 j 段的起点就是
    // 前 j 段归一化长度之和，即逐段累加出来的归一化偏移。
    final List<String> pieces = <String>[];
    int rawCursor = 0;
    for (final TtsTextSegment seg in segments) {
      pieces
        ..add(input.text.substring(rawCursor, seg.start))
        ..add(seg.text);
      rawCursor = seg.end;
    }
    final ({String text, List<int> starts}) norm =
        AudioTextNormalizer.normalizeConcat(pieces);
    for (int i = 0; i < segments.length; i++) {
      final TtsTextSegment seg = segments[i];
      final int matchStart = norm.starts[2 * i + 1];
      final int matchEnd = 2 * i + 2 < pieces.length
          ? norm.starts[2 * i + 2]
          : norm.text.length;
      // 整句没有可匹配字符（纯标点 / 符号）：阅读器高亮不到，也不值得读。
      if (matchEnd == matchStart) continue;
      final ({int offset, int length})? study = index.studyRangeForFragment(
        matchableStart: matchStart,
        matchableEnd: matchEnd,
      );
      out.add(
        TtsPlanSentence(
          section: section,
          href: book.chapters[section].href,
          text: seg.text,
          spokenText: fitted.spoken[i],
          matchStart: matchStart,
          matchEnd: matchEnd,
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
  bool advance(
    List<int> sorted,
    int cursor,
    int from,
    int to,
    void Function(int) save,
  ) {
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
    final bool paragraph = advance(blockEnds, b, from, to, (int c) => b = c);
    final bool scene = advance(sceneBreaks, s, from, to, (int c) => s = c);
    out.add((endsParagraph: paragraph, sceneBreakAfter: !last && scene));
  }
  return out;
}

/// 一句的原文区间（章内 UTF-16）、显示原文与合成文本。
typedef TtsTextSegment = TtsSplitSegment;

/// 按句末标点切句；块级元素边界与场景分隔（[EpubPlainTextWithRuby.blockEnds] /
/// `sceneBreaks`）也是句界；ruby 底本是不可拆的整体（合成用读音，显示用底本）；
/// 单句合成文本不超过 [maxLength]（超长句先在逗号类软切点断，再硬断）。
///
/// 整章一次交给原生内核（`native/fushi_compute/src/parse/tts_split.rs`，规则细节见
/// 那里的模块注释）；这是唯一实现，没有 Dart 回退。
List<TtsTextSegment> splitTtsText(
  EpubPlainTextWithRuby input, {
  required int maxLength,
}) {
  return TtsSplitNative.instance.split(
    input.text,
    rubies: <TtsSplitRuby>[
      for (final EpubRubyAnnotation ruby in input.rubies)
        (start: ruby.start, end: ruby.end, reading: ruby.reading),
    ],
    blockEnds: input.blockEnds,
    sceneBreaks: input.sceneBreaks,
    maxLength: maxLength,
  );
}

/// 切句并套用发音词典，保证每句**套用后**的合成文本不超过 [maxLength]。
///
/// 发音词典在切句之后才替换，替换可能把文本撑长（「AI」→「エーアイ」、人名换成
/// 长读音）：按引擎上限刚好切满的句子替换后会超长，引擎直接拒收（谷歌翻译朗读上限
/// 180 字，超了回 400），朗读停在那句。这里按超出量收紧切句上限重切本章，直到全部
/// 放得下；收紧到原上限的 1/4（且不低于切句内核允许的最小值 8）仍放不下（规则把
/// 文本放大了 4 倍以上），超长句退回不套用词典的读法（不超过上限）——宁可读原写法，
/// 也不让整句被引擎拒掉。
({List<TtsTextSegment> segments, List<String> spoken})
splitTtsTextWithPronunciation(
  EpubPlainTextWithRuby input, {
  required int maxLength,
  List<TtsPronunciationRule> pronunciation = const <TtsPronunciationRule>[],
}) {
  // 切句内核要求上限至少 8（`TtsSplitNative.split`）。
  final int quarter = maxLength ~/ 4 < 8 ? 8 : maxLength ~/ 4;
  final int floor = quarter > maxLength ? maxLength : quarter;
  int limit = maxLength;
  while (true) {
    final List<TtsTextSegment> segments = splitTtsText(input, maxLength: limit);
    final List<String> spoken = <String>[
      for (final TtsTextSegment seg in segments)
        applyTtsPronunciation(seg.spokenText, pronunciation),
    ];
    int overflow = 0;
    for (final String text in spoken) {
      if (text.length - maxLength > overflow) {
        overflow = text.length - maxLength;
      }
    }
    if (overflow == 0) return (segments: segments, spoken: spoken);
    if (limit <= floor) {
      return (
        segments: segments,
        spoken: <String>[
          for (int i = 0; i < segments.length; i++)
            spoken[i].length > maxLength ? segments[i].spokenText : spoken[i],
        ],
      );
    }
    limit = limit - overflow < floor ? floor : limit - overflow;
  }
}

/// 朗读用：把同一段落里相邻的过短句子并成一次合成。
///
/// 自建引擎每次请求有约 2 秒的固定开销（实测 GPT-SoVITS v5：7 字的句子 2.2 秒出声、
/// 实时率 2 以上），倍速朗读时短句一多就跟不上。并句只发生在同一章、同一段落内，
/// 不跨段 / 场景分隔，合并后合成文本不超过 [maxLength]；高亮覆盖合并后的整段。
///
/// 多声优朗读传 [voiceSlotOf]（每句归哪个声音槽：配了声音的角色 / 默认声音）：只有
/// 同一个槽的相邻句才并，否则两个角色的台词会共用一个声音。槽按「角色」而不是按
/// 预设 id 分：播放中换默认声音后，原来与某角色同预设而并在一起的句子不会读串。
/// 合并句沿用首句的句首坐标，按坐标再查槽仍落在同一个槽。
///
/// **制作有声书不用它**：制作台按单句生成、逐句校对，不需要摊薄请求开销。
TtsBookPlan mergeShortTtsSentences(
  TtsBookPlan plan, {
  required int maxLength,
  int minLength = 16,
  String Function(TtsPlanSentence sentence)? voiceSlotOf,
}) {
  final List<TtsPlanSentence> out = <TtsPlanSentence>[];
  for (final TtsPlanSentence s in plan.sentences) {
    final TtsPlanSentence? last = out.isEmpty ? null : out.last;
    final bool canMerge =
        last != null &&
        last.section == s.section &&
        !last.endsParagraph &&
        !last.sceneBreakAfter &&
        (last.spokenText.length < minLength ||
            s.spokenText.length < minLength) &&
        last.spokenText.length + s.spokenText.length <= maxLength &&
        (voiceSlotOf == null || voiceSlotOf(last) == voiceSlotOf(s));
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
