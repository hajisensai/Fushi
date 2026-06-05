import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

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
    ..textFragmentId = SasayakiMatchCodec.encodeHit(
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
  group('buildSasayakiPayload (BUG-060)', () {
    test('每条 entry 带 id/start/length/text，且 text == cue.text', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(sentenceIndex: 0, section: 0, ns: 10, ne: 18, text: '吾輩は猫である'),
        _cue(sentenceIndex: 1, section: 0, ns: 30, ne: 41, text: '名前はまだ無い'),
      ];

      final payload = AudiobookBridge.buildSasayakiPayload(cues, 0);

      expect(payload.length, 2);
      expect(payload.first.keys,
          containsAll(<String>['id', 'start', 'length', 'text']));
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

      final payload = AudiobookBridge.buildSasayakiPayload(cues, 1);

      expect(payload.length, 1);
      expect(payload.single['text'], 'かきくけこ');
    });

    test('非 sasayaki 的 cue 被跳过', () {
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
          AudiobookBridge.buildSasayakiPayload(<AudioCue>[plain], 0), isEmpty);
    });
  });
}
