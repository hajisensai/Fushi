import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_export.dart';
import 'package:fushi/src/media/audiobook/mining_audio_clip.dart';
import 'package:fushi_audio/fushi_audio.dart';

void main() {
  group('classifyAudiobookClipSelection (TODO-945 M1 boundaries)', () {
    const AudioPlaybackRange validRange = AudioPlaybackRange(
      audioFileIndex: 0,
      startMs: 1000,
      endMs: 4000,
    );

    test('empty selection (incl. pure-gaiji → empty text) → emptySelection',
        () {
      // Pure-gaiji selections come through with empty text (JS strips gaiji
      // images), so the same branch covers both "no selection" and "gaiji only".
      for (final String text in <String>['', '   ', '\n\t']) {
        final AudiobookClipBoundaryResult result =
            classifyAudiobookClipSelection(
          selectedText: text,
          audioFileCount: 2,
          sentenceRange: validRange,
        );
        expect(result.kind, AudiobookClipBoundaryKind.emptySelection);
        expect(result.isExportable, isFalse);
        expect(result.range, isNull);
      }
    });

    test('no audio files → noAudio', () {
      final AudiobookClipBoundaryResult result = classifyAudiobookClipSelection(
        selectedText: '僕',
        audioFileCount: 0,
        sentenceRange: validRange,
      );
      expect(result.kind, AudiobookClipBoundaryKind.noAudio);
      expect(result.isExportable, isFalse);
    });

    test('null range (cross-chapter cue miss) → unsupportedRange', () {
      final AudiobookClipBoundaryResult result = classifyAudiobookClipSelection(
        selectedText: '僕は学校へ',
        audioFileCount: 2,
        sentenceRange: null,
      );
      expect(result.kind, AudiobookClipBoundaryKind.unsupportedRange);
      expect(result.isExportable, isFalse);
    });

    test('range with out-of-bounds audioFileIndex → unsupportedRange', () {
      final AudiobookClipBoundaryResult result = classifyAudiobookClipSelection(
        selectedText: '僕',
        audioFileCount: 1,
        sentenceRange: const AudioPlaybackRange(
          audioFileIndex: 3,
          startMs: 1000,
          endMs: 4000,
        ),
      );
      expect(result.kind, AudiobookClipBoundaryKind.unsupportedRange);
    });

    test('degenerate range (endMs <= startMs) → unsupportedRange', () {
      final AudiobookClipBoundaryResult result = classifyAudiobookClipSelection(
        selectedText: '僕',
        audioFileCount: 1,
        sentenceRange: const AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 4000,
          endMs: 4000,
        ),
      );
      expect(result.kind, AudiobookClipBoundaryKind.unsupportedRange);
    });

    test('valid single-file range → exportable, range passed through', () {
      final AudiobookClipBoundaryResult result = classifyAudiobookClipSelection(
        selectedText: '僕は学校へ行った',
        audioFileCount: 2,
        sentenceRange: validRange,
      );
      expect(result.kind, AudiobookClipBoundaryKind.exportable);
      expect(result.isExportable, isTrue);
      expect(result.range, same(validRange));
    });
  });

  // D-RANGE empirical guard: `miningSentenceAudioRange` can NEVER return a
  // cross-file range — when adjacent cues live in a different audioFileIndex the
  // expansion loops break on the file boundary, so the result is always a single
  // audioFileIndex (the anchor cue's file). This is the fact M1 must rely on:
  // cross-file selections collapse to a single file's segment, and the caller
  // routes them through the unsupportedRange/exportable single-file path, never
  // a concat. If this assumption ever changes, this test goes red.
  group('miningSentenceAudioRange cross-file behaviour (D-RANGE fact)', () {
    test('cross-file adjacent cues do not merge across files', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 1000, endMs: 2000, text: '僕は', audioFileIndex: 0),
        _cue(startMs: 0, endMs: 1500, text: '学校へ行った', audioFileIndex: 1),
      ];

      // Anchor on the first cue (file 0); the sentence text spans both cues.
      final AudioPlaybackRange? clip = miningSentenceAudioRange(
        cues: cues,
        cue: cues[0],
        sentence: '僕は学校へ行った',
      );

      expect(clip, isNotNull);
      // Stays in file 0 — never a cross-file range.
      expect(clip!.audioFileIndex, 0);
      // Did not absorb file 1's end time. Phase 0 (d7cee212e / TODO-1115) appends
      // a tail pad to the exported clip; file 0's last cue has no same-file
      // successor, so its tail pad is uncapped and extends the end from the raw
      // 2000ms boundary by kMiningTailPadMs. The bound below therefore updates
      // from the pre-pad raw boundary (2000) to the pad-bounded boundary
      // (file 0 last cue endMs + kMiningTailPadMs). This proves the extension
      // comes from the same-file tail pad, NOT from absorbing file 1's timeline
      // (which would require audioFileIndex != 0, already excluded above).
      expect(clip.endMs, lessThanOrEqualTo(2000 + kMiningTailPadMs));
    });
  });

  group('clipCueSpansWithDelay (TODO-1147 highlight timebase)', () {
    test('delay 0 keeps cue times unchanged', () {
      final List<AudiobookClipCueSpan> spans = clipCueSpansWithDelay(
        span: <AudioCue>[
          _cue(startMs: 1000, endMs: 2000, text: '一'),
          _cue(startMs: 2000, endMs: 3000, text: '二'),
        ],
        delayMs: 0,
      );
      expect(spans, hasLength(2));
      expect(spans[0].startMs, 1000);
      expect(spans[0].endMs, 2000);
      expect(spans[1].startMs, 2000);
      expect(spans[1].endMs, 3000);
      expect(spans[0].text, '一');
    });

    test('positive delay shifts cue spans onto the shifted audio window', () {
      // 时基契约：音频窗口（clipExportGlobalRange）被 _shiftRange 平移 +delayMs，
      // cue 在音频里真实出现于 startMs+delayMs——帧计划的 cue 起止必须同步平移，
      // 否则逐句高亮整体偏移 delayMs（delay<0 时表现为固定迟钝）。
      final List<AudiobookClipCueSpan> spans = clipCueSpansWithDelay(
        span: <AudioCue>[_cue(startMs: 1000, endMs: 2000, text: '一')],
        delayMs: 250,
      );
      expect(spans.single.startMs, 1250);
      expect(spans.single.endMs, 2250);
    });

    test('negative delay shifts back, clamped at 0 with end > start', () {
      final List<AudiobookClipCueSpan> spans = clipCueSpansWithDelay(
        span: <AudioCue>[_cue(startMs: 100, endMs: 600, text: '一')],
        delayMs: -300,
      );
      // 起点镜像 _shiftRange clamp：不下穿 0；终点恒 > 起点。
      expect(spans.single.startMs, 0);
      expect(spans.single.endMs, 300);
      expect(spans.single.endMs, greaterThan(spans.single.startMs));
    });
  });
}

AudioCue _cue({
  required int startMs,
  required int endMs,
  required String text,
  int audioFileIndex = 0,
  String textFragmentId = '',
}) {
  final AudioCue cue = AudioCue();
  cue.bookKey = 'book';
  cue.chapterHref = 'ch.xhtml';
  cue.sentenceIndex = 0;
  cue.textFragmentId = textFragmentId;
  cue.text = text;
  cue.startMs = startMs;
  cue.endMs = endMs;
  cue.audioFileIndex = audioFileIndex;
  return cue;
}
