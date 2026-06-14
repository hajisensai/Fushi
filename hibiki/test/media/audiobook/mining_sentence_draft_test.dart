import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/mining_sentence_draft.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  AudioPlaybackRange range(int fileIndex, int startMs, int endMs) =>
      AudioPlaybackRange(
        audioFileIndex: fileIndex,
        startMs: startMs,
        endMs: endMs,
      );

  group('joinMinedSentences', () {
    test('single sentence is returned trimmed (equivalent to old behavior)',
        () {
      expect(joinMinedSentences(<String>['  これは一文です。 ']), 'これは一文です。');
    });

    test('multiple sentences join with newline in order', () {
      expect(
        joinMinedSentences(<String>['一句目。', '二句目。', '三句目。']),
        '一句目。\n二句目。\n三句目。',
      );
    });

    test('blank and whitespace-only sentences are dropped', () {
      expect(
        joinMinedSentences(<String>['一句目。', '   ', '', '二句目。']),
        '一句目。\n二句目。',
      );
    });

    test('empty list yields empty string', () {
      expect(joinMinedSentences(<String>[]), '');
    });
  });

  group('mergeMiningAudioRanges', () {
    test('all null yields null (no audio to merge)', () {
      expect(
        mergeMiningAudioRanges(<AudioPlaybackRange?>[null, null]),
        isNull,
      );
    });

    test('same file merges to first start -> last end', () {
      final AudioPlaybackRange? merged = mergeMiningAudioRanges(
        <AudioPlaybackRange?>[
          range(0, 1000, 1800),
          range(0, 2200, 2800),
          range(0, 3200, 4100),
        ],
      );
      expect(merged, isNotNull);
      expect(merged!.audioFileIndex, 0);
      expect(merged.startMs, 1000);
      expect(merged.endMs, 4100);
    });

    test('out-of-order ranges still take global min start / max end', () {
      final AudioPlaybackRange? merged = mergeMiningAudioRanges(
        <AudioPlaybackRange?>[
          range(0, 3200, 4100),
          range(0, 1000, 1800),
        ],
      );
      expect(merged!.startMs, 1000);
      expect(merged.endMs, 4100);
    });

    test('null gaps between present ranges are skipped, still merges', () {
      final AudioPlaybackRange? merged = mergeMiningAudioRanges(
        <AudioPlaybackRange?>[
          range(0, 1000, 1800),
          null,
          range(0, 3200, 4100),
        ],
      );
      expect(merged!.startMs, 1000);
      expect(merged.endMs, 4100);
    });

    test('cross-file (cross-chapter) degrades to null — never splice bad audio',
        () {
      final AudioPlaybackRange? merged = mergeMiningAudioRanges(
        <AudioPlaybackRange?>[
          range(0, 1000, 1800),
          range(1, 200, 900),
        ],
      );
      expect(merged, isNull);
    });

    test('single present range is returned as-is', () {
      final AudioPlaybackRange? merged = mergeMiningAudioRanges(
        <AudioPlaybackRange?>[null, range(2, 500, 900), null],
      );
      expect(merged!.audioFileIndex, 2);
      expect(merged.startMs, 500);
      expect(merged.endMs, 900);
    });
  });

  group('MiningSentenceDraft', () {
    test('starts empty', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      expect(draft.isEmpty, isTrue);
      expect(draft.length, 0);
    });

    test('append accumulates non-empty sentences in order', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      expect(
        draft.append(const MiningDraftSentence(sentence: '一句目。')),
        isTrue,
      );
      expect(
        draft.append(const MiningDraftSentence(sentence: '二句目。')),
        isTrue,
      );
      expect(draft.length, 2);
      expect(draft.isEmpty, isFalse);
    });

    test('append ignores blank / whitespace-only sentences', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      expect(draft.append(const MiningDraftSentence(sentence: '')), isFalse);
      expect(draft.append(const MiningDraftSentence(sentence: '   ')), isFalse);
      expect(draft.isEmpty, isTrue);
    });

    test('composeText joins draft sentences plus current sentence', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.append(const MiningDraftSentence(sentence: '一句目。'));
      draft.append(const MiningDraftSentence(sentence: '二句目。'));
      expect(draft.composeText('三句目。'), '一句目。\n二句目。\n三句目。');
    });

    test('composeText with empty draft equals the current sentence', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      expect(draft.composeText('  唯一の一文。 '), '唯一の一文。');
    });

    test('clear empties the buffer', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.append(const MiningDraftSentence(sentence: '一句目。'));
      draft.clear();
      expect(draft.isEmpty, isTrue);
      expect(draft.composeText('現在の文。'), '現在の文。');
    });

    test('composeAudioRange merges draft ranges plus current range', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.append(MiningDraftSentence(
        sentence: '一句目。',
        audioRange: AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 1000,
          endMs: 1800,
        ),
      ));
      draft.append(MiningDraftSentence(
        sentence: '二句目。',
        audioRange: AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 2200,
          endMs: 2800,
        ),
      ));
      final AudioPlaybackRange? merged = draft.composeAudioRange(
        AudioPlaybackRange(audioFileIndex: 0, startMs: 3200, endMs: 4100),
      );
      expect(merged!.startMs, 1000);
      expect(merged.endMs, 4100);
    });

    test('composeAudioRange degrades to null across audio files', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.append(MiningDraftSentence(
        sentence: '前章の文。',
        audioRange: AudioPlaybackRange(
          audioFileIndex: 0,
          startMs: 9000,
          endMs: 9500,
        ),
      ));
      final AudioPlaybackRange? merged = draft.composeAudioRange(
        AudioPlaybackRange(audioFileIndex: 1, startMs: 200, endMs: 900),
      );
      expect(merged, isNull);
    });

    test('unmodifiable sentences snapshot does not leak internal list', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.append(const MiningDraftSentence(sentence: '一句目。'));
      expect(
        () => draft.sentences.add(const MiningDraftSentence(sentence: 'x')),
        throwsUnsupportedError,
      );
    });
  });
}
