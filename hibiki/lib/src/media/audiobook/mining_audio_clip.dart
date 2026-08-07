import 'package:meta/meta.dart';

import 'package:fushi_audio/fushi_audio.dart';

/// Default head padding (ms) prepended to a mining audio clip.
///
/// Human speech onset (attack of the first mora) is short, so a small lead-in is
/// enough to keep the very first sound from being clipped. Kept intentionally
/// smaller than [kMiningTailPadMs] because a long head easily bleeds the previous
/// sentence's tail into the clip. Phase 0: a constant (not yet a setting) so the
/// intent and the value stay in one place.
const int kMiningHeadPadMs = 120;

/// Default tail padding (ms) appended to a mining audio clip.
///
/// Sentence endings decay slowly (trailing vowels, particles, breath), so the
/// tail needs more room than the head to avoid a hard cut that swallows the final
/// mora. Larger than [kMiningHeadPadMs] for that reason. Clamped against the next
/// same-file cue so it never bleeds the following sentence's onset in.
const int kMiningTailPadMs = 200;

/// Resolves the audio range used when exporting sentence audio for Anki.
///
/// The lookup cue can be only one fragment inside the selected sentence. Prefer
/// the reader's full normalized sentence range; when that is unavailable, match
/// Hoshi Android's behavior by expanding to adjacent cues whose text belongs to
/// the selected sentence. [delayMs] is the user's global A/V sync offset and is
/// applied to both edges, not as a sentence-tail padding.
///
/// [cue] is the cue the looked-up word fell inside. It can be null: audiobook
/// cue alignment leaves gaps (titles, captions, alignment misses, chapter
/// edges), so a word can sit in covered-but-uncued text while the sentence it
/// belongs to is still spanned by surrounding cues. In that case we resolve the
/// range purely from the sentence's normalized [sectionIndex] + offset/length
/// span instead of giving up — that is the only way to recover sentence audio
/// for those gap words (TODO-104a / BUG-172). Returns null only when no range
/// can be derived at all (no cue and no usable sentence span).
AudioPlaybackRange? miningSentenceAudioRange({
  required List<AudioCue> cues,
  required AudioCue? cue,
  required String sentence,
  int? sectionIndex,
  int? sentenceNormCharOffset,
  int? sentenceNormCharLength,
  int delayMs = 0,
}) {
  final AudioPlaybackRange? positionRange = _rangeFromSentencePosition(
    cues: cues,
    cue: cue,
    sentence: sentence,
    sectionIndex: sectionIndex,
    sentenceNormCharOffset: sentenceNormCharOffset,
    sentenceNormCharLength: sentenceNormCharLength,
  );

  // When the word did not land in any cue (gap), the sentence span is the only
  // anchor we have; do not fall through to cue-relative expansion.
  final AudioPlaybackRange? baseRange = positionRange ??
      (cue == null
          ? null
          : (_expandAroundCue(cues: cues, cue: cue, sentence: sentence) ??
              _cueRange(cue)));

  if (baseRange == null) {
    return null;
  }
  // TODO-1009 / BUG-475: same-chapter selections on coarse-aligned audio
  // (TextToEpub + post-attached audio, or alignment miss) can resolve to a
  // zero-duration cue (`endMs == startMs`) or a merge of such cues. Every
  // cue-relative path above copies the cue's raw start/end, so the merged range
  // stays degenerate -- only [_cueRange] floored it. A degenerate range then
  // trips `classifyAudiobookClipSelection` (`endMs <= startMs`) and the user
  // sees the misleading cross-chapter/cross-file toast for a perfectly
  // in-chapter selection. Repair the range here (single chokepoint) to a
  // positive duration before shifting: extend to the next same-file cue's start
  // (the implied playback length) and floor to +1ms. This keeps the same
  // audioFileIndex -- never fabricates a cross-file/cross-chapter range -- so
  // genuinely cross-file selections still fall through to the caller's
  // single-file/null routing untouched.
  final AudioPlaybackRange positiveRange =
      _ensurePositiveDuration(baseRange, cues);
  // Phase 0 (TODO-1115): widen the exported clip by a small head/tail padding so
  // the reader's first-mora onset and last-mora decay are not hard-cut, WITHOUT
  // bleeding an adjacent sentence in. Padding is clamped against the neighbouring
  // same-file cue boundaries in the unshifted timebase; the A/V [delayMs] is then
  // applied to the already-padded window (same as before). Only this mining
  // chokepoint pads — normal playback follow uses a different path and is
  // untouched.
  final AudioPlaybackRange paddedRange = padSentenceRange(
    positiveRange,
    cues: cues,
    headPadMs: kMiningHeadPadMs,
    tailPadMs: kMiningTailPadMs,
  );
  return _shiftRange(paddedRange, delayMs);
}

