import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';

/// 一条 cue 的显示文本：正文原文（命中时）或听写稿，外加落在这段原文里的
/// ruby（区间相对 [text]）。未命中 / 无 EPUB 时 [rubies] 为空。
class LyricsCueText {
  const LyricsCueText(this.text, this.rubies);

  const LyricsCueText.plain(String text)
    : this(text, const <EpubRubyAnnotation>[]);

  final String text;
  final List<EpubRubyAnnotation> rubies;
}

/// 两条 cue 之间的未认领正文至少这么多个有读音的字才在歌词页灰显
/// （[LyricsCueTextResolver.skippedTextBetween]）。
const int kLyricsSkippedTextMinChars = 2;

/// Resolves display text without changing transcript cues or their token timing.
/// Uses the same ruby-free chapter text and UTF-16 normalization as the matcher.
///
/// 章文本走 [EpubBook.chapterPlainTextWithRuby]——与 `chapterPlainText` 逐码元
/// 相同，顺手带回 ruby 区间，歌词页才能把振假名画回去（[resolveForCue]）。
class LyricsCueTextResolver {
  LyricsCueTextResolver(this.book);

  final EpubBook book;
  final Map<int, _Chapter> _chapters = <int, _Chapter>{};

  String textForCue(AudioCue cue) => resolveForCue(cue).text;

  LyricsCueText resolveForCue(AudioCue cue) {
    final SubtitleRematchFragment? fragment = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
    if (fragment == null ||
        fragment.sectionIndex < 0 ||
        fragment.sectionIndex >= book.chapters.length ||
        fragment.normCharStart < 0 ||
        fragment.normCharEnd <= fragment.normCharStart) {
      return LyricsCueText.plain(cue.text);
    }

    int start = fragment.normCharStart;
    int remaining = fragment.normCharEnd - start;
    final StringBuffer result = StringBuffer();
    final List<EpubRubyAnnotation> rubies = <EpubRubyAnnotation>[];
    for (
      int section = fragment.sectionIndex;
      section < book.chapters.length;
      section++
    ) {
      final _Chapter chapter = _chapter(section);
      final String normalized = chapter.norm.text;
      final bool first = section == fragment.sectionIndex;
      if (first &&
          (start >= normalized.length || !_isBoundary(normalized, start))) {
        return LyricsCueText.plain(cue.text);
      }
      final int available = normalized.length - start;
      // 句首开括号 / 破折号（「『――…）被归一化剥掉、落在匹配区间之外——按
      // [_gapSplit] 往回补上，歌词行才是「月が替わると…」而不是缺了左括号的半句。
      final int from = first ? _headStart(chapter, start) : 0;
      if (remaining <= available) {
        final int end = start + remaining;
        if (!_isBoundary(normalized, end)) return LyricsCueText.plain(cue.text);
        // 句末标点 / 闭括号 / 破折号（。」』！？…――）同样被归一化剥掉：matcher 的
        // 区间止于最后一个「有读音」的字，直接按它截取正文会让每行都丢掉句号（用户
        // 2026-10-04 报「歌词模式没有标点」）。往后补到 [_gapSplit] 的切点。
        final int to = _tailEnd(chapter, end);
        _collectRubies(rubies, chapter, from, to, result.length);
        result.write(chapter.text.substring(from, to));
        return LyricsCueText(result.toString(), rubies);
      }
      // The matcher concatenates chapters; a cue may span chapter boundaries.
      // Keep intervening punctuation, but never clamp an invalid end to the book.
      _collectRubies(rubies, chapter, from, chapter.text.length, result.length);
      result.write(chapter.text.substring(from));
      remaining -= available;
      start = 0;
    }
    return LyricsCueText.plain(cue.text);
  }

  /// 两条相邻 cue 之间**没有任何 cue 认领**的正文（朗读者跳读，或合缝也认领不下
  /// 的 ASR 漏转），按歌词行同一取法带回 ruby；没有这样的正文返回 null。
  ///
  /// 只在同章、区间都合法、[prev] 止于 [next] 起点之前时产生——跨章、开头结尾、
  /// 区间重叠或乱序一律不算。缝的归一化字数（有读音的字）不足
  /// [kLyricsSkippedTextMinChars] 不算（只剩标点 / 空白，或模糊命中漏掉的一个
  /// 词尾字）。文本区间与两侧歌词行首尾相接：从 [prev] 补完收尾标点之后起，到
  /// [next] 往回补的开括号之前止，再去掉两端空白。
  ///
  /// 纯显示：不改 cue、不改匹配区间，统计 / 制卡 / 高亮仍只认 cue 区间，所以
  /// 已落库的书不用重新对齐就能看到。
  LyricsCueText? skippedTextBetween(AudioCue prev, AudioCue next) {
    final SubtitleRematchFragment? a = SubtitleRematchCodec.tryDecode(
      prev.textFragmentId,
    );
    final SubtitleRematchFragment? b = SubtitleRematchCodec.tryDecode(
      next.textFragmentId,
    );
    if (a == null ||
        b == null ||
        a.sectionIndex != b.sectionIndex ||
        a.sectionIndex < 0 ||
        a.sectionIndex >= book.chapters.length ||
        a.normCharStart < 0 ||
        a.normCharEnd <= a.normCharStart ||
        b.normCharEnd <= b.normCharStart ||
        b.normCharStart - a.normCharEnd < kLyricsSkippedTextMinChars) {
      return null;
    }
    final _Chapter chapter = _chapter(a.sectionIndex);
    final String normalized = chapter.norm.text;
    final int gapStart = a.normCharEnd;
    final int gapEnd = b.normCharStart;
    if (gapEnd >= normalized.length ||
        !_isBoundary(normalized, gapStart) ||
        !_isBoundary(normalized, gapEnd)) {
      return null;
    }
    final String text = chapter.text;
    int from = _tailEnd(chapter, gapStart);
    int to = _headStart(chapter, gapEnd);
    while (from < to && _isBlank(text.codeUnitAt(from))) {
      from++;
    }
    while (to > from && _isBlank(text.codeUnitAt(to - 1))) {
      to--;
    }
    if (from >= to) return null;
    final List<EpubRubyAnnotation> rubies = <EpubRubyAnnotation>[];
    _collectRubies(rubies, chapter, from, to, 0);
    return LyricsCueText(text.substring(from, to), rubies);
  }

