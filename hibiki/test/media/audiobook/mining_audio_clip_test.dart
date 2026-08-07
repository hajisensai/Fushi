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
    test(
        'recovers gap-word sentence audio for non-rematch-encoded cues via text',
        () {
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

  group('miningSentenceCueSpan (TODO-1115 多句连读)', () {
    test('maps a 3-sentence position span to ordered same-file cues', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
            startMs: 1000,
            endMs: 1600,
            text: '第一句',
            textFragmentId: _frag(0, 0, 10)),
        _cue(
            startMs: 1600,
            endMs: 2300,
            text: '第二句',
            textFragmentId: _frag(0, 10, 20)),
        _cue(
            startMs: 2300,
            endMs: 4300,
            text: '第三句',
            textFragmentId: _frag(0, 20, 30)),
        _cue(
            startMs: 4300,
            endMs: 5200,
            text: '句外',
            textFragmentId: _frag(0, 30, 40)),
      ];
      // 选区覆盖 [0, 30) → 前三句命中，第四句（30..40）在选区之外。
      final List<AudioCue> span = miningSentenceCueSpan(
        cues: cues,
        cue: cues[0],
        sentence: '第一句第二句第三句',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 30,
      );
      expect(span.length, 3);
      expect(span.map((AudioCue c) => c.text).toList(),
          <String>['第一句', '第二句', '第三句']);
      // 升序（startMs 递增）。
      for (int i = 1; i < span.length; i++) {
        expect(span[i].startMs, greaterThanOrEqualTo(span[i - 1].startMs));
      }
    });

    test('single-sentence selection degenerates to a one-element span', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
            startMs: 1000,
            endMs: 1600,
            text: '一句',
            textFragmentId: _frag(0, 0, 10)),
        _cue(
            startMs: 1600,
            endMs: 2300,
            text: '二句',
            textFragmentId: _frag(0, 10, 20)),
      ];
      final List<AudioCue> span = miningSentenceCueSpan(
        cues: cues,
        cue: cues[0],
        sentence: '一句',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 10,
      );
      expect(span.length, 1);
      expect(span.first.text, '一句');
    });

    test('drops cross-file cues, keeps only first hit file', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
            startMs: 1000,
            endMs: 2000,
            text: 'A',
            textFragmentId: _frag(0, 0, 10)),
        _cue(
            startMs: 0, endMs: 900, text: 'B', textFragmentId: _frag(0, 10, 20))
          ..audioFileIndex = 1,
      ];
      // 两句都在 section 0 的选区 [0,20)，但属不同文件 → 只保留第一命中文件（file 0）。
      final List<AudioCue> span = miningSentenceCueSpan(
        cues: cues,
        cue: cues[0],
        sentence: 'AB',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 20,
      );
      expect(span.length, 1);
      expect(span.first.audioFileIndex, 0);
    });

    test('empty cues → empty span', () {
      final List<AudioCue> span = miningSentenceCueSpan(
        cues: const <AudioCue>[],
        cue: null,
        sentence: 'x',
        sectionIndex: 0,
        sentenceNormCharOffset: 0,
        sentenceNormCharLength: 10,
      );
      expect(span, isEmpty);
    });

    test('text fallback collects contiguous cues covering the sentence', () {
      // 无 sasayaki 位置（plain selector），走文本兜底。
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 500, text: '前'),
        _cue(startMs: 500, endMs: 1500, text: '本文'),
        _cue(startMs: 1500, endMs: 2000, text: 'です'),
        _cue(startMs: 2000, endMs: 2500, text: '次'),
      ];
      final List<AudioCue> span = miningSentenceCueSpan(
        cues: cues,
        cue: cues[1],
        sentence: '本文です',
      );
      expect(span.map((AudioCue c) => c.text).toList(), <String>['本文', 'です']);
    });
  });

  group('clipExportGlobalRange (TODO-1115 整段完整音频窗口)', () {
    test('start = first head-padded, end = last tail-padded (widened tail)',
        () {
      // 首句 [1000,1600)、中间句 [1600,2300)、末句 [2300,4300)，末句后无 cue → 尾无 cap。
      final List<AudioCue> cues = <AudioCue>[
        _cue(
            startMs: 1000,
            endMs: 1600,
            text: '一',
            textFragmentId: _frag(0, 0, 10)),
        _cue(
            startMs: 1600,
            endMs: 2300,
            text: '二',
            textFragmentId: _frag(0, 10, 20)),
        _cue(
            startMs: 2300,
            endMs: 4300,
            text: '三',
            textFragmentId: _frag(0, 20, 30)),
      ];
      final List<AudioCue> span = <AudioCue>[cues[0], cues[1], cues[2]];
      final AudioPlaybackRange? global = clipExportGlobalRange(
        span: span,
        allCues: cues,
      );
      expect(global, isNotNull);
      // head: 1000 - kMiningHeadPadMs(120) = 880。
      expect(global!.startMs, 880);
      // tail: 末句 4300 + kClipExportTailPadMs(600) = 4900（无后续 cue 不被 cap）。
      expect(global.endMs, 4900);
      expect(global.audioFileIndex, 0);
    });

    test('middle cues stay continuous, not cut by tailCap', () {
      // 中间句紧接下一句，只有末句尾 padding 可越界；中间不被切。
      final List<AudioCue> cues = <AudioCue>[
        _cue(
            startMs: 1000,
            endMs: 2000,
            text: '一',
            textFragmentId: _frag(0, 0, 10)),
        _cue(
            startMs: 2000,
            endMs: 3000,
            text: '二',
            textFragmentId: _frag(0, 10, 20)),
        // 末句后紧跟一个不属于选区的 cue（tailCap 生效，尾 padding 被 clamp 到它）。
        _cue(
            startMs: 3050,
            endMs: 4000,
            text: '外',
            textFragmentId: _frag(0, 20, 30)),
      ];
      final List<AudioCue> span = <AudioCue>[cues[0], cues[1]];
      final AudioPlaybackRange? global = clipExportGlobalRange(
        span: span,
        allCues: cues,
      );
      expect(global, isNotNull);
      expect(global!.startMs, 880); // 1000-120
      // 末句 endMs=3000 + 600 = 3600，但被下一 cue start 3050 capped → 3050。
      expect(global.endMs, 3050);
    });

    test('empty span → null', () {
      expect(
        clipExportGlobalRange(
            span: const <AudioCue>[], allCues: const <AudioCue>[]),
        isNull,
      );
    });

    test('applies A/V delay to both edges', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(
            startMs: 1000,
            endMs: 2000,
            text: '一',
            textFragmentId: _frag(0, 0, 10)),
      ];
      final AudioPlaybackRange? global = clipExportGlobalRange(
        span: cues,
        allCues: cues,
        delayMs: 100,
      );
      expect(global, isNotNull);
      // (1000-120)+100 = 980；(2000+600)+100 = 2700。
      expect(global!.startMs, 980);
      expect(global.endMs, 2700);
    });
  });

  // TODO-1256（用户回访「对不上」）: 逐句高亮切换帧必须对齐句音频起点。导出视频音视频
  // 锁定——帧 i 播放音频 [globalStart+i*Δ, globalStart+(i+1)*Δ)，某句声音在视频时刻
  // (S-globalStart) 被听到，切换帧应落在离它**最近**的帧边界 round((S-globalStart)/Δ)。
  // 帧起点采样 = ceil = 最多晚 Δ（迟钝）；帧尾采样 = floor = 最多早 Δ（TODO-1147 矫枉过正
  // 的「提前太多」）；帧中心采样 = round = 最近，对称误差 ≤Δ/2。这些用例把切换帧钉死在
  // round 上，任一方向的回归（回退帧尾/帧起点采样）都会变红。
  group('clipFramePlan (TODO-1256 帧-cue 对齐)', () {
    // fps=10 → Δ=100ms，帧中心在 50,150,250,...。整段 [0,1000) 共 10 帧。
    // 用「首段（第 0 句）持续帧数」= 切换到第 1 句的帧号，作为对齐判据。
    int switchFrame(List<ClipFrameSpec> plan) {
      expect(plan, isNotEmpty);
      expect(plan.first.highlightCueIndex, 0);
      return plan.first.frameCount;
    }

    test('rounds the switch UP when the cue start sits past the frame center',
        () {
      // 第二句起点 260ms：round(2.6)=3。帧尾采样(floor)会误在帧 2 切（早 60ms）。
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 260, text: '一'),
        _cue(startMs: 260, endMs: 1000, text: '二'),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      // 帧中心 = round：帧 3（视频 300ms，声音 260ms → 40ms 迟，最近边界）。
      // 帧尾 = floor 会给 2（视频 200ms → 60ms 早）：回归即变红。
      expect(switchFrame(plan), 3);
    });

    test(
        'rounds the switch DOWN when the cue start sits before the frame center',
        () {
      // 第二句起点 240ms：round(2.4)=2。帧起点采样(ceil)会误在帧 3 切（晚 60ms，迟钝）。
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 240, text: '一'),
        _cue(startMs: 240, endMs: 1000, text: '二'),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      // 帧中心 = round：帧 2（视频 200ms，声音 240ms → 40ms 早）。
      // 帧起点 = ceil 会给 3（视频 300ms → 60ms 迟）：回归即变红。
      expect(switchFrame(plan), 2);
    });

    test('a cue starting at the window origin highlights from frame 0', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 500, text: '一'),
        _cue(startMs: 500, endMs: 1000, text: '二'),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      // 500 是帧边界 → round=5，两侧采样一致，首句正好占前 5 帧。
      expect(plan.first.highlightCueIndex, 0);
      expect(switchFrame(plan), 5);
    });

    test(
        'is translation-invariant: a shared A/V delay offset never shifts the '
        'per-cue frame plan', () {
      // 时基契约（TODO-1147 第二根因已修）：globalStart 与 cue 起止在导出侧被同一
      // delayMs 平移，帧计划只取决于 (cueStart - globalStart)。给二者加同一偏移，
      // 计划必须逐段完全一致——否则说明帧计划错误依赖了绝对时基（delay 会整体拉偏）。
      List<ClipFrameSpec> planWith(int off) => clipFramePlan(
            cues: <AudioCue>[
              _cue(startMs: off + 0, endMs: off + 260, text: '一'),
              _cue(startMs: off + 260, endMs: off + 1000, text: '二'),
            ],
            globalStartMs: off + 0,
            globalEndMs: off + 1000,
            fps: 10,
          );
      expect(planWith(500), planWith(0));
      expect(planWith(-300), planWith(0));
    });

    test('frame counts sum to the total frame count', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 260, text: '一'),
        _cue(startMs: 260, endMs: 1000, text: '二'),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      final int total =
          plan.fold(0, (int a, ClipFrameSpec s) => a + s.frameCount);
      expect(total, 10); // ceil(1000 / 100)
    });

    test('leading head-padding silence holds no highlight until the first cue',
        () {
      // globalStart 在首句前留 200ms head padding（帧 0/1 落在句前静音）。默认
      // holdPrevious 但此前无句 → 前两帧无高亮(-1)，帧 2 起才亮第 0 句。
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 200, endMs: 1000, text: '一'),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      expect(plan.first.highlightCueIndex, -1); // gap，无上一句可保持
      expect(plan.first.frameCount, 2); // 帧 0(t=50)、帧 1(t=150) 都 < 200
      expect(plan[1].highlightCueIndex, 0); // 帧 2(t=250) 起亮首句
    });

    test('empty cues yield an empty plan (caller falls back to static)', () {
      expect(
        clipFramePlan(
          cues: const <AudioCue>[],
          globalStartMs: 0,
          globalEndMs: 1000,
          fps: 10,
        ),
        isEmpty,
      );
    });

    test('holdPrevious keeps the previous cue over an inter-sentence gap', () {
      // 两句之间有 [300,500) 的 gap（无 cue 覆盖）。默认 holdPrevious → gap 帧沿用
      // 上一句（第 0 句），不产生 -1 段。
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 300, text: '一'),
        _cue(startMs: 500, endMs: 1000, text: '二'),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      // 不应出现任何 -1 段（gap 被上一句覆盖）。
      expect(plan.any((ClipFrameSpec s) => s.highlightCueIndex == -1), isFalse);
    });

    test('ClipGapHighlight.none leaves inter-sentence gaps un-highlighted', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 300, text: '一'),
        _cue(startMs: 500, endMs: 1000, text: '二'),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
        gapHighlight: ClipGapHighlight.none,
      );
      // gap [300,500) 帧应为 -1（无高亮）。
      expect(plan.any((ClipFrameSpec s) => s.highlightCueIndex == -1), isTrue);
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
    SubtitleRematchCodec.encodeHit(
      sectionIndex: sectionIndex,
      normCharStart: start,
      normCharEnd: end,
    );