/// Widens [range] by up to [headPadMs] before its start and [tailPadMs] after its
/// end, clamped against the nearest neighbouring cue in the SAME audio file so the
/// padding never runs into an adjacent sentence.
///
/// Pure and side-effect free (unit-testable). Never changes [range.audioFileIndex]
/// and always returns a range with `endMs > startMs`.
///
/// Head: `startMs` moves back by [headPadMs] but is floored at
/// `max(0, endMs of the closest same-file cue that ends at/before the start)`.
/// When there is no such cue (first sentence in the file) the floor is 0, so the
/// clip can reach into the leading silence but never below the file origin.
///
/// Tail: `endMs` moves forward by [tailPadMs] but is capped at the `startMs` of
/// the closest same-file cue that starts at/after the end. When there is no such
/// cue (last sentence in the file) the tail is uncapped here — ffmpeg's `-t`
/// naturally stops at end-of-file, so over-running the real duration is harmless.
///
/// [headPadMs]/[tailPadMs] may be 0 (no padding on that edge); negative values are
/// treated as 0.
AudioPlaybackRange padSentenceRange(
  AudioPlaybackRange range, {
  required List<AudioCue> cues,
  required int headPadMs,
  required int tailPadMs,
}) {
  final int head = headPadMs > 0 ? headPadMs : 0;
  final int tail = tailPadMs > 0 ? tailPadMs : 0;
  if (head == 0 && tail == 0) {
    return range;
  }

  // Head floor: the latest same-file cue boundary that does NOT belong to this
  // sentence (ends at or before our start). Guarantees we never swallow the
  // previous sentence's tail. 0 when there is no earlier cue (leading silence).
  int headFloor = 0;
  // Tail cap: the earliest same-file cue boundary strictly after our end (the
  // next sentence's onset). No cap when nothing follows in this file.
  int? tailCap;
  for (final AudioCue cue in cues) {
    if (cue.audioFileIndex != range.audioFileIndex) {
      continue;
    }
    if (cue.endMs <= range.startMs && cue.endMs > headFloor) {
      headFloor = cue.endMs;
    }
    if (cue.startMs >= range.endMs) {
      if (tailCap == null || cue.startMs < tailCap) {
        tailCap = cue.startMs;
      }
    }
  }

  int paddedStart = range.startMs - head;
  if (paddedStart < headFloor) {
    paddedStart = headFloor;
  }
  if (paddedStart < 0) {
    paddedStart = 0;
  }

  int paddedEnd = range.endMs + tail;
  if (tailCap != null && paddedEnd > tailCap) {
    paddedEnd = tailCap;
  }

  // Never let padding collapse the window (e.g. degenerate neighbours touching
  // the range on both sides). Keep at least the original span.
  if (paddedStart > range.startMs) {
    paddedStart = range.startMs;
  }
  if (paddedEnd < range.endMs) {
    paddedEnd = range.endMs;
  }

  return AudioPlaybackRange(
    audioFileIndex: range.audioFileIndex,
    startMs: paddedStart,
    endMs: paddedEnd,
  );
}

/// Guarantees [range].endMs > [range].startMs. A zero/negative-duration range
/// comes from cues whose own `startMs == endMs` (coarse alignment). Extend the
/// end to the start of the next cue in the SAME file (the implied duration); if
/// none, floor to startMs + 1 so ffmpeg gets a non-empty window. Never changes
/// audioFileIndex.
AudioPlaybackRange _ensurePositiveDuration(
  AudioPlaybackRange range,
  List<AudioCue> cues,
) {
  if (range.endMs > range.startMs) {
    return range;
  }
  int repairedEnd = range.startMs + 1;
  for (final AudioCue cue in cues) {
    if (cue.audioFileIndex != range.audioFileIndex) continue;
    // The next cue boundary strictly after our start bounds the clip duration.
    if (cue.startMs > range.startMs && cue.startMs > repairedEnd) {
      repairedEnd = cue.startMs;
      break;
    }
  }
  return AudioPlaybackRange(
    audioFileIndex: range.audioFileIndex,
    startMs: range.startMs,
    endMs: repairedEnd,
  );
}

