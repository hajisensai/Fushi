import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/pointer_seek.dart';

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
}
