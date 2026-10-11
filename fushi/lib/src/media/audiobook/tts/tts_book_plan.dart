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
    }
  }
  return TtsBookPlan(out);
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

/// 按句末标点切句；ruby 底本是不可拆的整体（合成用读音，显示用底本）；单句合成
/// 文本不超过 [maxLength]（超长句先在逗号类软切点断，再硬断）。
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

  int first = 0;
  while (first < atoms.length) {
    int i = first;
    int spoken = 0;
    int lastSoft = -1;
    bool ended = false;
    while (i < atoms.length) {
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
    final bool overflowed = !ended && i < atoms.length;
    final int cut = overflowed && lastSoft > first ? lastSoft : i;
    emit(first, cut);
    first = cut;
  }
  return result;
}