AudioPlaybackRange? _rangeFromSentencePosition({
  required List<AudioCue> cues,
  required AudioCue? cue,
  required String sentence,
  required int? sectionIndex,
  required int? sentenceNormCharOffset,
  required int? sentenceNormCharLength,
}) {
  // TODO-811: local (non-sasayaki) audiobooks have cues whose textFragmentId is a
  // plain selector ([data-cue-id="N"]) or empty, never a sasayaki-encoded
  // fragment, so CollectionAudioMatcher's position matching cannot place them. The
  // sentence text is the only span anchor left, so always forward it as the text
  // fallback; findPlaybackRange returns the sasayaki position range when present
  // and otherwise recovers the range from the cue texts (which carry the real
  // start/end ms). Without this, a gap word (cue == null) on a local audiobook
  // resolved no range at all -> the card silently lost its sentence audio.
  final String textFallback = sentence.trim();
  if (sectionIndex == null ||
      sentenceNormCharOffset == null ||
      sentenceNormCharLength == null ||
      sentenceNormCharLength <= 0) {
    // No usable normalized span. The sentence text is then the only span anchor.
    //
    // TODO-970: try the plain-text match whenever there IS sentence text, even
    // when a lookup cue exists. The old guard returned null on `cue != null` and
    // deferred entirely to the caller's _expandAroundCue. But _expandAroundCue is
    // cue-anchored: it only keeps a text match that COVERS the lookup cue and only
    // expands to neighbours whose text is a substring of the sentence. When the
    // looked-up token landed on a plain-selector boundary cue OUTSIDE the
    // sentence (punctuation / adjacent-sentence fragment, common on local
    // audiobooks with no sasayaki positions), the anchored match is rejected and
    // expansion collapses to that single boundary cue — the wrong/missing audio
    // (BUG-458 残留). The non-anchored text search recovers the full sentence
    // range from the cue texts instead. On a hit, use it; on a miss return null
    // so the caller's cue-anchored _expandAroundCue still gets its chance.
    if (textFallback.isEmpty) {
      return null;
    }
    final AudioPlaybackRange? textRange =
        CollectionAudioMatcher.findPlaybackRange(
      cues: cues,
      text: textFallback,
    );
    if (textRange != null) {
      return textRange;
    }
    // Text matched nothing. With no cue there is no further anchor; with a cue
    // defer to the caller's _expandAroundCue (returning null here lets the main
    // function fall through to the cue-relative path).
    return null;
  }
  // When a lookup cue exists, keep the original guard: trust the sentence span
  // only if the cue actually decodes to this section (the word truly belongs to
  // the cued text). When there is no cue (gap word), the cue cannot vouch for
  // the section, so we trust [sectionIndex] directly — it comes from the
  // reader's current chapter / lyrics fragment, which is authoritative for the
  // selection regardless of cue coverage.
  if (cue != null) {
    final SubtitleRematchFragment? cueFragment =
        SubtitleRematchCodec.tryDecode(cue.textFragmentId);
    if (cueFragment == null) {
      // The cue carries no sasayaki position (plain SRT selector / empty): it
      // cannot vouch for the section, and the section's cues may not be sasayaki
      // either, so trusting the text fallback here could anchor on a repeated
      // sentence elsewhere. Defer to the caller's cue-anchored _expandAroundCue.
      return null;
    }
    if (cueFragment.sectionIndex != sectionIndex) {
      // TODO-956 (C-audio): cue/reader divergence — the lookup cue decoded to a
      // DIFFERENT section than the reader's authoritative sentence span. The old
      // code returned null and fell through to _expandAroundCue's CONTIGUOUS
      // substring match, which is exactly what produced no sentence audio when
      // the cue and reader texts diverge. Instead, prefer anchoring on the
      // sentence span by POSITION in the reader's section. We pass text:null so
      // this attempt never falls back to text matching (which could grab a
      // repeated sentence); when the section's cues carry no sasayaki position
      // the call returns null and we still defer to the caller's cue expansion.
      return CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: sectionIndex,
        normCharOffset: sentenceNormCharOffset,
        normCharLength: sentenceNormCharLength,
      );
    }
  }
  return CollectionAudioMatcher.findPlaybackRange(
    cues: cues,
    sectionIndex: sectionIndex,
    normCharOffset: sentenceNormCharOffset,
    normCharLength: sentenceNormCharLength,
    text: textFallback.isEmpty ? null : textFallback,
  );
}

