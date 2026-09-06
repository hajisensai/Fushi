import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_fbank.dart';

/// 真实语音 wav（edge-tts `ja-JP-NanamiNeural`「今日はいい天気ですね。」，ffmpeg 转
/// 16 kHz 单声道 s16）的 fbank 与 kaldi-native-fbank 黄金特征逐值对拍。
/// 黄金数据由 `fixtures/gen_fbank_golden.py` 生成；sherpa-onnx 对同一 wav 的贪心
/// 转录为「今日はいい天気ですね」（timestamps 0.0/0.16/0.32/0.56/0.64/1.0/1.16/
/// 1.36/1.48/1.72 s），供真 app 内对拍。
void main() {
  test('AsrFbank 对真实日语 wav 与 knf 逐值一致（|diff| < 1e-3）', () {
    final Float32List samples = readPcm16MonoWav(
      File('test/asr/fixtures/ja_tts_16k.wav'),
    );
    final Map<String, Object?> golden = jsonDecode(
      File('test/asr/fixtures/fbank_golden_ja.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(samples.length, golden['num_samples']);

    final int frames = golden['frames']! as int;
    final List<double> expected = (golden['features']! as List<Object?>)
        .map((Object? v) => (v as num).toDouble())
        .toList();
    final Float32List actual = const AsrFbank().compute(samples);

    expect(AsrFbank.frameCount(samples.length), frames);
    expect(actual.length, expected.length);
    double maxDiff = 0;
    int worst = -1;
    for (int i = 0; i < expected.length; i++) {
      final double d = (actual[i] - expected[i]).abs();
      if (d > maxDiff) {
        maxDiff = d;
        worst = i;
      }
    }
    expect(
      maxDiff,
      lessThan(1e-3),
      reason: '最大偏差 $maxDiff 在帧 ${worst ~/ 80} bin ${worst % 80}：'
          'dart=${actual[worst]} knf=${expected[worst]}',
    );
  });
}

/// 读取 RIFF/WAVE PCM16 单声道 16 kHz，归一化到 [-1, 1]（与 soundfile
/// `dtype="float32"` 的 `/32768` 一致）。
Float32List readPcm16MonoWav(File file) {
  final Uint8List bytes = file.readAsBytesSync();
  final ByteData view = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
  int offset = 12;
  int? dataStart;
  int? dataLength;
  while (offset + 8 <= bytes.length) {
    final String id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final int size = view.getUint32(offset + 4, Endian.little);
    final int body = offset + 8;
    if (id == 'fmt ') {
      expect(view.getUint16(body, Endian.little), 1, reason: 'PCM');
      expect(view.getUint16(body + 2, Endian.little), 1, reason: '单声道');
      expect(view.getUint32(body + 4, Endian.little), 16000);
      expect(view.getUint16(body + 14, Endian.little), 16, reason: '16 bit');
    } else if (id == 'data') {
      dataStart = body;
      dataLength = size;
      break;
    }
    offset = body + size + (size & 1);
  }
  if (dataStart == null || dataLength == null) {
    throw StateError('wav 缺少 data chunk');
  }
  final int n = dataLength ~/ 2;
  final Float32List out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = view.getInt16(dataStart + i * 2, Endian.little) / 32768.0;
  }
  return out;
}
