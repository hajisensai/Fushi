import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/mining_audio_clip.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi_audio/fushi_audio.dart';

void main() {
  test('audio resolves the second repeated sentence after a Latin prefix', () {
    // Learning units collapse ABC to one unit, whereas audio retains ABC.
    final ReaderSelectionData data =
        ReaderSelectionData.fromJson(<String, dynamic>{
          'text': '猫だ',
          'sentence': '猫だ',
          'normalizedOffset': 3,
          'normalizedLength': 2,
          'matchableOffset': 5,
          'matchableLength': 2,
          'sentenceMatchableOffset': 5,
          'sentenceMatchableLength': 2,
        });
    final List<AudioCue> cues = <AudioCue>[
      _cue('ABC', 0, 3),
      _cue('猫だ', 3, 5),
      _cue('猫だ', 5, 7),
    ];
    final List<AudioCue> hits = miningSentenceCueSpan(
      cues: cues,
      cue: null,
      sentence: data.sentence,
      sectionIndex: 0,
      sentenceNormCharOffset: data.sentenceMatchableOffset,
      sentenceNormCharLength: data.sentenceMatchableLength,
    );
    expect(hits, <AudioCue>[cues.last]);
    expect(data.normalizedOffset, 3);
  });

  test(
    'legacy selection does not promote learning units into audio positions',
    () {
      final ReaderSelectionData data =
          ReaderSelectionData.fromJson(<String, dynamic>{
            'text': '猫だ',
            'sentence': '猫だ',
            'normalizedOffset': 3,
            'normalizedLength': 2,
            'sentenceNormalizedOffset': 3,
            'sentenceNormalizedLength': 2,
          });
      expect(data.matchableOffset, isNull);
      expect(data.matchableLength, isNull);
      expect(data.sentenceMatchableOffset, isNull);
      expect(data.sentenceMatchableLength, isNull);
    },
  );

  test(
    'lookup, context menu and audio export keep coordinate domains separate',
    () {
      const String directory = 'lib/src/pages/implementations/reader_fushi/';
      for (final String file in <String>[
        'lookup.part.dart',
        'chrome.part.dart',
      ]) {
        final String source = File('$directory$file').readAsStringSync();
        expect(
          source,
          isNot(contains('_findCueForOffset(data.normalizedOffset!')),
        );
        // 查词 / 选区操作条的 cue 回退共用 chrome.part 的 [_cueForSelectionData]，
        // 两处都经它取 cue；偏移域在它的函数体里钉（见下）。
        expect(source, contains('_cueForSelectionData(data)'));
        expect(source, contains('_cacheMatchableSelection(data)'));
      }
      final String chrome = File(
        '${directory}chrome.part.dart',
      ).readAsStringSync();
      final int helperAt = chrome.indexOf(
        'AudioCue? _cueForSelectionData(ReaderSelectionData data) {',
      );
      expect(helperAt, isNonNegative);
      final String helper = chrome.substring(
        helperAt,
        chrome.indexOf('\n  }\n', helperAt),
      );
      expect(helper, contains('_findCueForOffset(data.matchableOffset!'));
      expect(helper, isNot(contains('normalizedOffset')));
      final String audio = File(
        '${directory}audiobook.part.dart',
      ).readAsStringSync();
      final String span = audio.substring(
        audio.indexOf('  ({int offset, int length})? _miningSpanRange()'),
        audio.indexOf('  AudioPlaybackRange? _sentenceAudioRangeFor('),
      );
      expect(span, contains('_cachedMatchableSentenceRange'));
      expect(span, contains('_cachedMatchableSelectionRange'));
      expect(span, isNot(contains('_cachedSentenceRange')));
      expect(span, isNot(contains('_cachedSelectionRange')));
      final String export = audio.substring(
        audio.indexOf('  _buildAudiobookClipPlan('),
        audio.indexOf('    final String sentence = resolvedSelection.text;'),
      );
      expect(export, contains('_cachedMatchableSelectionRange'));
    },
  );
}

AudioCue _cue(String text, int start, int end) => AudioCue()
  ..bookKey = 'book'
  ..chapterHref = 'chapter.xhtml'
  ..sentenceIndex = start
  ..textFragmentId = SubtitleRematchCodec.encodeHit(
    sectionIndex: 0,
    normCharStart: start,
    normCharEnd: end,
  )
  ..text = text
  ..startMs = start * 1000
  ..endMs = end * 1000
  ..audioFileIndex = 0;
