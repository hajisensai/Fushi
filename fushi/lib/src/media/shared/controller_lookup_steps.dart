import 'package:characters/characters.dart';
import 'package:fushi/src/media/video/subtitle_word_sweep.dart';

/// Pure cursor steps of the controller lookup mode (S6 of the dual-screen
/// companion) for pages whose cursor is a logical position in a line of text
/// (manga OCR blocks, music lyric lines). Word steps reuse the subtitle word
/// sweep tokenizer ([buildSubtitleSweepTokens]) so every page splits words the
/// same way; offsets are UTF-16 code units, steps never land inside a
/// grapheme.

/// UTF-16 start offset of every grapheme in [text].
List<int> controllerLookupGraphemeStarts(String text) {
  final List<int> starts = <int>[];
  int at = 0;
  for (final String g in text.characters) {
    starts.add(at);
    at += g.length;
  }
  return starts;
}

/// The cursor [at] (UTF-16) moved one grapheme in [dir] (+1 / -1), clamped to
/// the first / last grapheme. Returns [at] unchanged on empty text.
int controllerLookupCharStep(String text, int at, int dir) {
  final List<int> starts = controllerLookupGraphemeStarts(text);
  if (starts.isEmpty) return at;
  int index = starts.lastIndexWhere((int s) => s <= at);
  if (index < 0) index = 0;
  return starts[(index + dir).clamp(0, starts.length - 1)];
}

/// The cursor [at] (UTF-16) moved to the start of the next (+1) / previous
/// (-1) word. Back from inside a word goes to that word's start first. Null at
/// the first / last word (the caller keeps the cursor; line steps change
/// lines). [tokenize] is for tests only.
int? controllerLookupWordStep(
  String text,
  int at,
  int dir, {
  SubtitleSweepTokenizer? tokenize,
}) {
  if (text.isEmpty) return null;
  final List<int> graphemes = controllerLookupGraphemeStarts(text);
  final List<int> starts = <int>[
    for (final SubtitleSweepToken t in buildSubtitleSweepTokens(
      text,
      tokenize: tokenize,
    ))
      if (t.graphemeStart < graphemes.length) graphemes[t.graphemeStart],
  ];
  if (dir > 0) {
    for (final int s in starts) {
      if (s > at) return s;
    }
    return null;
  }
  for (final int s in starts.reversed) {
    if (s < at) return s;
  }
  return null;
}

/// One character of a subtitle caret registry, as the word step needs it:
/// the sentence it belongs to, its grapheme index there, and its cue (two
/// cues can carry the same sentence text).
typedef ControllerLookupSubtitleChar = ({
  String sentence,
  int graphemeIndex,
  Object cue,
});

/// Video subtitle caret word step: the registry entry of the first character
/// of the next (+1) / previous (-1) word in the sentence of entry [current].
/// Null when the step cannot be made by word (no hit, the sentence has no
/// words, the target is not in the registry): the caller falls back to a
/// character step. -1 when the cursor is already at the first / last word
/// (stays put; line steps change cues). [tokenize] is for tests only.
int? controllerLookupSubtitleWordEntry({
  required int current,
  required int dir,
  required int entryCount,
  required ControllerLookupSubtitleChar? Function(int entry) charAt,
  SubtitleSweepTokenizer? tokenize,
}) {
  final ControllerLookupSubtitleChar? hit = charAt(current);
  if (hit == null || hit.sentence.isEmpty) return null;
  final List<int> graphemes = controllerLookupGraphemeStarts(hit.sentence);
  if (hit.graphemeIndex < 0 || hit.graphemeIndex >= graphemes.length) {
    return null;
  }
  final int? target = controllerLookupWordStep(
    hit.sentence,
    graphemes[hit.graphemeIndex],
    dir,
    tokenize: tokenize,
  );
  if (target == null) return -1;
  final int targetGrapheme = graphemes.indexOf(target);
  for (int i = 0; i < entryCount; i++) {
    final ControllerLookupSubtitleChar? c = charAt(i);
    if (c != null &&
        identical(c.cue, hit.cue) &&
        c.sentence == hit.sentence &&
        c.graphemeIndex == targetGrapheme) {
      return i;
    }
  }
  return null;
}