AudioPlaybackRange? _expandAroundCue({
  required List<AudioCue> cues,
  required AudioCue cue,
  required String sentence,
}) {
  final int cueIndex = _indexOfCue(cues, cue);
  if (cueIndex < 0) return null;

  final String normalizedSentence = AudioTextNormalizer.normalize(sentence);
  if (normalizedSentence.isEmpty) return null;

  final AudioPlaybackRange? anchoredMatch = _anchoredAdjacentMatch(
    cues: cues,
    cueIndex: cueIndex,
    normalizedSentence: normalizedSentence,
  );
  if (anchoredMatch != null) return anchoredMatch;

  int startIndex = cueIndex;
  int endIndex = cueIndex;
  while (startIndex > 0 &&
      _canExpandTo(cue, cues[startIndex - 1], normalizedSentence)) {
    startIndex -= 1;
  }
  while (endIndex < cues.length - 1 &&
      _canExpandTo(cue, cues[endIndex + 1], normalizedSentence)) {
    endIndex += 1;
  }

  final int fileIndex = cue.audioFileIndex;
  int startMs = cues[startIndex].startMs;
  int endMs = cues[endIndex].endMs;
  for (int i = startIndex; i <= endIndex; i++) {
    final AudioCue hit = cues[i];
    if (hit.audioFileIndex != fileIndex) break;
    if (hit.startMs < startMs) startMs = hit.startMs;
    if (hit.endMs > endMs) endMs = hit.endMs;
  }

  return AudioPlaybackRange(
    audioFileIndex: fileIndex,
    startMs: startMs,
    endMs: endMs,
  );
}

/// 归一化拼接索引：各 cue 归一化文本、其在拼接串中的起点，与拼接串本身。
/// [_anchoredAdjacentMatch] 与 [_collectSpanCuesByText] 原各持一份逐字相同的
/// 构建循环，收敛为文件内单一构建点。hibiki_audio 侧
/// `CollectionAudioMatcher._normalizedAdjacentMatch` 的第三份刻意保持包内独立
/// （不跨包新增共享面；归一化本体 AudioTextNormalizer / BUG-060 白名单不动）。
({List<int> cueStarts, List<String> normTexts, String concat})
    _normalizedCueConcat(List<AudioCue> cues) {
  final List<int> cueStarts = <int>[];
  final List<String> normTexts = <String>[];
  final StringBuffer buf = StringBuffer();
  for (final AudioCue cue in cues) {
    cueStarts.add(buf.length);
    final String normalizedText = AudioTextNormalizer.normalize(cue.text);
    normTexts.add(normalizedText);
    buf.write(normalizedText);
  }
  return (cueStarts: cueStarts, normTexts: normTexts, concat: buf.toString());
}

AudioPlaybackRange? _anchoredAdjacentMatch({
  required List<AudioCue> cues,
  required int cueIndex,
  required String normalizedSentence,
}) {
  final ({List<int> cueStarts, List<String> normTexts, String concat}) index =
      _normalizedCueConcat(cues);
  final String concat = index.concat;
  final int anchorStart = index.cueStarts[cueIndex];
  final int anchorEnd = anchorStart + index.normTexts[cueIndex].length;

  int found = concat.indexOf(normalizedSentence);
  while (found >= 0) {
    final int foundEnd = found + normalizedSentence.length;
    if (_rangeContainsCue(
      rangeStart: found,
      rangeEnd: foundEnd,
      cueStart: anchorStart,
      cueEnd: anchorEnd,
    )) {
      return _cueRangeForNormalizedSpan(
        cues: cues,
        normalizedTexts: index.normTexts,
        cueStarts: index.cueStarts,
        spanStart: found,
        spanEnd: foundEnd,
      );
    }
    found = concat.indexOf(normalizedSentence, found + 1);
  }

  return null;
}

bool _rangeContainsCue({
  required int rangeStart,
  required int rangeEnd,
  required int cueStart,
  required int cueEnd,
}) {
  if (cueStart == cueEnd) {
    return rangeStart <= cueStart && cueStart <= rangeEnd;
  }
  return rangeStart < cueEnd && rangeEnd > cueStart;
}

