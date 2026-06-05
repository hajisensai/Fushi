import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/pointer_seek.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

AudioCue _cue({required int sid, required String frag}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'c'
  ..sentenceIndex = sid
  ..textFragmentId = frag
  ..text = 't$sid'
  ..startMs = sid * 1000
  ..endMs = sid * 1000 + 500
  ..audioFileIndex = 0;

void main() {
  final cues = [
    _cue(sid: 0, frag: 'sasayaki://s=0&ns=0&ne=5'),
    _cue(sid: 1, frag: 'sasayaki://s=0&ns=5&ne=9'),
  ];

  test('frag payload resolves by textFragmentId', () {
    final cue = cueForPointerPayload(
        '{"type":"frag","id":"sasayaki://s=0&ns=5&ne=9"}', cues);
    expect(cue?.sentenceIndex, 1);
  });

  test('sid payload resolves by sentenceIndex (string id)', () {
    final cue = cueForPointerPayload('{"type":"sid","id":"0"}', cues);
    expect(cue?.sentenceIndex, 0);
  });

  test('unmatched id returns null', () {
    expect(cueForPointerPayload('{"type":"frag","id":"nope"}', cues), isNull);
  });

  test('garbage / null payload returns null', () {
    expect(cueForPointerPayload('null', cues), isNull);
    expect(cueForPointerPayload('not json', cues), isNull);
    expect(cueForPointerPayload('', cues), isNull);
  });

  group('button gate + lyrics boundary (real registry defaults)', () {
    HibikiShortcutRegistry registry() =>
        HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

    test('default middle button (1) is the seek button; others are not', () {
      final reg = registry();
      expect(isSeekToClickedSentenceButton(reg, 1), isTrue);
      expect(isSeekToClickedSentenceButton(reg, 2), isFalse);
      expect(isSeekToClickedSentenceButton(reg, -1), isFalse);
    });

    test('cueForLyricsPointer returns cue only for bound button + in-range idx',
        () {
      final reg = registry();
      expect(cueForLyricsPointer(reg, 1, 1, cues)?.sentenceIndex, 1);
      // Unbound button → no seek.
      expect(cueForLyricsPointer(reg, 2, 0, cues), isNull);
      // Out-of-range index → no seek (negative and past-end).
      expect(cueForLyricsPointer(reg, 1, -1, cues), isNull);
      expect(cueForLyricsPointer(reg, 1, cues.length, cues), isNull);
      // Empty cue list → no crash, no seek.
      expect(cueForLyricsPointer(reg, 1, 0, const <AudioCue>[]), isNull);
    });
  });
}
