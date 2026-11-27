import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_loopback_voice_detector.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;

/// 按样本位置给概率的替身打分器：[speech] 内的 512 样本窗口判语音。
class _RangeScorer implements asr.AsrVadScorer {
  _RangeScorer(this.speech);

  final List<(int startMs, int endMs)> speech;
  int _window = 0;

  @override
  Future<Float64List> score(List<Float32List> windows) async {
    final Float64List out = Float64List(windows.length);
    for (int i = 0; i < windows.length; i++) {
      final int ms =
          _window * asr.kAsrVadWindowSamples * 1000 ~/ asr.kAsrSampleRate;
      out[i] = speech.any(((int, int) r) => ms >= r.$1 && ms < r.$2)
          ? 0.9
          : 0.05;
      _window++;
    }
    return out;
  }

  @override
  void reset() => _window = 0;
}

Float32List _pcm16k(int ms) => Float32List(ms * asr.kAsrSampleRate ~/ 1000);

void main() {
  group('galSliceToVadPcm', () {
    test('48 kHz 立体声 int16 → 16 kHz 单声道，取声道与区间平均', () {
      final ByteData data = ByteData(48000 * 4); // 1 s
      for (int f = 0; f < 48000; f++) {
        data.setInt16(f * 4, 16384, Endian.little); // 左 0.5
        data.setInt16(f * 4 + 2, 0, Endian.little); // 右 0
      }
      final Float32List? out = galSliceToVadPcm(
        GalAudioSlice(
          pcm: data.buffer.asUint8List(),
          format: const PcmFormat(
            sampleRate: 48000,
            channels: 2,
            bitsPerSample: 16,
            isFloat: false,
          ),
        ),
      );
      expect(out, isNotNull);
      expect(out!.length, 16000);
      expect(out.every((double v) => (v - 0.25).abs() < 1e-6), isTrue);
    });

    test('44.1 kHz float32 也能转，长度按比例', () {
      final ByteData data = ByteData(44100 * 4);
      final Float32List? out = galSliceToVadPcm(
        GalAudioSlice(
          pcm: data.buffer.asUint8List(),
          format: const PcmFormat(
            sampleRate: 44100,
            channels: 1,
            bitsPerSample: 32,
            isFloat: true,
          ),
        ),
      );
      expect(out!.length, 16000);
    });

    test('不认识的位深判不出', () {
      expect(
        galSliceToVadPcm(
          GalAudioSlice(
            pcm: Uint8List(300),
            format: const PcmFormat(
              sampleRate: 48000,
              channels: 1,
              bitsPerSample: 24,
              isFloat: false,
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('galVadFindsLineSpeech', () {
    test('全程只有 BGM（无语音窗口）→ 无人声', () async {
      expect(
        await galVadFindsLineSpeech(
          scorer: _RangeScorer(const <(int, int)>[]),
          pcm16k: _pcm16k(5000),
          leadInMs: 1000,
        ),
        isFalse,
      );
    });

    test('预卷里的上一句尾巴不算本句配音', () async {
      expect(
        await galVadFindsLineSpeech(
          scorer: _RangeScorer(const <(int, int)>[(0, 700)]),
          pcm16k: _pcm16k(5000),
          leadInMs: 1000,
        ),
        isFalse,
      );
    });

    test('预卷之后有人声 → 有配音；跨过预卷的提前语音也算', () async {
      expect(
        await galVadFindsLineSpeech(
          scorer: _RangeScorer(const <(int, int)>[(1500, 3500)]),
          pcm16k: _pcm16k(5000),
          leadInMs: 1000,
        ),
        isTrue,
      );
      expect(
        await galVadFindsLineSpeech(
          scorer: _RangeScorer(const <(int, int)>[(600, 2500)]),
          pcm16k: _pcm16k(5000),
          leadInMs: 1000,
        ),
        isTrue,
      );
    });
  });

  test('打分器拿不到（ONNX 不可用）→ 判不出', () async {
    final VadGalLoopbackVoiceDetector detector = VadGalLoopbackVoiceDetector(
      scorerFactory: () async => null,
    );
    expect(
      await detector.hasSpeech(
        GalAudioSlice(
          pcm: Uint8List(4000),
          format: const PcmFormat(
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16,
            isFloat: false,
          ),
        ),
        leadInMs: 0,
      ),
      isNull,
    );
  });
}
