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

  group('MiningSentenceDraft (TODO-393 directional context)', () {
    MiningDraftSentence s(String text, {int? file, int? start, int? end}) =>
        MiningDraftSentence(
          sentence: text,
          audioRange: file == null
              ? null
              : AudioPlaybackRange(
                  audioFileIndex: file,
                  startMs: start ?? 0,
                  endMs: end ?? 0,
                ),
        );

    test('starts empty', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      expect(draft.isEmpty, isTrue);
      expect(draft.length, 0);
    });

    test('setContext stores prev + next and counts both', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(
        prev: <MiningDraftSentence>[s('前1。'), s('前2。')],
        next: <MiningDraftSentence>[s('後1。')],
      );
      expect(draft.length, 3);
      expect(draft.isEmpty, isFalse);
      expect(draft.prevSentences.map((e) => e.sentence).toList(),
          <String>['前1。', '前2。']);
      expect(
          draft.nextSentences.map((e) => e.sentence).toList(), <String>['後1。']);
    });

    test('setContext filters blank / whitespace-only sentences', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(
        prev: <MiningDraftSentence>[s(''), s('  '), s('前。')],
        next: <MiningDraftSentence>[s('   ')],
      );
      expect(draft.length, 1);
      expect(draft.prevSentences.single.sentence, '前。');
      expect(draft.nextSentences, isEmpty);
    });

    test('setContext replaces (not accumulates) previous context', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(prev: <MiningDraftSentence>[s('上1。')]);
      expect(draft.length, 1);
      // Re-selecting "上2" replaces, not adds.
      draft.setContext(prev: <MiningDraftSentence>[s('上1。'), s('上2。')]);
      expect(draft.length, 2);
      draft.setContext();
      expect(draft.isEmpty, isTrue);
    });

    test('composeText orders prev -> current -> next', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(
        prev: <MiningDraftSentence>[s('前1。'), s('前2。')],
        next: <MiningDraftSentence>[s('後1。')],
      );
      expect(draft.composeText('現在。'), '前1。\n前2。\n現在。\n後1。');
    });

    test('composeText with empty context equals the current sentence', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      expect(draft.composeText('  唯一の一文。 '), '唯一の一文。');
    });

    test('clear empties the buffer', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(prev: <MiningDraftSentence>[s('前。')]);
      draft.clear();
      expect(draft.isEmpty, isTrue);
      expect(draft.composeText('現在の文。'), '現在の文。');
    });

    test('composeAudioRange merges prev + current + next in order', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(
        prev: <MiningDraftSentence>[s('前。', file: 0, start: 1000, end: 1800)],
        next: <MiningDraftSentence>[s('後。', file: 0, start: 3200, end: 4100)],
      );
      final AudioPlaybackRange? merged = draft.composeAudioRange(
        AudioPlaybackRange(audioFileIndex: 0, startMs: 2200, endMs: 2800),
      );
      expect(merged!.startMs, 1000);
      expect(merged.endMs, 4100);
    });

    test('composeAudioRange degrades to null across audio files', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(
        prev: <MiningDraftSentence>[s('前章。', file: 0, start: 9000, end: 9500)],
      );
      final AudioPlaybackRange? merged = draft.composeAudioRange(
        AudioPlaybackRange(audioFileIndex: 1, startMs: 200, endMs: 900),
      );
      expect(merged, isNull);
    });

    test('prevSentences / nextSentences snapshots do not leak internal lists',
        () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.setContext(prev: <MiningDraftSentence>[s('前。')]);
      expect(() => draft.prevSentences.add(s('x')), throwsUnsupportedError);
      expect(() => draft.nextSentences.add(s('x')), throwsUnsupportedError);
    });
  });
}