AudioPlaybackRange? _cueRangeForNormalizedSpan({
  required List<AudioCue> cues,
  required List<String> normalizedTexts,
  required List<int> cueStarts,
  required int spanStart,
  required int spanEnd,
}) {
  int startIndex = cues.length;
  int endIndex = -1;
  for (int i = 0; i < cues.length; i++) {
    final int cueStart = cueStarts[i];
    final int cueEnd = cueStart + normalizedTexts[i].length;
    if (_rangeContainsCue(
      rangeStart: spanStart,
      rangeEnd: spanEnd,
      cueStart: cueStart,
      cueEnd: cueEnd,
    )) {
      if (i < startIndex) startIndex = i;
      if (i > endIndex) endIndex = i;
    }
  }

  if (startIndex > endIndex) return null;

  final int fileIndex = cues[startIndex].audioFileIndex;
  int startMs = cues[startIndex].startMs;
  int endMs = cues[startIndex].endMs;
  for (int i = startIndex + 1; i <= endIndex; i++) {
    final AudioCue cue = cues[i];
    if (cue.audioFileIndex != fileIndex) break;
    if (cue.startMs < startMs) startMs = cue.startMs;
    if (cue.endMs > endMs) endMs = cue.endMs;
  }

  return AudioPlaybackRange(
    audioFileIndex: fileIndex,
    startMs: startMs,
    endMs: endMs,
  );
}

bool _canExpandTo(
  AudioCue anchor,
  AudioCue candidate,
  String normalizedSentence,
) {
  if (candidate.audioFileIndex != anchor.audioFileIndex) return false;

  final SubtitleRematchFragment? anchorFragment =
      SubtitleRematchCodec.tryDecode(anchor.textFragmentId);
  final SubtitleRematchFragment? candidateFragment =
      SubtitleRematchCodec.tryDecode(candidate.textFragmentId);
  if (anchorFragment != null &&
      candidateFragment != null &&
      candidateFragment.sectionIndex != anchorFragment.sectionIndex) {
    return false;
  }

  final String normalizedCue = AudioTextNormalizer.normalize(candidate.text);
  return normalizedCue.isNotEmpty && normalizedSentence.contains(normalizedCue);
}

int _indexOfCue(List<AudioCue> cues, AudioCue cue) {
  final int? id = cue.id;
  if (id != null) {
    final int byId = cues.indexWhere((AudioCue c) => c.id == id);
    if (byId >= 0) return byId;
  }
  return cues.indexWhere((AudioCue c) => identical(c, cue));
}

AudioPlaybackRange _cueRange(AudioCue cue) {
  final int endMs = cue.endMs > cue.startMs ? cue.endMs : cue.startMs + 1;
  return AudioPlaybackRange(
    audioFileIndex: cue.audioFileIndex,
    startMs: cue.startMs,
    endMs: endMs,
  );
}

AudioPlaybackRange _shiftRange(AudioPlaybackRange range, int delayMs) {
  if (delayMs == 0) return range;
  final int startMs = (range.startMs + delayMs).clamp(0, 1 << 30);
  final int endMs = (range.endMs + delayMs).clamp(startMs + 1, 1 << 30);
  return AudioPlaybackRange(
    audioFileIndex: range.audioFileIndex,
    startMs: startMs,
    endMs: endMs,
  );
}

// ─────────────────────────────────────────────────────────────────────────
// TODO-1115 动态高亮片段视频：多句连读 + 逐帧高亮跟随。
//
// [miningSentenceAudioRange] 只回一段合并后的 [AudioPlaybackRange]（单文件、
// 起止 ms），够用来「裁一段音频」，但**丢失了每句 cue 的边界**——逐句高亮跟随需要
// 知道选区覆盖了哪几个 cue、每个 cue 的 [startMs]/[endMs]，才能在每一帧定位「此刻
// 该高亮哪一句」。所以这里新增一条纯数据路径：把选区映射到**有序 cue 列表**，再由
// [clipFramePlan] 排出每帧高亮哪一句。二者都是纯函数、无副作用、可单测。
//
// 不改 [miningSentenceAudioRange]：单句静态导出仍走旧路径（never break userspace），
// 多句动态失败时回退单句静态。
// ─────────────────────────────────────────────────────────────────────────

