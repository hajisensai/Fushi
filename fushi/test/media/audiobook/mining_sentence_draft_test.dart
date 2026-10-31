import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/mining_audio_clip.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi_audio/fushi_audio.dart';

void main() {
  AudioPlaybackRange range(int fileIndex, int startMs, int endMs) =>
      AudioPlaybackRange(
        audioFileIndex: fileIndex,
        startMs: startMs,
        endMs: endMs,
      );

  group('joinMinedSentences', () {
    test(
      'single sentence is returned trimmed (equivalent to old behavior)',
      () {
        expect(joinMinedSentences(<String>['  これは一文です。 ']), 'これは一文です。');
      },
    );

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
      expect(mergeMiningAudioRanges(<AudioPlaybackRange?>[null, null]), isNull);
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
        <AudioPlaybackRange?>[range(0, 3200, 4100), range(0, 1000, 1800)],
      );
      expect(merged!.startMs, 1000);
      expect(merged.endMs, 4100);
    });

    test('null gaps between present ranges are skipped, still merges', () {
      final AudioPlaybackRange? merged = mergeMiningAudioRanges(
        <AudioPlaybackRange?>[range(0, 1000, 1800), null, range(0, 3200, 4100)],
      );
      expect(merged!.startMs, 1000);
      expect(merged.endMs, 4100);
    });

    test(
      'cross-file (cross-chapter) degrades to null — never splice bad audio',
      () {
        final AudioPlaybackRange? merged = mergeMiningAudioRanges(
          <AudioPlaybackRange?>[range(0, 1000, 1800), range(1, 200, 900)],
        );
        expect(merged, isNull);
      },
    );

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
      expect(draft.prevSentences.map((e) => e.sentence).toList(), <String>[
        '前1。',
        '前2。',
      ]);
      expect(draft.nextSentences.map((e) => e.sentence).toList(), <String>[
        '後1。',
      ]);
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

    // BUG-660：用户报视频制卡例句「アジアのほとんどを埋める砂漠で」重复两遍。沿真实代码
    // 路径（video_fushi lookup_mining `_resolveVideoMiningRange` →
    // `_miningDraft.composeText(_lastLookupSentence)`）：默认单句查词（未点上下文步进器，
    // 草稿空）时合成 sentence 字段必须恰是当前 cue 一份，绝不出现「当前句 × 2」。develop
    // 已单句（本守卫锁死反重复不变量，防未来把当前句拼两遍回归；与浏览器扩展 Netflix
    // 叶子 span 去重 BUG-593 是两条独立路径）。
    test('BUG-660: empty draft never doubles the current sentence', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      const String cue = 'アジアのほとんどを埋める砂漠で';
      final String composed = draft.composeText(cue);
      expect(composed, cue);
      // 反重复不变量：合成文本里当前句只出现一次（既非 "cuecue" 也非 "cue\ncue"）。
      expect(cue.allMatches(composed).length, 1);
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

    test(
      'prevSentences / nextSentences snapshots do not leak internal lists',
      () {
        final MiningSentenceDraft draft = MiningSentenceDraft();
        draft.setContext(prev: <MiningDraftSentence>[s('前。')]);
        expect(() => draft.prevSentences.add(s('x')), throwsUnsupportedError);
        expect(() => draft.nextSentences.add(s('x')), throwsUnsupportedError);
      },
    );
  });

  group('buildSentenceContextPreview (Niratan 制卡前调整模态)', () {
    MiningDraftSentence s(String text) => MiningDraftSentence(sentence: text);

    test(
      'empty draft yields prev/next empty, total 0, current + offset echoed',
      () {
        final MiningSentenceDraft draft = MiningSentenceDraft();
        final Map<String, Object?> p = buildSentenceContextPreview(
          draft: draft,
          current: '当前句。',
          currentOffset: 3,
        );
        expect(p['prev'], <String>[]);
        expect(p['next'], <String>[]);
        expect(p['current'], '当前句。');
        expect(p['currentOffset'], 3);
        expect(p['total'], 0);
      },
    );

    test(
      'prev/next real texts echoed in reading order, total = prev + next',
      () {
        final MiningSentenceDraft draft = MiningSentenceDraft();
        draft.setContext(
          prev: <MiningDraftSentence>[s('前々。'), s('前。')],
          next: <MiningDraftSentence>[s('后。')],
        );
        final Map<String, Object?> p = buildSentenceContextPreview(
          draft: draft,
          current: '当前。',
          currentOffset: null,
        );
        expect(p['prev'], <String>['前々。', '前。']);
        expect(p['next'], <String>['后。']);
        expect(p['current'], '当前。');
        expect(p['currentOffset'], isNull);
        expect(p['total'], 3);
      },
    );

    test(
      'result is JSON-safe (bridge-serializable) — String/int/List<String>',
      () {
        final MiningSentenceDraft draft = MiningSentenceDraft()
          ..setContext(prev: <MiningDraftSentence>[s('前。')]);
        final Map<String, Object?> p = buildSentenceContextPreview(
          draft: draft,
          current: 'x',
          currentOffset: 0,
        );
        expect(p['prev'], isA<List<String>>());
        expect(p['next'], isA<List<String>>());
        expect(p['current'], isA<String>());
        expect(p['total'], isA<int>());
      },
    );
  });

  group('MiningSentenceDraft.editSentence (user-edited sentence text)', () {
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

    MiningSentenceDraft draftWith({
      List<String> prev = const <String>[],
      List<String> next = const <String>[],
    }) => MiningSentenceDraft()
      ..setContext(
        prev: <MiningDraftSentence>[for (final String p in prev) s(p)],
        next: <MiningDraftSentence>[for (final String n in next) s(n)],
      );

    test(
      'editing a context sentence feeds composeText, original text kept',
      () {
        final MiningSentenceDraft draft = draftWith(prev: <String>['前一。']);
        expect(
          draft.editSentence(
            slot: SentenceContextSlot.prev,
            index: 0,
            text: '前一（改）。',
          ),
          isTrue,
        );
        expect(draft.composeText('現在。'), '前一（改）。\n現在。');
        // 原句仍在，供「还原」与重解析后贴回编辑用。
        expect(draft.prevSentences.single.sentence, '前一。');
        expect(draft.prevSentences.single.editedSentence, '前一（改）。');
        expect(draft.prevSentences.single.effectiveSentence, '前一（改）。');
      },
    );

    test('editing the current sentence overrides it in composeText', () {
      final MiningSentenceDraft draft = draftWith(next: <String>['後一。']);
      draft.editSentence(
        slot: SentenceContextSlot.current,
        index: 0,
        text: '現在（改）。',
      );
      expect(draft.currentSentenceEdit, '現在（改）。');
      expect(draft.composeText('現在。'), '現在（改）。\n後一。');
    });

    test('edits survive setContext re-resolution (keyed by original text)', () {
      final MiningSentenceDraft draft = draftWith(prev: <String>['前一。']);
      draft.editSentence(
        slot: SentenceContextSlot.prev,
        index: 0,
        text: '前一（改）。',
      );
      // 用户接着点「前加一句」：宿主整体重解析，前文变成两句，已改的那句后移一位。
      draft.setContext(prev: <MiningDraftSentence>[s('前二。'), s('前一。')]);
      expect(draft.prevSentences[1].effectiveSentence, '前一（改）。');
      expect(draft.prevSentences[0].effectiveSentence, '前二。');
      expect(draft.composeText('現在。'), '前二。\n前一（改）。\n現在。');
    });

    test(
      'blank text restores the original instead of writing an empty line',
      () {
        final MiningSentenceDraft draft = draftWith(prev: <String>['前一。']);
        draft.editSentence(
          slot: SentenceContextSlot.prev,
          index: 0,
          text: '前一（改）。',
        );
        draft.editSentence(
          slot: SentenceContextSlot.prev,
          index: 0,
          text: '   ',
        );
        expect(draft.prevSentences.single.editedSentence, isNull);
        expect(draft.composeText('現在。'), '前一。\n現在。');
        expect(draft.hasEdits, isFalse);
      },
    );

    test('editing back to the original text clears the edit', () {
      final MiningSentenceDraft draft = draftWith(next: <String>['後一。']);
      draft.editSentence(
        slot: SentenceContextSlot.next,
        index: 0,
        text: '後一（改）。',
      );
      expect(draft.hasEdits, isTrue);
      draft.editSentence(slot: SentenceContextSlot.next, index: 0, text: '後一。');
      expect(draft.hasEdits, isFalse);
      expect(draft.nextSentences.single.editedSentence, isNull);
    });

    test('blank current edit clears the override', () {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      draft.editSentence(
        slot: SentenceContextSlot.current,
        index: 0,
        text: '現在（改）。',
      );
      draft.editSentence(slot: SentenceContextSlot.current, index: 0, text: '');
      expect(draft.currentSentenceEdit, isNull);
      expect(draft.composeText('現在。'), '現在。');
    });

    test('out-of-range index is a no-op and reports false', () {
      final MiningSentenceDraft draft = draftWith(prev: <String>['前一。']);
      expect(
        draft.editSentence(slot: SentenceContextSlot.prev, index: 3, text: 'x'),
        isFalse,
      );
      expect(draft.hasEdits, isFalse);
      expect(draft.composeText('現在。'), '前一。\n現在。');
    });

    test(
      'editing text never moves the audio range (mirrors sentenceOverride)',
      () {
        final MiningSentenceDraft draft = MiningSentenceDraft()
          ..setContext(
            prev: <MiningDraftSentence>[
              s('前一。', file: 0, start: 100, end: 200),
            ],
            next: <MiningDraftSentence>[
              s('後一。', file: 0, start: 500, end: 900),
            ],
          );
        draft.editSentence(
          slot: SentenceContextSlot.prev,
          index: 0,
          text: '前一（大改，长度完全不同）。',
        );
        draft.editSentence(
          slot: SentenceContextSlot.current,
          index: 0,
          text: '現在（改）。',
        );
        final AudioPlaybackRange? merged = draft.composeAudioRange(
          range(0, 250, 400),
        );
        expect(merged, isNotNull);
        expect(merged!.startMs, 100);
        expect(merged.endMs, 900);
        expect(draft.prevSentences.single.audioRange?.startMs, 100);
      },
    );

    test('clear() drops edits along with the context', () {
      final MiningSentenceDraft draft = draftWith(prev: <String>['前一。']);
      draft.editSentence(
        slot: SentenceContextSlot.prev,
        index: 0,
        text: '前一（改）。',
      );
      draft.editSentence(
        slot: SentenceContextSlot.current,
        index: 0,
        text: '現在（改）。',
      );
      draft.clear();
      expect(draft.hasEdits, isFalse);
      expect(draft.currentSentenceEdit, isNull);
      expect(draft.composeText('現在。'), '現在。');
      // 换词后重新出现同一句原文，不该带回上一个词条的改写。
      draft.setContext(prev: <MiningDraftSentence>[s('前一。')]);
      expect(draft.prevSentences.single.effectiveSentence, '前一。');
    });

    test('preview exposes edited text and drops the stale current offset', () {
      final MiningSentenceDraft draft = draftWith(prev: <String>['前一。']);
      draft.editSentence(
        slot: SentenceContextSlot.prev,
        index: 0,
        text: '前一（改）。',
      );
      Map<String, Object?> p = buildSentenceContextPreview(
        draft: draft,
        current: '現在。',
        currentOffset: 2,
      );
      expect(p['prev'], <String>['前一（改）。']);
      // 当前句没改：offset 照旧有效。
      expect(p['current'], '現在。');
      expect(p['currentOffset'], 2);

      draft.editSentence(
        slot: SentenceContextSlot.current,
        index: 0,
        text: '現在（改）。',
      );
      p = buildSentenceContextPreview(
        draft: draft,
        current: '現在。',
        currentOffset: 2,
      );
      expect(p['current'], '現在（改）。');
      // 偏移是按原句算的，套到改后的文本上会把高亮划错位置 → 必须置空。
      expect(p['currentOffset'], isNull);
    });
  });

  // 用户报「中间是旁白，也做进字幕了，不能删么 / 删除了确定也还变回原样」：
  // 「−」只能从两端减句，清空编辑框又被当成还原——中间那句没有任何办法拿掉。
  group('MiningSentenceDraft.setSentenceRemoved (drop a middle sentence)', () {
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

    MiningSentenceDraft draftWith({
      List<MiningDraftSentence> prev = const <MiningDraftSentence>[],
      List<MiningDraftSentence> next = const <MiningDraftSentence>[],
    }) => MiningSentenceDraft()..setContext(prev: prev, next: next);

    test('removing a middle sentence drops it from composeText', () {
      final MiningSentenceDraft draft = draftWith(
        prev: <MiningDraftSentence>[s('前二。'), s('あい'), s('前一。')],
      );
      expect(
        draft.setSentenceRemoved(
          slot: SentenceContextSlot.prev,
          index: 1,
          removed: true,
        ),
        isTrue,
      );
      expect(draft.composeText('現在。'), '前二。\n前一。\n現在。');
      // 仍占着上下文的位置：宿主按 length 重解析，keptLength 才是会进卡的句数。
      expect(draft.length, 3);
      expect(draft.keptLength, 2);
      expect(draft.prevSentences[1].removed, isTrue);
      expect(draft.hasEdits, isFalse);
    });

    test('restoring brings the sentence back', () {
      final MiningSentenceDraft draft = draftWith(
        next: <MiningDraftSentence>[s('後一。'), s('後二。')],
      );
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.next,
        index: 0,
        removed: true,
      );
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.next,
        index: 0,
        removed: false,
      );
      expect(draft.composeText('現在。'), '現在。\n後一。\n後二。');
      expect(draft.keptLength, 2);
    });

    test('removal follows the original sentence across setContext', () {
      final MiningSentenceDraft draft = draftWith(
        prev: <MiningDraftSentence>[s('あい'), s('前一。')],
      );
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.prev,
        index: 0,
        removed: true,
      );
      // 「前加一句」：宿主整体重解析，被移除的那句后移一位——移除必须跟着它走，
      // 不能留在下标 0 上砸到新加进来的句子。
      draft.setContext(
        prev: <MiningDraftSentence>[s('前三。'), s('あい'), s('前一。')],
      );
      expect(draft.prevSentences[0].removed, isFalse);
      expect(draft.prevSentences[1].removed, isTrue);
      expect(draft.composeText('現在。'), '前三。\n前一。\n現在。');
    });

    test('removed sentences do not contribute to the audio range', () {
      final MiningSentenceDraft draft = draftWith(
        prev: <MiningDraftSentence>[s('前一。', file: 0, start: 100, end: 200)],
        next: <MiningDraftSentence>[
          s('後一。', file: 0, start: 400, end: 500),
          s('後二。', file: 0, start: 600, end: 900),
        ],
      );
      const AudioPlaybackRange current = AudioPlaybackRange(
        audioFileIndex: 0,
        startMs: 250,
        endMs: 350,
      );
      // 去掉末尾一句：区间随之收窄到 後一 的结尾。
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.next,
        index: 1,
        removed: true,
      );
      AudioPlaybackRange? merged = draft.composeAudioRange(current);
      expect(merged!.startMs, 100);
      expect(merged.endMs, 500);
      // 去掉中间一句：首尾不变，音频照旧连续。
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.next,
        index: 1,
        removed: false,
      );
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.next,
        index: 0,
        removed: true,
      );
      merged = draft.composeAudioRange(current);
      expect(merged!.startMs, 100);
      expect(merged.endMs, 900);
    });

    test('current sentence cannot be removed; out of range is a no-op', () {
      final MiningSentenceDraft draft = draftWith(
        prev: <MiningDraftSentence>[s('前一。')],
      );
      expect(
        draft.setSentenceRemoved(
          slot: SentenceContextSlot.current,
          index: 0,
          removed: true,
        ),
        isFalse,
      );
      expect(
        draft.setSentenceRemoved(
          slot: SentenceContextSlot.prev,
          index: 5,
          removed: true,
        ),
        isFalse,
      );
      expect(draft.composeText('現在。'), '前一。\n現在。');
    });

    test('edit and removal are independent and both survive', () {
      final MiningSentenceDraft draft = draftWith(
        prev: <MiningDraftSentence>[s('前一。')],
      );
      draft.editSentence(
        slot: SentenceContextSlot.prev,
        index: 0,
        text: '前一（改）。',
      );
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.prev,
        index: 0,
        removed: true,
      );
      expect(draft.composeText('現在。'), '現在。');
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.prev,
        index: 0,
        removed: false,
      );
      expect(draft.composeText('現在。'), '前一（改）。\n現在。');
    });

    test('clear() forgets removals', () {
      final MiningSentenceDraft draft = draftWith(
        prev: <MiningDraftSentence>[s('あい')],
      );
      draft.setSentenceRemoved(
        slot: SentenceContextSlot.prev,
        index: 0,
        removed: true,
      );
      draft.clear();
      draft.setContext(prev: <MiningDraftSentence>[s('あい')]);
      expect(draft.prevSentences.single.removed, isFalse);
      expect(draft.composeText('現在。'), 'あい\n現在。');
    });

    test(
      'preview lists removed sentences with flags; total counts kept only',
      () {
        final MiningSentenceDraft draft = draftWith(
          prev: <MiningDraftSentence>[s('前一。'), s('あい')],
          next: <MiningDraftSentence>[s('後一。')],
        );
        draft.setSentenceRemoved(
          slot: SentenceContextSlot.prev,
          index: 1,
          removed: true,
        );
        final Map<String, Object?> p = buildSentenceContextPreview(
          draft: draft,
          current: '現在。',
        );
        expect(p['prev'], <String>['前一。', 'あい']);
        expect(p['prevRemoved'], <bool>[false, true]);
        expect(p['nextRemoved'], <bool>[false]);
        expect(p['total'], 2);
      },
    );
  });

  // BUG-3434：歌词模式与视频字幕共用的「相邻 cue 作上下文」切法。
  group('cueContextNeighbors', () {
    List<AudioCue> cues(int n) => <AudioCue>[
      for (int i = 0; i < n; i++)
        AudioCue()
          ..text = 'c$i'
          ..startMs = i * 1000
          ..endMs = i * 1000 + 900
          ..audioFileIndex = 0,
    ];
    List<String> texts(List<AudioCue> list) => <String>[
      for (final AudioCue c in list) c.text,
    ];

    test('takes adjacent cues before and after the anchor in order', () {
      final r = cueContextNeighbors(
        cues: cues(6),
        anchorIndex: 3,
        prevCount: 2,
        nextCount: 1,
      );
      expect(texts(r.prev), <String>['c1', 'c2']);
      expect(texts(r.next), <String>['c4']);
    });

    test('caps at both ends so "add one more" stops growing', () {
      final r = cueContextNeighbors(
        cues: cues(3),
        anchorIndex: 0,
        prevCount: 2,
        nextCount: 5,
      );
      expect(r.prev, isEmpty);
      expect(texts(r.next), <String>['c1', 'c2']);
    });

    test('zero or negative counts yield no context', () {
      final r = cueContextNeighbors(
        cues: cues(4),
        anchorIndex: 1,
        prevCount: 0,
        nextCount: -1,
      );
      expect(r.prev, isEmpty);
      expect(r.next, isEmpty);
    });

    test('anchor not in the list clears context instead of guessing', () {
      for (final int bad in <int>[-1, 4, 99]) {
        final r = cueContextNeighbors(
          cues: cues(4),
          anchorIndex: bad,
          prevCount: 1,
          nextCount: 1,
        );
        expect(r.prev, isEmpty, reason: 'anchor $bad');
        expect(r.next, isEmpty, reason: 'anchor $bad');
      }
    });
  });

  // BUG-3434 复核：歌词模式上下文句的音频区间必须取相邻 cue 自己的坐标，不能按
  // 查词句的章节号 / 文本去推断（跨章被换算进本章 → 整章区间；同文短句取到更早一句）。
  group('cueContextDraftSentences', () {
    AudioCue cue(
      String text,
      int startMs,
      int endMs, {
      int file = 0,
      int? section,
      int? ns,
      int? ne,
    }) => AudioCue()
      ..text = text
      ..startMs = startMs
      ..endMs = endMs
      ..audioFileIndex = file
      ..textFragmentId = section == null
          ? ''
          : SubtitleRematchCodec.encodeHit(
              sectionIndex: section,
              normCharStart: ns!,
              normCharEnd: ne!,
            );

    test('next sentence across a chapter boundary keeps its own audio and '
        'never widens the merged clip to the whole chapter', () {
      // 单文件有声书（m4b）：第 0 章三句，第 1 章两句；查词句是第 0 章末句。
      final List<AudioCue> cues = <AudioCue>[
        cue('一', 0, 1000, section: 0, ns: 0, ne: 10),
        cue('二', 1000, 2000, section: 0, ns: 10, ne: 20),
        cue('三', 2000, 3000, section: 0, ns: 20, ne: 30),
        cue('四', 3000, 4000, section: 1, ns: 0, ne: 10),
        cue('五', 4000, 5000, section: 1, ns: 10, ne: 20),
      ];
      final r = cueContextDraftSentences(
        cues: cues,
        anchorIndex: 2,
        prevCount: 0,
        nextCount: 1,
        audioFileCount: 1,
      );
      expect(r.next, hasLength(1));
      final AudioPlaybackRange next = r.next.single.audioRange!;
      expect(next.audioFileIndex, 0);
      expect(next.startMs, 3000);
      expect(next.endMs, 4000);

      final AudioPlaybackRange current = miningCueAudioRange(
        cues: cues,
        cue: cues[2],
      );
      final AudioPlaybackRange merged = mergeMiningAudioRanges(
        <AudioPlaybackRange?>[current, next],
      )!;
      expect(merged.startMs, 2000, reason: 'must not start at chapter 0 head');
      expect(merged.endMs, 4000);
    });

    test('previous sentence in the previous chapter on another audio file '
        'stays on its own file so merging degrades to text-only', () {
      final List<AudioCue> cues = <AudioCue>[
        cue('前章末', 8000, 9000, section: 0, ns: 40, ne: 50),
        cue('本章首', 0, 1000, file: 1, section: 1, ns: 0, ne: 10),
      ];
      final r = cueContextDraftSentences(
        cues: cues,
        anchorIndex: 1,
        prevCount: 1,
        nextCount: 0,
        audioFileCount: 2,
        headPadMs: 0,
        tailPadMs: 0,
      );
      final AudioPlaybackRange prev = r.prev.single.audioRange!;
      expect(prev.audioFileIndex, 0);
      expect(prev.startMs, 8000);
      expect(
        mergeMiningAudioRanges(<AudioPlaybackRange?>[
          prev,
          miningCueAudioRange(cues: cues, cue: cues[1]),
        ]),
        isNull,
      );
    });

    test('repeated short lines without positions resolve to the adjacent '
        'cue, not the first cue with the same text', () {
      final List<AudioCue> cues = <AudioCue>[
        cue('はい', 0, 500),
        cue('うん', 1000, 1500),
        cue('はい', 2000, 2500),
        cue('そうだね', 3000, 4000),
      ];
      final r = cueContextDraftSentences(
        cues: cues,
        anchorIndex: 3,
        prevCount: 1,
        nextCount: 0,
        audioFileCount: 1,
        headPadMs: 0,
        tailPadMs: 0,
      );
      final AudioPlaybackRange prev = r.prev.single.audioRange!;
      expect(prev.startMs, 2000);
      expect(prev.endMs, 2500);
    });

    test('applies A/V delay, uses the supplied display text, and drops audio '
        'for a cue whose file is not loaded', () {
      final List<AudioCue> cues = <AudioCue>[
        cue('raw-a', 1000, 2000),
        cue('raw-b', 2000, 3000),
        cue('raw-c', 3000, 4000, file: 5),
      ];
      final r = cueContextDraftSentences(
        cues: cues,
        anchorIndex: 1,
        prevCount: 1,
        nextCount: 1,
        audioFileCount: 1,
        textOf: (AudioCue c) => 'shown:${c.text}',
        delayMs: 100,
        headPadMs: 0,
        tailPadMs: 0,
      );
      expect(r.prev.single.sentence, 'shown:raw-a');
      expect(r.prev.single.audioRange!.startMs, 1100);
      expect(r.prev.single.audioRange!.endMs, 2100);
      expect(r.next.single.sentence, 'shown:raw-c');
      expect(r.next.single.audioRange, isNull);
    });
  });
}