  static bool _isBlank(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x3000;

  /// 把章内 `[from, to)` 里的 ruby 平移到输出坐标（输出已有 [offset] 码元）。
  /// 被 cue 边界切开的 ruby 丢弃：半个基底配整个读音比没有更糟。
  static void _collectRubies(
    List<EpubRubyAnnotation> out,
    _Chapter chapter,
    int from,
    int to,
    int offset,
  ) {
    for (final EpubRubyAnnotation r in chapter.rubies) {
      if (r.end <= from) continue;
      if (r.start >= to) break;
      if (r.start < from || r.end > to) continue;
      out.add(
        EpubRubyAnnotation(
          start: r.start - from + offset,
          end: r.end - from + offset,
          reading: r.reading,
        ),
      );
    }
  }

  _Chapter _chapter(int section) {
    final _Chapter? cached = _chapters.remove(section);
    final _Chapter value = cached ?? _Chapter.parse(book, section);
    _chapters[section] = value;
    while (_chapters.length > 3) {
      _chapters.remove(_chapters.keys.first);
    }
    return value;
  }

  /// 从归一化下标 [normStart] 起的那条歌词行，在正文里的起点：往回认领它前面
  /// 那段无读音缝隙里 [_gapSplit] 切点之后的部分（开括号、行首破折号……），
  /// 再跳过行首空白。
  static int _headStart(_Chapter chapter, int normStart) {
    final int gapTo = chapter.norm.starts[normStart];
    final int gapFrom = normStart > 0 ? chapter.norm.ends[normStart - 1] : 0;
    int i = _gapSplit(chapter, gapFrom, gapTo);
    while (i < gapTo && _isBlank(chapter.text.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  /// 止于归一化下标 [normEnd]（不含）的那条歌词行，在正文里的终点：往后认领
  /// 它后面那段无读音缝隙里 [_gapSplit] 切点之前的部分（句末标点、闭括号、
  /// 省略号、破折号……）。
  static int _tailEnd(_Chapter chapter, int normEnd) {
    final int gapFrom = chapter.norm.ends[normEnd - 1];
    final int gapTo = normEnd < chapter.norm.text.length
        ? chapter.norm.starts[normEnd]
        : chapter.text.length;
    return _gapSplit(chapter, gapFrom, gapTo);
  }

  /// 两个有读音的字之间那段缝隙 `[gapFrom, gapTo)`（只含标点 / 符号 / 空白，
  /// 归一化把它们全剥了）归前后两行的切点：前一行认领切点之前、后一行认领
  /// 切点之后，所以前后两条 cue 各算各的也不会丢字或重复。
  ///
  /// 优先切在段落边界（章纯文本不含段落分隔符，边界记在 `blockEnds`）；其次切在
  /// 第一个空白处；再次切在第一个开括号前；都没有则整段归前一行（句末的
  /// 「。――」「……」、句中的「、」）。不按白名单逐个收标点：此前白名单漏了
  /// 破折号，补到「――」就停，后面的闭引号也跟着丢。
  static int _gapSplit(_Chapter chapter, int gapFrom, int gapTo) {
    for (final int e in chapter.blockEnds) {
      if (e > gapTo) break;
      if (e >= gapFrom) return e;
    }
    final String text = chapter.text;
    for (int i = gapFrom; i < gapTo; i++) {
      final int c = text.codeUnitAt(i);
      if (_isBlank(c) || _kOpening.contains(c)) return i;
    }
    return gapTo;
  }

  static final Set<int> _kOpening = '「『（(［[｛{【〔〈《〖〘〚“‘〝«‹'.codeUnits.toSet();

  static bool _isBoundary(String text, int offset) =>
      offset == text.length ||
      text.codeUnitAt(offset) < 0xdc00 ||
      text.codeUnitAt(offset) > 0xdfff;
}

class _Chapter {
  const _Chapter({
    required this.text,
    required this.norm,
    required this.rubies,
    required this.blockEnds,
  });

  factory _Chapter.parse(EpubBook book, int section) {
    final EpubPlainTextWithRuby chapter = book.chapterPlainTextWithRuby(
      section,
    );
    return _Chapter(
      text: chapter.text,
      norm: AudioTextNormalizer.normalizeWithOffsets(chapter.text),
      rubies: chapter.rubies,
      blockEnds: chapter.blockEnds,
    );
  }

  final String text;
  final NormalizedTextWithOffsets norm;
  final List<EpubRubyAnnotation> rubies;

  /// 段落边界（升序，章纯文本坐标）。
  final List<int> blockEnds;
}