/// 把有声书查词/拖选选区映射到覆盖它的**有序 cue 列表**（同一 [AudioCue.audioFileIndex]，
/// 按 [AudioCue.startMs] 升序）。
///
/// 与 [miningSentenceAudioRange] 复用同一套定位逻辑（sasayaki 位置匹配优先，文本兜底），
/// 但**收集所有命中的 cue**而不合并成单一区间——逐句高亮跟随需要每句边界。
///
/// 语义与约束：
/// - **单文件约束**：只保留第一个命中 cue 所在文件（`audioFileIndex`）的 cue；跨文件的
///   命中被丢弃（跨文件选区在导出侧本就降级，见 [classifyAudiobookClipSelection]）。
/// - 选区只覆盖 1 句时自然退化为**单元素列表**，等价旧单句路径。
/// - 无法定位（跨章解析落空 / 无 cue 无 span）返回**空列表**，调用方据此回退单句静态。
///
/// [cue] 是查词落入的 cue（可空——gap word）；[sentence] 是选区文本；
/// [sectionIndex]/[sentenceNormCharOffset]/[sentenceNormCharLength] 是选区的整书归一化
/// span（拖选跨句时已由选区 JS 合并成整段 span，见 mining_clip_span_test）。
List<AudioCue> miningSentenceCueSpan({
  required List<AudioCue> cues,
  required AudioCue? cue,
  required String sentence,
  int? sectionIndex,
  int? sentenceNormCharOffset,
  int? sentenceNormCharLength,
}) {
  if (cues.isEmpty) {
    return const <AudioCue>[];
  }

  final List<AudioCue> hits = _collectSpanCues(
    cues: cues,
    cue: cue,
    sentence: sentence,
    sectionIndex: sectionIndex,
    sentenceNormCharOffset: sentenceNormCharOffset,
    sentenceNormCharLength: sentenceNormCharLength,
  );
  if (hits.isEmpty) {
    return const <AudioCue>[];
  }

  // 单文件约束：以第一句所在文件为准，丢弃跨文件命中，再按 startMs 升序。
  final int fileIndex = hits.first.audioFileIndex;
  final List<AudioCue> sameFile = hits
      .where((AudioCue c) => c.audioFileIndex == fileIndex)
      .toList()
    ..sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  return List<AudioCue>.unmodifiable(sameFile);
}

/// 收集覆盖选区的 cue（未过滤文件、未排序）。位置匹配优先，文本兜底，最后单 cue 兜底。
List<AudioCue> _collectSpanCues({
  required List<AudioCue> cues,
  required AudioCue? cue,
  required String sentence,
  required int? sectionIndex,
  required int? sentenceNormCharOffset,
  required int? sentenceNormCharLength,
}) {
  // 1) 位置匹配（sasayaki span 与选区 [offset, offset+length) 有交集的 cue）。
  if (sectionIndex != null &&
      sentenceNormCharOffset != null &&
      sentenceNormCharLength != null &&
      sentenceNormCharLength > 0) {
    final int offset = sentenceNormCharOffset;
    final int rangeEnd = offset + sentenceNormCharLength;
    final List<AudioCue> hits = <AudioCue>[];
    for (final AudioCue c in cues) {
      final SubtitleRematchFragment? frag =
          SubtitleRematchCodec.tryDecode(c.textFragmentId);
      if (frag == null || frag.sectionIndex != sectionIndex) {
        continue;
      }
      if (offset < frag.normCharEnd && rangeEnd > frag.normCharStart) {
        hits.add(c);
      }
    }
    if (hits.isNotEmpty) {
      return hits;
    }
  }

  // 2) 文本兜底：归一化拼接子串匹配，取覆盖 span 的连续 cue。
  final String textFallback = sentence.trim();
  if (textFallback.isNotEmpty) {
    final List<AudioCue> textHits = _collectSpanCuesByText(cues, textFallback);
    if (textHits.isNotEmpty) {
      return textHits;
    }
  }

  // 3) 单 cue 兜底：连位置/文本都定位不出时，至少保留查词落入的那个 cue（若有），
  //    让多句路径自然退化为单句静态（等价旧路径），而不是彻底放弃。
  if (cue != null) {
    return <AudioCue>[cue];
  }
  return const <AudioCue>[];
}

/// 归一化所有 cue.text 拼接后定位 [query]，返回与其重叠的连续 cue（复刻
/// [CollectionAudioMatcher] 的文本匹配语义，但回 cue 列表而非合并区间）。
List<AudioCue> _collectSpanCuesByText(List<AudioCue> cues, String query) {
  final String normQuery = AudioTextNormalizer.normalize(query);
  if (normQuery.isEmpty) {
    return const <AudioCue>[];
  }
  final ({List<int> cueStarts, List<String> normTexts, String concat}) index =
      _normalizedCueConcat(cues);
  final int found = index.concat.indexOf(normQuery);
  if (found < 0) {
    return const <AudioCue>[];
  }
  final int foundEnd = found + normQuery.length;
  final List<AudioCue> hits = <AudioCue>[];
  for (int i = 0; i < cues.length; i++) {
    final int cueStart = index.cueStarts[i];
    final int cueEnd = cueStart + index.normTexts[i].length;
    if (cueStart < foundEnd && cueEnd > found) {
      hits.add(cues[i]);
    }
  }
  return hits;
}

