import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';

/// Resolves display text without changing transcript cues or their token timing.
/// Uses the same ruby-free chapter text and UTF-16 normalization as the matcher.
class LyricsCueTextResolver {
  LyricsCueTextResolver(this.book);

  final EpubBook book;
  final Map<int, ({String text, NormalizedTextWithOffsets norm})> _chapters =
      <int, ({String text, NormalizedTextWithOffsets norm})>{};

  String textForCue(AudioCue cue) {
    final SubtitleRematchFragment? fragment = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
    if (fragment == null ||
        fragment.sectionIndex < 0 ||
        fragment.sectionIndex >= book.chapters.length ||
        fragment.normCharStart < 0 ||
        fragment.normCharEnd <= fragment.normCharStart) {
      return cue.text;
    }

    int start = fragment.normCharStart;
    int remaining = fragment.normCharEnd - start;
    final StringBuffer result = StringBuffer();
    for (
      int section = fragment.sectionIndex;
      section < book.chapters.length;
      section++
    ) {
      final ({String text, NormalizedTextWithOffsets norm}) chapter = _chapter(
        section,
      );
      final String normalized = chapter.norm.text;
      final bool first = section == fragment.sectionIndex;
      if (first &&
          (start >= normalized.length || !_isBoundary(normalized, start))) {
        return cue.text;
      }
      final int available = normalized.length - start;
      if (remaining <= available) {
        final int end = start + remaining;
        if (!_isBoundary(normalized, end)) return cue.text;
        result.write(
          chapter.text.substring(
            first ? chapter.norm.starts[start] : 0,
            chapter.norm.ends[end - 1],
          ),
        );
        return result.toString();
      }
      // The matcher concatenates chapters; a cue may span chapter boundaries.
      // Keep intervening punctuation, but never clamp an invalid end to the book.
      result.write(
        chapter.text.substring(first ? chapter.norm.starts[start] : 0),
      );
      remaining -= available;
      start = 0;
    }
    return cue.text;
  }

  ({String text, NormalizedTextWithOffsets norm}) _chapter(int section) {
    final ({String text, NormalizedTextWithOffsets norm})? cached = _chapters
        .remove(section);
    final String text = cached?.text ?? book.chapterPlainText(section);
    final ({String text, NormalizedTextWithOffsets norm}) value =
        cached ??
        (text: text, norm: AudioTextNormalizer.normalizeWithOffsets(text));
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
