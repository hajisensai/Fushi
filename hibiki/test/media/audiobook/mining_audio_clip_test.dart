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
      expect(clip!.startMs, 1000);
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
      expect(clip!.startMs, 1000);
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
      expect(clip!.startMs, 9000);
      expect(clip.endMs, 12300);
    });

    test('falls back to the exact cue range without tail padding', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 6200, text: 'は');

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: '別の文',
      );

      expect(clip, isNotNull);
      expect(clip!.startMs, 5000);
      expect(clip.endMs, 6200);
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
      expect(clip!.startMs, 4750);
      expect(clip.endMs, 5950);
    });

    test('keeps invalid fallback ranges valid', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 5000, text: 'は');

      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: <AudioCue>[cue],
        cue: cue,
        sentence: '',
      );

      expect(clip, isNotNull);
      expect(clip!.startMs, 5000);
      expect(clip.endMs, 5001);
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
      expect(clip!.startMs, 1000);
      expect(clip.endMs, 4300);
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
      expect(clip!.startMs, 1000);
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
      expect(clip!.startMs, 1000);
      expect(clip.endMs, 4300);
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
