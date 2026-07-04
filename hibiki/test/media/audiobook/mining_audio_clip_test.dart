import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('miningSentenceAudioRange', () {
    test('uses the complete sentence range to merge overlapping cues', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
          startMs: 1000,
          endMs: 1600,
          text: '僕',
          textFragmentId: _frag(0, 0, 10),
        ),
        _cue(
          startMs: 1600,
          endMs: 2300,
          text: 'は',
          textFragmentId: _frag(0, 10, 20),
        ),
        _cue(
          startMs: 2300,
          endMs: 4300,
          text: '学校へ行った',
          textFragmentId: _frag(0, 20, 60),
        ),
        _cue(
          startMs: 4300,
          endMs: 5200,
          text: '次の文',
          textFragmentId: _frag(0, 60, 80),
        ),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: cues[1],
        sentence: '「僕は学校へ行った。」',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 60,
      );

      expect(clip, isNotNull);
      // 880 = 1000 - kMiningHeadPadMs(120), floored at 0 (no earlier cue).
      // 4300 = tail padding capped at the next same-file cue start (4300).
      expect(clip!.startMs, 880);
      expect(clip.endMs, 4300);
    });

    test('expands adjacent cue text contained in the selected sentence', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 1000, endMs: 1600, text: '僕'),
        _cue(startMs: 1600, endMs: 2300, text: 'は'),
        _cue(startMs: 2300, endMs: 4300, text: '学校へ行った'),
        _cue(startMs: 4300, endMs: 5200, text: '次の文'),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: cues[1],
        sentence: '「僕は学校へ行った。」',
      );

      expect(clip, isNotNull);
      expect(clip!.startMs, 880);
      expect(clip.endMs, 4300);
    });

    test('expands around the current cue when repeated text lacks positions',
        () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 1000, endMs: 1600, text: '僕'),
        _cue(startMs: 1600, endMs: 2300, text: 'は'),
        _cue(startMs: 2300, endMs: 4300, text: '学校へ行った'),
        _cue(startMs: 9000, endMs: 9600, text: '僕'),
        _cue(startMs: 9600, endMs: 10300, text: 'は'),
        _cue(startMs: 10300, endMs: 12300, text: '学校へ行った'),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: cues[4],
        sentence: '僕は学校へ行った。',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 60,
      );

      expect(clip, isNotNull);
      // 8880 = 9000 - 120, floored at 4300 (prev same-file cue end).
      // 12500 = 12300 + kMiningTailPadMs(200), uncapped (no following cue).
      expect(clip!.startMs, 8880);
      expect(clip.endMs, 12500);
    });

    test('falls back to the exact cue range without tail padding', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 6200, text: 'は');

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: '別の文',
      );

      expect(clip, isNotNull);
      // 4880 = 5000 - 120 (no earlier cue), 6400 = 6200 + 200 (no later cue).
      expect(clip!.startMs, 4880);
      expect(clip.endMs, 6400);
    });

    test('applies playback delay by shifting the whole range', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 6200, text: 'は');

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: 'は',
        delayMs: -250,
      );

      expect(clip, isNotNull);
      // Padded 4880/6400 then shifted by delayMs -250 -> 4630/6150.
      expect(clip!.startMs, 4630);
      expect(clip.endMs, 6150);
    });

    test('keeps invalid fallback ranges valid', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 5000, text: 'は');

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: '',
      );

      expect(clip, isNotNull);
      // Repaired 5000/5001; head floored at the cue's own end (5000) so no head
      // padding, tail +200 uncapped -> 5000/5201.
      expect(clip!.startMs, 5000);
      expect(clip.endMs, 5201);
    });

    // BUG-172 / TODO-104a: gap word — the looked-up word fell in covered-but-
    // uncued text so the reader resolves no lookup cue (cue == null). The
    // sentence span must still recover the full audio range from the cues that
    // surround the gap. Reverting the cue-by-range fallback turns this red.
    test('recovers sentence audio for a gap word with no lookup cue', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
          startMs: 1000,
          endMs: 1600,
          text: '僕',
          textFragmentId: _frag(0, 0, 10),
        ),
        _cue(
          startMs: 1600,
          endMs: 2300,
          text: 'は',
          textFragmentId: _frag(0, 10, 20),
        ),
        _cue(
          startMs: 2300,
          endMs: 4300,
          text: '学校へ行った',
          textFragmentId: _frag(0, 20, 60),
        ),
      ];

      // cue == null mirrors _findCueForOffset returning null for a gap word; the
      // sentence still spans cues [0..2] via its normalized range.
      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: null,
        sentence: '「僕は学校へ行った。」',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 60,
      );

      expect(clip, isNotNull);
      // Only 3 cues (no trailing cue) -> tail uncapped: 4300 + 200 = 4500.
      expect(clip!.startMs, 880);
      expect(clip.endMs, 4500);
    });

    // TODO-811: local (non-sasayaki) audiobook. Every cue's textFragmentId is a
    // plain SRT selector ('[data-cue-id="N"]'), not a sasayaki-encoded fragment,
    // so position matching cannot use it. The looked-up word fell in an alignment
    // gap (cue == null). The sentence audio must still be recovered from the cue
    // texts via text matching - this is the exact case where local-audiobook
    // mining produced no sentence audio. Reverting the text-fallback turns it red.
    test('recovers gap-word sentence audio for non-sasayaki cues via text', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
          startMs: 1000,
          endMs: 1600,
          text: '僕',
          textFragmentId: '[data-cue-id="0"]',
        ),
        _cue(
          startMs: 1600,
          endMs: 2300,
          text: 'は',
          textFragmentId: '[data-cue-id="1"]',
        ),
        _cue(
          startMs: 2300,
          endMs: 4300,
          text: '学校へ行った',
          textFragmentId: '[data-cue-id="2"]',
        ),
        _cue(
          startMs: 4300,
          endMs: 5200,
          text: '次の文',
          textFragmentId: '[data-cue-id="3"]',
        ),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: null,
        sentence: '「僕は学校へ行った。」',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 60,
      );

      expect(clip, isNotNull);
      expect(clip!.startMs, 880);
      expect(clip.endMs, 4300);
    });

    // TODO-956 (C-audio): cue/reader divergence. The looked-up word's cue decoded
    // to section 1 (a neighbouring fragment the matcher mis-assigned), but the
    // reader's authoritative sentence span points to section 0, whose cues carry
    // sasayaki positions spanning the whole sentence. BEFORE the span-anchor
    // preference, the section guard returned null and _expandAroundCue tried a
    // contiguous-substring match around the section-1 cue; with divergent text it
    // recovered no range -> the card lost its sentence audio. AFTER, the span is
    // anchored by position in section 0 and the full range is recovered.
    test(
        'prefers the sentence span when the lookup cue decodes to another '
        'section', () {
      final List<AudioCue> cues = <AudioCue>[
        // Section 0 cues — the reader's actual sentence lives here.
        _cue(
          startMs: 1000,
          endMs: 1600,
          text: '僕',
          textFragmentId: _frag(0, 0, 10),
        ),
        _cue(
          startMs: 1600,
          endMs: 2300,
          text: 'は',
          textFragmentId: _frag(0, 10, 20),
        ),
        _cue(
          startMs: 2300,
          endMs: 4300,
          text: '学校へ行った',
          textFragmentId: _frag(0, 20, 60),
        ),
        // Section 1 cue — the matcher mis-assigned the looked-up word here.
        _cue(
          startMs: 8000,
          endMs: 8600,
          text: '別の章の語',
          textFragmentId: _frag(1, 0, 12),
        ),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: cues[3], // decodes to section 1, != span section 0
        sentence: '「僕は学校へ行った。」',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 60,
      );

      expect(clip, isNotNull);
      // 880 = 1000 - 120 (no earlier cue). 4500 = 4300 + 200 (next same-file cue
      // is at 8000, far enough not to cap).
      expect(clip!.startMs, 880);
      expect(clip.endMs, 4500);
    });

    // TODO-970 / BUG-458: empty DOM sentence span (offset/length null) + a non-null lookup
    // cue that sits OUTSIDE the sentence (the looked-up token landed on a
    // plain-selector boundary cue — punctuation / adjacent-sentence fragment —
    // common on local audiobooks whose cues carry no sasayaki positions). The
    // span guard trips (no normalized offset/length), so the old code returned
    // from the position attempt without trying text and fell straight into
    // _expandAroundCue. _expandAroundCue is cue-anchored: it only keeps text
    // matches that COVER the anchor cue and only expands to neighbours whose text
    // is a substring of the sentence. With the anchor cue outside the sentence,
    // the anchored match is rejected and expansion stops immediately, collapsing
    // to the single boundary cue — the wrong (or missing) audio. The plain
    // sentence-text search recovers the full range instead, so when there is
    // sentence text it must be tried even though cue != null.
    test(
        'recovers the full sentence via text when span is empty and the cue is '
        'outside the sentence', () {
      final List<AudioCue> cues = <AudioCue>[
        // Boundary cue the looked-up token landed on (plain selector, outside the
        // sentence the reader extracted). startMs marks it clearly distinct.
        _cue(
          startMs: 100,
          endMs: 300,
          text: '前の章の語',
          textFragmentId: '[data-cue-id="0"]',
        ),
        // The sentence '僕は学校へ行った' spans these three cues.
        _cue(
          startMs: 1000,
          endMs: 1600,
          text: '僕は',
          textFragmentId: '[data-cue-id="1"]',
        ),
        _cue(
          startMs: 1600,
          endMs: 2300,
          text: '学校へ',
          textFragmentId: '[data-cue-id="2"]',
        ),
        _cue(
          startMs: 2300,
          endMs: 4300,
          text: '行った',
          textFragmentId: '[data-cue-id="3"]',
        ),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: cues[0], // outside the sentence; span unavailable below
        sentence: '「僕は学校へ行った。」',
        sectionIndex: 0,
        sentenceNormCharOffset: null,
        sentenceNormCharLength: null,
      );

      expect(clip, isNotNull);
      // 880 = 1000 - 120, floored at 300 (prev same-file cue end).
      // 4500 = 4300 + 200 (no following cue to cap).
      expect(clip!.startMs, 880);
      expect(clip.endMs, 4500);
    });

    test('returns null when there is no cue and no usable sentence span', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
          startMs: 1000,
          endMs: 1600,
          text: '僕',
          textFragmentId: _frag(0, 0, 10),
        ),
      ];

      // No cue and no sentence offset/length: nothing can be derived, so the
      // mining gate must skip sentence audio rather than fabricate a range.
      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: null,
        sentence: '何か',
      );

      expect(clip, isNull);
    });

    test('returns null for a gap word when the section has no matching cues',
        () {
      // Sentence span points at section 1, but every cue belongs to section 0.
      final List<AudioCue> cues = <AudioCue>[
        _cue(
          startMs: 1000,
          endMs: 1600,
          text: '僕',
          textFragmentId: _frag(0, 0, 10),
        ),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: null,
        sentence: '僕は',
        sectionIndex: 1,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 20,
      );

      expect(clip, isNull);
    });

    // TODO-1009 / BUG-475: same-chapter selection on coarse-aligned audio
    // (TextToEpub + post-attached audio, alignment miss) where the matched
    // cue is zero-duration (startMs == endMs). Every cue-relative path copies
    // the cue's raw start/end, so the range came back degenerate
    // (endMs <= startMs) -> classifyAudiobookClipSelection labelled it
    // `unsupportedRange` -> user saw the misleading cross-chapter/cross-file
    // toast for a perfectly in-chapter selection. The range must be repaired to
    // a positive duration, never returned degenerate. Reverting
    // _ensurePositiveDuration turns this red.
    test('repairs a zero-duration single cue to a positive same-file range',
        () {
      final AudioCue cue = _cue(
        startMs: 5000,
        endMs: 5000,
        text: '僕は学校へ行った',
        textFragmentId: '[data-cue-id="0"]',
      );

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: '僕は学校へ行った',
      );

      expect(clip, isNotNull);
      expect(clip!.audioFileIndex, 0);
      // Same file, positive duration -> exportable, NOT a cross-chapter reject.
      expect(clip.endMs, greaterThan(clip.startMs));
    });

    // TODO-1009: when the degenerate range has a following same-file cue, the
    // repair extends the end to that next cue's start (the implied playback
    // length), not just a hard +1ms floor.
    test('repaired degenerate range extends to the next same-file cue start',
        () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
          startMs: 5000,
          endMs: 5000,
          text: '僕は',
          textFragmentId: '[data-cue-id="0"]',
        ),
        _cue(
          startMs: 5000,
          endMs: 5000,
          text: '学校へ行った',
          textFragmentId: '[data-cue-id="1"]',
        ),
        // Next cue boundary on the same file at 7000ms bounds the clip length.
        _cue(
          startMs: 7000,
          endMs: 8000,
          text: '次の文',
          textFragmentId: '[data-cue-id="2"]',
        ),
      ];

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: cues[0],
        sentence: '僕は学校へ行った',
      );

      expect(clip, isNotNull);
      expect(clip!.startMs, 5000);
      expect(clip.endMs, 7000);
    });
  });

  group('padSentenceRange', () {
    // Gap on both sides is large enough: head and tail both add the full padding.
    // Mutation guard: dropping either the head or tail expansion turns this red.
    test('adds full head and tail padding when the gap is wide', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 500, text: '前'),
        _cue(startMs: 2000, endMs: 4000, text: '本文'),
        _cue(startMs: 9000, endMs: 9500, text: '次'),
      ];
      const AudioPlaybackRange range = AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: 2000,
        endMs: 4000,
      );

      final AudioPlaybackRange padded = padSentenceRange(
        range,
        cues: cues,
        headPadMs: 120,
        tailPadMs: 200,
      );

      expect(padded.startMs, 2000 - 120);
      expect(padded.endMs, 4000 + 200);
      expect(padded.audioFileIndex, 0);
    });

    // The next same-file cue starts only 50ms after the range end: the tail must
    // be clamped to that neighbour's start, NOT extended the full 200ms.
    // Mutation guard: removing the tail cap makes endMs 4200 -> red.
    test('clamps the tail to the next same-file cue start', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 2000, endMs: 4000, text: '本文'),
        _cue(startMs: 4050, endMs: 5000, text: '次の文'),
      ];
      const AudioPlaybackRange range = AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: 2000,
        endMs: 4000,
      );

      final AudioPlaybackRange padded = padSentenceRange(
        range,
        cues: cues,
        headPadMs: 120,
        tailPadMs: 200,
      );

      // Head has no earlier cue -> floored at 0, full 120ms applied.
      expect(padded.startMs, 2000 - 120);
      // Tail capped at the next cue start (4050), not 4200.
      expect(padded.endMs, 4050);
    });

    // The previous same-file cue ends only 30ms before the range start: the head
    // must be clamped to that neighbour's end, NOT extended the full 120ms.
    // Mutation guard: removing the head floor makes startMs 1880 -> red.
    test('clamps the head to the previous same-file cue end', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 1000, endMs: 1970, text: '前の文'),
        _cue(startMs: 2000, endMs: 4000, text: '本文'),
      ];
      const AudioPlaybackRange range = AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: 2000,
        endMs: 4000,
      );

      final AudioPlaybackRange padded = padSentenceRange(
        range,
        cues: cues,
        headPadMs: 120,
        tailPadMs: 200,
      );

      // Head floored at the previous cue end (1970), not 1880.
      expect(padded.startMs, 1970);
      // No following cue -> tail uncapped.
      expect(padded.endMs, 4200);
    });

    // First sentence of the file (no earlier cue): head clamps to 0, never below
    // the file origin. Mutation guard: a missing `< 0` floor would go negative.
    test('clamps the head to zero at the file origin', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 50, endMs: 4000, text: '本文'),
      ];
      const AudioPlaybackRange range = AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: 50,
        endMs: 4000,
      );

      final AudioPlaybackRange padded = padSentenceRange(
        range,
        cues: cues,
        headPadMs: 120,
        tailPadMs: 200,
      );

      expect(padded.startMs, 0);
      expect(padded.startMs, greaterThanOrEqualTo(0));
      expect(padded.endMs, 4200);
    });

    // Last sentence of the file (no following cue): tail is uncapped here, ffmpeg
    // stops at EOF. And a neighbour in a DIFFERENT audio file must NOT clamp.
    test('ignores cues in other audio files when clamping', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 2000, endMs: 4000, text: '本文'),
        // Different file, right after the range end: must be ignored.
        _cue(startMs: 4010, endMs: 5000, text: '別ファイル')..audioFileIndex = 1,
      ];
      const AudioPlaybackRange range = AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: 2000,
        endMs: 4000,
      );

      final AudioPlaybackRange padded = padSentenceRange(
        range,
        cues: cues,
        headPadMs: 120,
        tailPadMs: 200,
      );

      expect(padded.startMs, 2000 - 120);
      // The file-1 cue at 4010 must NOT cap the tail -> full 200ms.
      expect(padded.endMs, 4200);
      expect(padded.audioFileIndex, 0);
    });

    test('zero padding leaves the range untouched', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 2000, endMs: 4000, text: '本文'),
      ];
      const AudioPlaybackRange range = AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: 2000,
        endMs: 4000,
      );

      final AudioPlaybackRange padded = padSentenceRange(
        range,
        cues: cues,
        headPadMs: 0,
        tailPadMs: 0,
      );

      expect(padded.startMs, 2000);
      expect(padded.endMs, 4000);
    });
  });
}

AudioCue _cue({
  required int startMs,
  required int endMs,
  String text = '吾輩は猫である。',
  String textFragmentId = '#s0',
}) {
  return AudioCue()
    ..bookKey = 'book'
    ..chapterHref = 'chapter.xhtml'
    ..sentenceIndex = 0
    ..textFragmentId = textFragmentId
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

String _frag(int sectionIndex, int start, int end) =>
    SasayakiMatchCodec.encodeHit(
      sectionIndex: sectionIndex,
      normCharStart: start,
      normCharEnd: end,
    );
