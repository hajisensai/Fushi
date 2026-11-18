import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-060：sasayaki payload 必须带 cue 原文，运行时 JS 才能在实时 DOM
/// 就近重定位高亮（消除 package:html↔DOM 累积偏移）。
AudioCue _cue({
  required int sentenceIndex,
  required int section,
  required int ns,
  required int ne,
  required String text,
}) {
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = sentenceIndex
    ..textFragmentId = SubtitleRematchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: ns,
      normCharEnd: ne,
    )
    ..text = text
    ..startMs = 0
    ..endMs = 0
    ..audioFileIndex = 0;
}

void main() {
  group('buildSentenceAudioPayload (BUG-060)', () {
    test('每条 entry 带 id/start/length/text，且 text == cue.text', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(sentenceIndex: 0, section: 0, ns: 10, ne: 18, text: '吾輩は猫である'),
        _cue(sentenceIndex: 1, section: 0, ns: 30, ne: 41, text: '名前はまだ無い'),
      ];

      final payload = AudiobookBridge.buildSentenceAudioPayload(cues, 0);

      expect(payload.length, 2);
      expect(
        payload.first.keys,
        containsAll(<String>['id', 'start', 'length', 'text']),
      );
      expect(payload[0]['start'], 10);
      expect(payload[0]['length'], 8);
      expect(payload[0]['text'], '吾輩は猫である');
      expect(payload[1]['text'], '名前はまだ無い');
    });

    test('只保留目标 section 的 cue', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(sentenceIndex: 0, section: 0, ns: 0, ne: 5, text: 'あいうえお'),
        _cue(sentenceIndex: 1, section: 1, ns: 0, ne: 5, text: 'かきくけこ'),
      ];

      final payload = AudiobookBridge.buildSentenceAudioPayload(cues, 1);

      expect(payload.length, 1);
      expect(payload.single['text'], 'かきくけこ');
    });

    test('非 sentenceAudioHighlight 的 cue 被跳过', () {
      final AudioCue plain = AudioCue()
        ..bookKey = ''
        ..chapterHref = ''
        ..sentenceIndex = 0
        ..textFragmentId = 'srt://0'
        ..text = 'x'
        ..startMs = 0
        ..endMs = 0
        ..audioFileIndex = 0;

      expect(
        AudiobookBridge.buildSentenceAudioPayload(<AudioCue>[plain], 0),
        isEmpty,
      );
    });
  });

  group('sentenceAudioCueIndexFor（章 → 本章句级 cue 的派生索引）', () {
    AudioCue plain(int i) => AudioCue()
      ..bookKey = ''
      ..chapterHref = ''
      ..sentenceIndex = i
      ..textFragmentId = '[data-cue-id="$i"]'
      ..text = 'plain $i'
      ..startMs = 0
      ..endMs = 0
      ..audioFileIndex = 0;

    List<AudioCue> book() => <AudioCue>[
      _cue(sentenceIndex: 0, section: 2, ns: 0, ne: 5, text: 'さしすせそ'),
      plain(1),
      _cue(sentenceIndex: 2, section: 0, ns: 10, ne: 18, text: '吾輩は猫である'),
      _cue(sentenceIndex: 3, section: 2, ns: 9, ne: 12, text: 'たちつ'),
      _cue(sentenceIndex: 4, section: 0, ns: 30, ne: 41, text: '名前はまだ無い'),
    ];

    test('每一章的 payload 与 buildSentenceAudioPayload 逐位相同（含顺序）', () {
      final List<AudioCue> cues = book();
      final SentenceAudioCueIndex index =
          AudiobookBridge.sentenceAudioCueIndexFor(cues);
      for (final int section in <int>[0, 1, 2, 7]) {
        expect(
          index.payloadFor(section),
          AudiobookBridge.buildSentenceAudioPayload(cues, section),
          reason: 'section=$section',
        );
      }
      expect(
        index.payloadFor(2).map((Map<String, dynamic> e) => e['text']),
        <String>['さしすせそ', 'たちつ'],
      );
      expect(index.payloadFor(1), isEmpty);
      expect(index.hasSentenceAudio, isTrue);
    });

    test('同一个列表对象只建一次索引；换了列表对象各建各的', () {
      final List<AudioCue> cues = book();
      final SentenceAudioCueIndex first =
          AudiobookBridge.sentenceAudioCueIndexFor(cues);
      expect(
        identical(AudiobookBridge.sentenceAudioCueIndexFor(cues), first),
        isTrue,
        reason: '每装一章都来取，不能每次重新解码整书',
      );
      expect(
        identical(
          AudiobookBridge.sentenceAudioCueIndexFor(List<AudioCue>.of(cues)),
          first,
        ),
        isFalse,
        reason: '索引跟着列表对象走：整书 cue 换了列表就不得沿用旧索引',
      );
    });

    test('同一个列表对象长度变了：索引重建，新 cue 进 payload', () {
      final List<AudioCue> cues = book();
      final SentenceAudioCueIndex first =
          AudiobookBridge.sentenceAudioCueIndexFor(cues);
      expect(first.payloadFor(5), isEmpty);
      cues.add(_cue(sentenceIndex: 5, section: 5, ns: 0, ne: 3, text: 'なにぬ'));
      final SentenceAudioCueIndex second =
          AudiobookBridge.sentenceAudioCueIndexFor(cues);
      expect(identical(second, first), isFalse);
      expect(second.payloadFor(5).single['text'], 'なにぬ');
    });

    test('整书没有一条句级 cue：hasSentenceAudio 为 false，任何章都是空表', () {
      final SentenceAudioCueIndex index =
          AudiobookBridge.sentenceAudioCueIndexFor(<AudioCue>[
            plain(0),
            plain(1),
          ]);
      expect(index.hasSentenceAudio, isFalse);
      expect(index.payloadFor(0), isEmpty);
    });
  });
}
