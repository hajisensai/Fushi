import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_waveform.dart';

/// galgame 一键制卡波形数据桥（docs/specs/galgame-mining）：PCM -> 逐窗 RMS dBFS。
void main() {
  // 每窗 20ms @ 48k = 960 帧/窗。造 2 窗：一窗满幅、一窗静音。
  const int sampleRate = 48000;
  const int windowMs = kGalWaveformWindowMs; // 20
  const int framesPerWindow = sampleRate * windowMs ~/ 1000; // 960

  group('pcmToEnergyEnvelope int16 单声道', () {
    const fmt = PcmFormat(
      sampleRate: sampleRate,
      channels: 1,
      bitsPerSample: 16,
      isFloat: false,
    );

    test('响窗 dB 明显高于静音窗，且都 <=0', () {
      const int totalFrames = framesPerWindow * 2;
      final bytes = Uint8List(totalFrames * 2); // 单声道 16-bit
      final bd = ByteData.sublistView(bytes);
      // 窗0：满幅方波（±32767）；窗1：全零静音。
      for (int f = 0; f < framesPerWindow; f++) {
        bd.setInt16(f * 2, f.isEven ? 32767 : -32767, Endian.little);
      }
      final env = pcmToEnergyEnvelope(bytes, fmt, windowMs: windowMs);
      expect(env.length, 2);
      // 满幅 RMS≈1 -> dB≈0；静音 -> 地板 -120。
      expect(env[0], greaterThan(-1.0));
      expect(env[0], lessThanOrEqualTo(0.0));
      expect(env[1], lessThan(-100.0));
      expect(env[0], greaterThan(env[1]));
    });

    test('空 PCM -> 空包络', () {
      expect(pcmToEnergyEnvelope(Uint8List(0), fmt), isEmpty);
    });
  });

  group('pcmToEnergyEnvelope float32 立体声', () {
    const fmt = PcmFormat(
      sampleRate: sampleRate,
      channels: 2,
      bitsPerSample: 32,
      isFloat: true,
    );

    test('半幅正弦 -> dB 约 -9dB 附近（<0 且远高于静音）', () {
      const int totalFrames = framesPerWindow;
      final bytes = Uint8List(totalFrames * 2 * 4); // 立体声 float32
      final bd = ByteData.sublistView(bytes);
      for (int f = 0; f < totalFrames; f++) {
        final double v = 0.5 * math.sin(2 * math.pi * f / 64);
        bd.setFloat32(f * 8, v, Endian.little); // L
        bd.setFloat32(f * 8 + 4, v, Endian.little); // R
      }
      final env = pcmToEnergyEnvelope(bytes, fmt, windowMs: windowMs);
      expect(env.length, 1);
      // 0.5 幅正弦 RMS≈0.354 -> ~-9dB。给宽容区间避免死板。
      expect(env[0], inInclusiveRange(-15.0, -3.0));
    });
  });

  group('退化格式', () {
    test('不支持位深（如 24-bit）-> 空包络（不崩不乱画）', () {
      const fmt = PcmFormat(
        sampleRate: sampleRate,
        channels: 2,
        bitsPerSample: 24,
        isFloat: false,
      );
      final bytes = Uint8List(framesPerWindow * 2 * 3);
      expect(pcmToEnergyEnvelope(bytes, fmt), isEmpty);
    });
  });
}