/// 有声书片段导出专用的整段尾 padding（ms）。比 Anki 制卡共用的 [kMiningTailPadMs]
/// 放宽，避免导出视频末句尾音被硬切；**只用于导出路径**（[clipExportGlobalRange]），
/// 不改全局常量，不影响 [miningSentenceAudioRange] 的 Anki 制卡窗口。
const int kClipExportTailPadMs = 600;

/// 从**有序**多句 cue 列表算出导出用的整段完整音频窗口（首句 head-padded start ..
/// 末句 tail-padded end），并应用 A/V [delayMs] 偏移。纯函数、可单测。
///
/// 中间句本就连续（相邻 cue 首尾相接），不会被 padSentenceRange 的 tailCap 切——tailCap
/// 只对**末句**的尾 padding 生效（末句之后无同文件 cue 时 tailCap 为空，尾 padding 放宽到
/// [kClipExportTailPadMs] 也不会侵入下一句）。跨文件 cue 已在 [miningSentenceCueSpan]
/// 侧被过滤，这里的 [span] 保证单文件。返回 null 当 [span] 为空。
AudioPlaybackRange? clipExportGlobalRange({
  required List<AudioCue> span,
  required List<AudioCue> allCues,
  int headPadMs = kMiningHeadPadMs,
  int tailPadMs = kClipExportTailPadMs,
  int delayMs = 0,
}) {
  if (span.isEmpty) {
    return null;
  }
  final int fileIndex = span.first.audioFileIndex;
  int startMs = span.first.startMs;
  int endMs = span.first.endMs;
  for (final AudioCue c in span) {
    if (c.audioFileIndex != fileIndex) continue;
    if (c.startMs < startMs) startMs = c.startMs;
    if (c.endMs > endMs) endMs = c.endMs;
  }
  final AudioPlaybackRange merged = AudioPlaybackRange(
    audioFileIndex: fileIndex,
    startMs: startMs,
    endMs: endMs > startMs ? endMs : startMs + 1,
  );
  final AudioPlaybackRange padded = padSentenceRange(
    merged,
    cues: allCues,
    headPadMs: headPadMs,
    tailPadMs: tailPadMs,
  );
  return _shiftRange(padded, delayMs);
}

/// 逐帧渲染计划里的一段：从第 [highlightCueIndex] 句起、连续 [frameCount] 帧都高亮它。
///
/// [highlightCueIndex] 是**多句 cue 列表里的下标**（0-based）；-1 表示这一段落在句间
/// gap（无 cue 覆盖当前帧时刻，见 [clipFramePlan] 的 gap 策略）。相邻相同 index 的帧被
/// 合并成一段（[frameCount] 累加），供渲染层「每句只渲一次 PNG、按 frameCount 决定序列帧
/// 里复制几帧」。
@immutable
class ClipFrameSpec {
  const ClipFrameSpec({
    required this.highlightCueIndex,
    required this.frameCount,
  });

  /// 该段高亮的 cue 下标（多句列表 0-based）；-1 = 句间 gap，无高亮。
  final int highlightCueIndex;

  /// 该段持续的帧数（合并相邻同 index 帧后的计数）。
  final int frameCount;

  @override
  bool operator ==(Object other) =>
      other is ClipFrameSpec &&
      other.highlightCueIndex == highlightCueIndex &&
      other.frameCount == frameCount;

  @override
  int get hashCode => Object.hash(highlightCueIndex, frameCount);

  @override
  String toString() =>
      'ClipFrameSpec(cue=$highlightCueIndex, frames=$frameCount)';
}

/// 句间 gap（某帧时刻无 cue 覆盖）时的高亮策略。
enum ClipGapHighlight {
  /// 保持上一句高亮（默认——朗读者在句间停顿时上一句字幕通常仍留在屏上）。
  holdPrevious,

  /// 无高亮（gap 帧不高亮任何句）。
  none,
}

