import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue({
  required int audioFileIndex,
  required int startMs,
  required int endMs,
  required String textFragmentId,
  String text = '',
}) {
  return AudioCue()
    ..bookKey = 'book1'
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = textFragmentId
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = audioFileIndex;
}

String _frag(int sec, int ns, int ne) => SasayakiMatchCodec.encodeHit(
      sectionIndex: sec,
      normCharStart: ns,
      normCharEnd: ne,
    );

void main() {
  group('position match (with normCharLength)', () {
    final cues = [
      _cue(
          audioFileIndex: 0,
          startMs: 0,
          endMs: 5000,
          textFragmentId: _frag(0, 0, 50),
          text: 'ああああ'),
      _cue(
          audioFileIndex: 0,
          startMs: 5000,
          endMs: 10000,
          textFragmentId: _frag(0, 50, 100),
          text: 'いいいい'),
      _cue(
          audioFileIndex: 0,
          startMs: 10000,
          endMs: 15000,
          textFragmentId: _frag(0, 100, 150),
          text: 'うううう'),
    ];

    test('single cue hit returns that cue range', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 0,
        normCharOffset: 10,
        normCharLength: 30,
      );
      expect(result, isNotNull);
      expect(result!.audioFileIndex, 0);
      expect(result.startMs, 0);
      expect(result.endMs, 5000);
    });

    test('multi-cue overlap merges startMs and endMs', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 0,
        normCharOffset: 30,
        normCharLength: 90,
      );
      expect(result, isNotNull);
      expect(result!.audioFileIndex, 0);
      expect(result.startMs, 0);
      expect(result.endMs, 15000);
    });

    test('no overlap returns null', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 1,
        normCharOffset: 0,
        normCharLength: 50,
      );
      expect(result, isNull);
    });
  });

  group('position match (without normCharLength — old data)', () {
    final cues = [
      _cue(
          audioFileIndex: 0,
          startMs: 0,
          endMs: 5000,
          textFragmentId: _frag(0, 0, 50)),
      _cue(
          audioFileIndex: 0,
          startMs: 5000,
          endMs: 10000,
          textFragmentId: _frag(0, 50, 100)),
    ];

    test('point-in-range returns containing cue', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 0,
        normCharOffset: 60,
      );
      expect(result, isNotNull);
      expect(result!.startMs, 5000);
      expect(result.endMs, 10000);
    });

    test('point outside all ranges returns nearest cue', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 0,
        normCharOffset: 200,
      );
      expect(result, isNotNull);
      expect(result!.startMs, 5000);
      expect(result.endMs, 10000);
    });
  });

  group('cross audioFileIndex — first contiguous segment', () {
    final cues = [
      _cue(
          audioFileIndex: 0,
          startMs: 50000,
          endMs: 60000,
          textFragmentId: _frag(0, 0, 50)),
      _cue(
          audioFileIndex: 0,
          startMs: 60000,
          endMs: 70000,
          textFragmentId: _frag(0, 50, 100)),
      _cue(
          audioFileIndex: 1,
          startMs: 0,
          endMs: 5000,
          textFragmentId: _frag(0, 100, 150)),
    ];

    test(
        'returns first contiguous audio-file segment when selection crosses files',
        () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 0,
        normCharOffset: 30,
        normCharLength: 100,
      );
      expect(result, isNotNull);
      expect(result!.audioFileIndex, 0);
      expect(result.startMs, 50000);
      expect(result.endMs, 70000);
    });
  });

  group('text fallback (no sectionIndex)', () {
    final cues = [
      _cue(
          audioFileIndex: 0,
          startMs: 0,
          endMs: 3000,
          textFragmentId: '',
          text: 'これは最初の文です'),
      _cue(
          audioFileIndex: 0,
          startMs: 3000,
          endMs: 6000,
          textFragmentId: '',
          text: '次の文になります'),
      _cue(
          audioFileIndex: 0,
          startMs: 6000,
          endMs: 9000,
          textFragmentId: '',
          text: 'そして最後の文です'),
    ];

    test('exact text match returns that cue', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
          cues: cues, text: '次の文になります');
      expect(result, isNotNull);
      expect(result!.startMs, 3000);
      expect(result.endMs, 6000);
    });

    test('normalized substring across adjacent cues merges range', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
          cues: cues, text: '最初の文です次の文に');
      expect(result, isNotNull);
      expect(result!.startMs, 0);
      expect(result.endMs, 6000);
    });

    test('no match returns null', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
          cues: cues, text: '全く関係ない文章');
      expect(result, isNull);
    });
  });

  group('position takes priority over text', () {
    final cues = [
      _cue(
          audioFileIndex: 0,
          startMs: 0,
          endMs: 5000,
          textFragmentId: _frag(0, 0, 50),
          text: 'ああああ'),
      _cue(
          audioFileIndex: 0,
          startMs: 5000,
          endMs: 10000,
          textFragmentId: _frag(0, 50, 100),
          text: 'いいいい'),
    ];

    test('position match wins even when text would match different cue', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 0,
        normCharOffset: 60,
        normCharLength: 20,
        text: 'ああああ',
      );
      expect(result, isNotNull);
      expect(result!.startMs, 5000);
      expect(result.endMs, 10000);
    });
  });

  group('edge cases', () {
    test('empty cues returns null', () {
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: [],
        sectionIndex: 0,
        normCharOffset: 0,
        normCharLength: 50,
      );
      expect(result, isNull);
    });

    test('no sasayaki cues falls through to text', () {
      final cues = [
        _cue(
            audioFileIndex: 0,
            startMs: 0,
            endMs: 5000,
            textFragmentId: 'srt://1',
            text: 'テスト文'),
      ];
      final result = CollectionAudioMatcher.findPlaybackRange(
        cues: cues,
        sectionIndex: 0,
        normCharOffset: 0,
        normCharLength: 10,
        text: 'テスト文',
      );
      expect(result, isNotNull);
      expect(result!.startMs, 0);
    });
  });
}
