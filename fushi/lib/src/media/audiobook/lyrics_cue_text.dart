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
      final int from = first ? chapter.norm.starts[start] : 0;
      if (remaining <= available) {
        final int end = start + remaining;
        if (!_isBoundary(normalized, end)) return LyricsCueText.plain(cue.text);
        final int to = chapter.norm.ends[end - 1];
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
  });

  factory _Chapter.parse(EpubBook book, int section) {
    final EpubPlainTextWithRuby chapter = book.chapterPlainTextWithRuby(
      section,
    );
    return _Chapter(
      text: chapter.text,
      norm: AudioTextNormalizer.normalizeWithOffsets(chapter.text),
      rubies: chapter.rubies,
    );
  }

  final String text;
  final NormalizedTextWithOffsets norm;
  final List<EpubRubyAnnotation> rubies;
}
