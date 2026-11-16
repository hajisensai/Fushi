import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_clip.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:fushi/src/mining/galgame_waveform_select.dart'
    show GalWaveformRange;

/// 跨应用语音挖掘（拍板 oqk37s3QFL）：查词快照里截「查词前最后一句」并编码成句子音频。
const PcmFormat _format = PcmFormat(
  sampleRate: 8000,
  channels: 1,
  bitsPerSample: 16,
  isFloat: false,
);

/// 按 [segments]（起止毫秒 + 振幅）拼一段 16-bit 单声道 PCM，其余位置是很轻的底噪。
Uint8List _pcm(int totalMs, List<({int startMs, int endMs, double amp})> segs) {
  final int frames = _format.sampleRate * totalMs ~/ 1000;
  final ByteData data = ByteData(frames * 2);
  for (int i = 0; i < frames; i++) {
    final int ms = i * 1000 ~/ _format.sampleRate;
    double amp = 0.001;
    for (final ({int startMs, int endMs, double amp}) s in segs) {
      if (ms >= s.startMs && ms < s.endMs) amp = s.amp;
    }
    final double v = amp * math.sin(2 * math.pi * 440 * i / _format.sampleRate);
    data.setInt16(i * 2, (v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  group('crossAppAudioDefaultRange', () {
    test('picks the last utterance, merging short pauses, with padding', () {
      final Uint8List pcm = _pcm(8000, <({int startMs, int endMs, double amp})>[
        // 上一句（更早、隔着长静音）——不该被截进来。
        (startMs: 2000, endMs: 3000, amp: 0.5),
        // 最后一句：中间 300ms 换气（< kCrossAppAudioMaxGapMs）要并成一句。
        (startMs: 5000, endMs: 5500, amp: 0.5),
        (startMs: 5800, endMs: 6500, amp: 0.4),
      ]);
      final GalWaveformRange range = crossAppAudioDefaultRange(
        GalAudioSlice(pcm: pcm, format: _format),
      );
      expect(range.startMs, 5000 - kCrossAppAudioPadMs);
      expect(range.endMs, 6500 + kCrossAppAudioPadMs);
    });

    test('a pause longer than the gap limit splits the utterances', () {
      final Uint8List pcm = _pcm(6000, <({int startMs, int endMs, double amp})>[
        (startMs: 1000, endMs: 2000, amp: 0.5),
        (startMs: 3000, endMs: 4000, amp: 0.5),
      ]);
      final GalWaveformRange range = crossAppAudioDefaultRange(
        GalAudioSlice(pcm: pcm, format: _format),
      );
      expect(range.startMs, 3000 - kCrossAppAudioPadMs);
      expect(range.endMs, 4000 + kCrossAppAudioPadMs);
    });

    test('silence (game blocked capture) falls back to the whole snapshot', () {
      final Uint8List pcm = Uint8List(_format.byteRate * 3);
      final GalWaveformRange range = crossAppAudioDefaultRange(
        GalAudioSlice(pcm: pcm, format: _format),
      );
      expect(range.startMs, 0);
      expect(range.endMs, 3000);
    });

    test('padding is clamped to the snapshot bounds', () {
      final Uint8List pcm = _pcm(2000, <({int startMs, int endMs, double amp})>[
        (startMs: 0, endMs: 2000, amp: 0.5),
      ]);
      final GalWaveformRange range = crossAppAudioDefaultRange(
        GalAudioSlice(pcm: pcm, format: _format),
      );
      expect(range.startMs, 0);
      expect(range.endMs, 2000);
    });
  });

  group('CrossAppAudioSnapshot.fromNative', () {
    test('parses the native snapshot reply', () {
      final CrossAppAudioSnapshot? s =
          CrossAppAudioSnapshot.fromNative(<Object?, Object?>{
            'path': '/cache/cross_app_audio/lookup_1.pcm',
            'sampleRate': 48000,
            'channels': 1,
            'bitsPerSample': 16,
            'isFloat': false,
          });
      expect(s, isNotNull);
      expect(s!.pcmPath, '/cache/cross_app_audio/lookup_1.pcm');
      expect(s.format.sampleRate, 48000);
      expect(s.format.channels, 1);
      expect(s.format.bitsPerSample, 16);
      expect(s.format.isFloat, isFalse);
    });

    test('rejects a reply without a path or format', () {
      expect(CrossAppAudioSnapshot.fromNative(null), isNull);
      expect(
        CrossAppAudioSnapshot.fromNative(<Object?, Object?>{
          'sampleRate': 48000,
          'channels': 1,
          'bitsPerSample': 16,
          'isFloat': false,
        }),
        isNull,
      );
      expect(
        CrossAppAudioSnapshot.fromNative(<Object?, Object?>{'path': '/x.pcm'}),
        isNull,
      );
    });
  });

  group('prepareCrossAppSentenceAudio', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cross_app_audio_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<CrossAppAudioSnapshot> writeSnapshot(Uint8List pcm) async {
      final File f = File('${tmp.path}/lookup.pcm');
      await f.writeAsBytes(pcm);
      return CrossAppAudioSnapshot(pcmPath: f.path, format: _format);
    }

    test('encodes only the last utterance and returns the file', () async {
      final CrossAppAudioSnapshot snapshot = await writeSnapshot(
        _pcm(8000, <({int startMs, int endMs, double amp})>[
          (startMs: 2000, endMs: 3000, amp: 0.5),
          (startMs: 5000, endMs: 6000, amp: 0.5),
        ]),
      );
      GalAudioSlice? encoded;
      final ({String path, Directory dir})? out =
          await prepareCrossAppSentenceAudio(
            snapshot,
            encode: (GalAudioSlice clip, String outputPath) async {
              encoded = clip;
              await File(outputPath).writeAsBytes(<int>[1, 2, 3]);
              return true;
            },
          );
      expect(out, isNotNull);
      expect(out!.path, endsWith('sentence.m4a'));
      expect(await File(out.path).exists(), isTrue);
      final int clipMs = encoded!.pcm.length * 1000 ~/ _format.byteRate;
      expect(clipMs, 1000 + 2 * kCrossAppAudioPadMs);
      await deleteCrossAppAudioDir(out.dir);
      expect(await out.dir.exists(), isFalse);
    });

    test('an explicit range overrides the detected one', () async {
      final CrossAppAudioSnapshot snapshot = await writeSnapshot(
        _pcm(4000, const <({int startMs, int endMs, double amp})>[]),
      );
      GalAudioSlice? encoded;
      final ({String path, Directory dir})? out =
          await prepareCrossAppSentenceAudio(
            snapshot,
            range: const GalWaveformRange(startMs: 1000, endMs: 1500),
            encode: (GalAudioSlice clip, String outputPath) async {
              encoded = clip;
              await File(outputPath).writeAsBytes(<int>[1]);
              return true;
            },
          );
      expect(out, isNotNull);
      expect(encoded!.pcm.length, _format.byteRate ~/ 2);
      await deleteCrossAppAudioDir(out!.dir);
    });

    test('a failed encode yields no audio and leaves no temp dir', () async {
      final CrossAppAudioSnapshot snapshot = await writeSnapshot(
        _pcm(3000, <({int startMs, int endMs, double amp})>[
          (startMs: 1000, endMs: 2000, amp: 0.5),
        ]),
      );
      String? attempted;
      final ({String path, Directory dir})? out =
          await prepareCrossAppSentenceAudio(
            snapshot,
            encode: (GalAudioSlice clip, String outputPath) async {
              attempted = outputPath;
              return false;
            },
          );
      expect(out, isNull);
      expect(attempted, isNotNull);
      expect(await File(attempted!).parent.exists(), isFalse);
    });

    test(
      'a snapshot already pruned by later lookups yields no audio',
      () async {
        final ({String path, Directory dir})? out =
            await prepareCrossAppSentenceAudio(
              CrossAppAudioSnapshot(
                pcmPath: '${tmp.path}/gone.pcm',
                format: _format,
              ),
              encode: (GalAudioSlice clip, String outputPath) async =>
                  fail('must not encode without a snapshot'),
            );
        expect(out, isNull);
      },
    );
  });
}