/// 纯函数：给定**有序** cue 列表 [cues]（[miningSentenceCueSpan] 产出，已单文件+升序）、
/// 全局裁剪窗口 `[globalStartMs, globalEndMs)` 与帧率 [fps]，排出每帧「高亮哪一句」。
///
/// 帧数 = ceil((globalEndMs - globalStartMs) / (1000/fps))，至少 1 帧。第 i 帧的显示
/// 区间是 `[globalStartMs + i*Δ, globalStartMs + (i+1)*Δ)`（Δ=1000/fps），在其**帧中心**
/// （`globalStartMs + (i+0.5)*Δ`）采样：在 [cues] 里找**包含该时刻**的 cue（`startMs <= t < endMs`）
/// → 该帧高亮它。导出视频音视频锁定，第 i 帧播放的音频是 `[globalStartMs+i*Δ,
/// globalStartMs+(i+1)*Δ)`，某句声音在视频时刻 `S-globalStartMs` 被听到，帧中心采样让
/// 高亮切换帧落在离句起点**最近**的帧边界（`round((S-globalStartMs)/Δ)`）——对称误差 ≤Δ/2，
/// 既不迟钝（帧起点采样 = ceil = 最多晚 Δ）也不提前太多（帧尾采样 = floor = 最多早 Δ，
/// TODO-1147 矫枉过正的根因，TODO-1256 用户回访「对不上」）。落在任何 cue 之外（句间 gap
/// / 头尾 padding）时按 [gapHighlight] 决定：默认 [ClipGapHighlight.holdPrevious] 保持上一句。
///
/// 相邻相同 highlightCueIndex 的帧合并计数（每句只渲一次 PNG）。返回 [ClipFrameSpec] 列表，
/// 其 [ClipFrameSpec.frameCount] 之和 == 总帧数。
///
/// [cues] 为空返回空列表（调用方回退单句静态）。
List<ClipFrameSpec> clipFramePlan({
  required List<AudioCue> cues,
  required int globalStartMs,
  required int globalEndMs,
  required int fps,
  ClipGapHighlight gapHighlight = ClipGapHighlight.holdPrevious,
}) {
  if (cues.isEmpty || fps <= 0 || globalEndMs <= globalStartMs) {
    return const <ClipFrameSpec>[];
  }

  final double msPerFrame = 1000.0 / fps;
  final int durationMs = globalEndMs - globalStartMs;
  // ceil：末段不足一帧也补一帧，保证覆盖整段音频时长。
  int frameCount = (durationMs / msPerFrame).ceil();
  if (frameCount < 1) {
    frameCount = 1;
  }

  final List<ClipFrameSpec> plan = <ClipFrameSpec>[];
  // run-length：逐帧算高亮 index，相邻相同则累加计数，变化则 flush 当前 run。
  int? currentIndex;
  int runFrames = 0;
  int lastHighlight = _kNoHighlight;

  for (int i = 0; i < frameCount; i++) {
    // TODO-1256（用户回访「对不上」根因·帧-cue 对齐）：帧起点采样（t=i*Δ）= ceil =
    // 高亮切换最多晚 Δ ms（迟钝，1147 前的老问题）；TODO-1147 曾改成帧尾采样
    // （t=(i+1)*Δ-1）= floor = 高亮覆盖整帧含声音前那段 = 最多**早** Δ ms（矫枉过正，
    // 用户觉得提前太多、对不上）。改在**帧中心**（t=(i+0.5)*Δ）采样 = round = 切换帧落在
    // 离句起点最近的帧边界，对称误差 ≤Δ/2，既不迟钝也不提前太多，真正「对上」句起点。
    final int t = globalStartMs + ((i + 0.5) * msPerFrame).round();
    int frameIndex = _cueIndexAt(cues, t);
    if (frameIndex == _kNoHighlight) {
      // 句间 gap / 头尾 padding：按策略处理。
      if (gapHighlight == ClipGapHighlight.holdPrevious &&
          lastHighlight != _kNoHighlight) {
        frameIndex = lastHighlight;
      }
    } else {
      lastHighlight = frameIndex;
    }

    if (currentIndex == null) {
      currentIndex = frameIndex;
      runFrames = 1;
    } else if (frameIndex == currentIndex) {
      runFrames += 1;
    } else {
      plan.add(
        ClipFrameSpec(highlightCueIndex: currentIndex, frameCount: runFrames),
      );
      currentIndex = frameIndex;
      runFrames = 1;
    }
  }
  plan.add(
    ClipFrameSpec(highlightCueIndex: currentIndex!, frameCount: runFrames),
  );
  return List<ClipFrameSpec>.unmodifiable(plan);
}

/// [ClipFrameSpec.highlightCueIndex] 的「无高亮 / gap」哨兵值。
const int _kNoHighlight = -1;

/// 在**有序** cue 列表里找包含时刻 [t] 的 cue 下标（`startMs <= t < endMs`）；无则 -1。
/// cue 已按 startMs 升序，命中区间可能重叠时取**第一个**包含 t 的 cue（读序优先）。
int _cueIndexAt(List<AudioCue> cues, int t) {
  for (int i = 0; i < cues.length; i++) {
    final AudioCue c = cues[i];
    if (t >= c.startMs && t < c.endMs) {
      return i;
    }
  }
  return _kNoHighlight;
}
