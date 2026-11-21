import 'dart:typed_data';

import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_silence.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

void main() {
  group('ttsTextIsSilent', () {
    test('punctuation / symbol / whitespace only lines are silent', () {
      for (final String text in <String>[
        '「！」',
        '！',
        '……',
        '――！？',
        '♪',
        '  　',
        '',
        '（……）',
      ]) {
        expect(ttsTextIsSilent(text), isTrue, reason: text);
      }
    });

    test('anything with a letter, kana, kanji or digit is spoken', () {
      for (final String text in <String>[
        '「あ！」',
        '――っ！',
        '何？',
        'ー',
        '123',
        'OK!',
        '々',
      ]) {
        expect(ttsTextIsSilent(text), isFalse, reason: text);
      }
    });
  });

  test('buildTtsSilenceWav is a WAV the cache probe accepts', () {
    final Uint8List bytes = buildTtsSilenceWav(
      ms: 800,
      sampleRate: kTtsSilentLineSampleRate,
      channels: 1,
    );
    expect(sniffTtsAudioFormat(bytes), TtsAudioFormat.wav);
    expect(probeTtsAudioDurationMs(bytes, TtsAudioFormat.wav), 800);
  });
}
