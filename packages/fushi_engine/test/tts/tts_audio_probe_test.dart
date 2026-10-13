import 'dart:typed_data';

import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

void main() {
  group('sniffTtsAudioFormat', () {
    test('detects wav, mp3 (sync + ID3) and rejects garbage', () {
      expect(sniffTtsAudioFormat(buildWav()), TtsAudioFormat.wav);
      expect(sniffTtsAudioFormat(buildMp3(frames: 1)), TtsAudioFormat.mp3);
      expect(
        sniffTtsAudioFormat(Uint8List.fromList('ID3xxxxxxx'.codeUnits)),
        TtsAudioFormat.mp3,
      );
      expect(
        sniffTtsAudioFormat(Uint8List.fromList('<html>'.codeUnits)),
        isNull,
      );
      expect(sniffTtsAudioFormat(Uint8List(0)), isNull);
    });
  });

  group('WAV duration', () {
    test('plain PCM', () {
      // 8000Hz mono 16bit → 16000 B/s；16000 字节 = 1000ms
      expect(
        probeTtsAudioDurationMs(buildWav(dataBytes: 16000), TtsAudioFormat.wav),
        1000,
      );
      // 24000Hz mono 16bit, 12000 字节 = 250ms
      expect(
        probeTtsAudioDurationMs(
          buildWav(sampleRate: 24000, dataBytes: 12000),
          TtsAudioFormat.wav,
        ),
        250,
      );
    });

    test('skips unknown chunks with odd-size padding', () {
      expect(
        probeTtsAudioDurationMs(
          buildWav(dataBytes: 8000, extraChunk: true),
          TtsAudioFormat.wav,
        ),
        500,
      );
    });

    test('data size 0 or 0xFFFFFFFF uses remaining bytes', () {
      expect(
        probeTtsAudioDurationMs(
          buildWav(dataBytes: 8000, dataSizeField: 0),
          TtsAudioFormat.wav,
        ),
        500,
      );
      expect(
        probeTtsAudioDurationMs(
          buildWav(dataBytes: 4000, dataSizeField: 0xFFFFFFFF),
          TtsAudioFormat.wav,
        ),
        250,
      );
    });

    test('empty data, truncated header, garbage → null', () {
      expect(
        probeTtsAudioDurationMs(buildWav(dataBytes: 0), TtsAudioFormat.wav),
        isNull,
      );
      final Uint8List wav = buildWav();
      expect(
        probeTtsAudioDurationMs(
          Uint8List.sublistView(wav, 0, 24),
          TtsAudioFormat.wav,
        ),
        isNull,
      );
      expect(
        probeTtsAudioDurationMs(
          Uint8List.fromList(List<int>.generate(200, (int i) => i)),
          TtsAudioFormat.wav,
        ),
        isNull,
      );
      // MP3 内容按 WAV 探测 → null
      expect(
        probeTtsAudioDurationMs(buildMp3(frames: 3), TtsAudioFormat.wav),
        isNull,
      );
    });
  });

  group('MP3 duration', () {
    int expectedMs(int frames) => (frames * 1152 / 44100 * 1000).round();

    test('MPEG1 Layer III 128kbps 44.1kHz frames', () {
      expect(
        probeTtsAudioDurationMs(buildMp3(frames: 100), TtsAudioFormat.mp3),
        expectedMs(100),
      );
      expect(
        probeTtsAudioDurationMs(
          buildMp3(frames: 50, padding: true),
          TtsAudioFormat.mp3,
        ),
        expectedMs(50),
      );
      // 混合 417 / 418 字节帧
      final Uint8List mixed = Uint8List.fromList(<int>[
        ...buildMp3(frames: 10),
        ...buildMp3(frames: 10, padding: true),
        ...buildMp3(frames: 10),
      ]);
      expect(probeTtsAudioDurationMs(mixed, TtsAudioFormat.mp3), expectedMs(30));
    });

    test('ID3v2 tag is skipped', () {
      // 300 字节标签体，syncsafe 大小
      const int tagSize = 300;
      final Uint8List header = Uint8List.fromList(<int>[
        ...'ID3'.codeUnits,
        4, 0, 0, //
        (tagSize >> 21) & 0x7F,
        (tagSize >> 14) & 0x7F,
        (tagSize >> 7) & 0x7F,
        tagSize & 0x7F,
      ]);
      // 标签体里故意放一个伪帧头：若没跳过会被误计。
      final Uint8List body = Uint8List(tagSize)
        ..[0] = 0xFF
        ..[1] = 0xFB
        ..[2] = 0x90;
      final Uint8List bytes = Uint8List.fromList(<int>[
        ...header,
        ...body,
        ...buildMp3(frames: 20),
      ]);
      expect(sniffTtsAudioFormat(bytes), TtsAudioFormat.mp3);
      expect(probeTtsAudioDurationMs(bytes, TtsAudioFormat.mp3), expectedMs(20));
    });

    test('no frames → null', () {
      expect(
        probeTtsAudioDurationMs(Uint8List(1000), TtsAudioFormat.mp3),
        isNull,
      );
      expect(probeTtsAudioDurationMs(buildWav(), TtsAudioFormat.mp3), isNull);
    });
  });
}
