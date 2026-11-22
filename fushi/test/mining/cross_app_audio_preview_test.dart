import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_clip.dart';
import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_preview.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:fushi/src/mining/galgame_waveform_select.dart'
    show GalWaveformRange;

/// 跨应用语音缓存 · 制卡前试听 + 调起止（拍板 design-cross-app-audio-trim-ui）：
/// 查词卡「调整句子音频」面板的数据（波形 + 默认区间 + 试听 WAV）与制卡时按面板拖出的
/// 偏移截句。
const PcmFormat _stereo48k = PcmFormat(
  sampleRate: 48000,
  channels: 2,
  bitsPerSample: 16,
  isFloat: false,
);

const PcmFormat _mono8k = PcmFormat(
  sampleRate: 8000,
  channels: 1,
  bitsPerSample: 16,
  isFloat: false,
);

/// [voice] 段里是 0.5 振幅的 440 Hz，其余是很轻的底噪。
Uint8List _pcm(
  PcmFormat format,
  int totalMs,
  List<({int startMs, int endMs})> voice,
) {
  final int frames = format.sampleRate * totalMs ~/ 1000;
  final ByteData data = ByteData(frames * format.blockAlign);
  for (int i = 0; i < frames; i++) {
    final int ms = i * 1000 ~/ format.sampleRate;
    double amp = 0.001;
    for (final ({int startMs, int endMs}) s in voice) {
      if (ms >= s.startMs && ms < s.endMs) amp = 0.5;
    }
    final double v = amp * math.sin(2 * math.pi * 440 * i / format.sampleRate);
    for (int c = 0; c < format.channels; c++) {
      data.setInt16(
        i * format.blockAlign + c * 2,
        (v * 32767).round(),
        Endian.little,
      );
    }
  }
  return data.buffer.asUint8List();
}

void main() {
  group('crossAppAudioAdjustRange', () {
    const GalWaveformRange base = GalWaveformRange(startMs: 2000, endMs: 3000);

    test('adds the panel offsets to the auto-detected clip', () {
      final GalWaveformRange? r = crossAppAudioAdjustRange(
        base,
        totalMs: 10000,
        startDeltaMs: -500,
        endDeltaMs: 250,
      );
      expect(r!.startMs, 1500);
      expect(r.endMs, 3250);
    });

    test('clamps into the snapshot', () {
      final GalWaveformRange? r = crossAppAudioAdjustRange(
        base,
        totalMs: 4000,
        startDeltaMs: -9000,
        endDeltaMs: 9000,
      );
      expect(r!.startMs, 0);
      expect(r.endMs, 4000);
    });

    test('a range shorter than the minimum yields no audio', () {
      expect(
        crossAppAudioAdjustRange(
          base,
          totalMs: 10000,
          startDeltaMs: 950,
          endDeltaMs: 0,
        ),
        isNull,
      );
      expect(
        crossAppAudioAdjustRange(
          base,
          totalMs: 10000,
          startDeltaMs: 1500,
          endDeltaMs: 0,
        ),
        isNull,
        reason: 'start dragged past end must not invert into a clip',
      );
    });
  });

  group('buildCrossAppAudioPreview', () {
    test('waveform, default range and a 16 kHz mono WAV', () {
      final GalAudioSlice slice = GalAudioSlice(
        pcm: _pcm(_stereo48k, 6000, const <({int startMs, int endMs})>[
          (startMs: 3000, endMs: 4000),
        ]),
        format: _stereo48k,
      );
      final CrossAppAudioPreview? preview = buildCrossAppAudioPreview(slice);
      expect(preview, isNotNull);
      expect(preview!.totalMs, 6000);
      // 与制卡同一个判据：面板的偏移才能落在同一段上。
      final GalWaveformRange detected = crossAppAudioDefaultRange(slice)!;
      expect(preview.defaultRange.startMs, detected.startMs);
      expect(preview.defaultRange.endMs, detected.endMs);

      expect(preview.peaks.length, lessThanOrEqualTo(480));
      expect(preview.peaks, everyElement(inInclusiveRange(0.0, 1.0)));
      final int voiceIndex = 3500 * preview.peaks.length ~/ 6000;
      final int quietIndex = 1000 * preview.peaks.length ~/ 6000;
      expect(preview.peaks[voiceIndex], greaterThan(preview.peaks[quietIndex]));

      final ByteData wav = ByteData.sublistView(preview.wav);
      expect(ascii.decode(preview.wav.sublist(0, 4)), 'RIFF');
      expect(wav.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(wav.getUint32(24, Endian.little), 16000);
      expect(wav.getUint16(34, Endian.little), 16);
      // 6 秒 × 16000 Hz × 2 字节 + 44 字节头。
      expect(preview.wav.length, 44 + 6 * 16000 * 2);
    });

    test('bridge JSON carries a playable data URL and the minimum clip', () {
      final CrossAppAudioPreview preview = buildCrossAppAudioPreview(
        GalAudioSlice(
          pcm: _pcm(_mono8k, 3000, const <({int startMs, int endMs})>[
            (startMs: 1000, endMs: 2000),
          ]),
          format: _mono8k,
        ),
      )!;
      final Map<String, Object?> json = preview.toBridgeJson();
      expect(json['totalMs'], 3000);
      expect(json['startMs'], preview.defaultRange.startMs);
      expect(json['endMs'], preview.defaultRange.endMs);
      expect(json['minClipMs'], kCrossAppAudioMinClipMs);
      expect(json['audio'], startsWith('data:audio/wav;base64,UklGR'));
      // 8 kHz 已低于目标采样率：原样保留，不升采样。
      expect(
        ByteData.sublistView(preview.wav).getUint32(24, Endian.little),
        8000,
      );
    });

    test('silence and unknown sample formats give no preview', () {
      expect(
        buildCrossAppAudioPreview(
          GalAudioSlice(pcm: Uint8List(8000 * 2 * 2), format: _mono8k),
        ),
        isNull,
      );
      expect(
        buildCrossAppAudioPreview(
          GalAudioSlice(
            pcm: Uint8List(8000 * 3),
            format: const PcmFormat(
              sampleRate: 8000,
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

  group('bridges and mining with panel offsets', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cross_app_preview_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<CrossAppAudioSnapshot> writeSnapshot(Uint8List pcm) async {
      final File f = File('${tmp.path}/lookup.pcm');
      await f.writeAsBytes(pcm);
      return CrossAppAudioFileSnapshot(pcmPath: f.path, format: _mono8k);
    }

    test('available / preview replies follow the snapshot', () async {
      expect(await crossAppAudioAvailableReply(null), isFalse);
      expect(
        await crossAppAudioAvailableReply(
          Future<CrossAppAudioSnapshot?>.value(),
        ),
        isFalse,
      );
      expect(await crossAppAudioPreviewReply(null), isNull);

      final Future<CrossAppAudioSnapshot?> snapshot =
          Future<CrossAppAudioSnapshot?>.value(
            await writeSnapshot(
              _pcm(_mono8k, 4000, const <({int startMs, int endMs})>[
                (startMs: 1000, endMs: 2000),
              ]),
            ),
          );
      expect(await crossAppAudioAvailableReply(snapshot), isTrue);
      final Map<String, Object?>? reply = await crossAppAudioPreviewReply(
        snapshot,
      );
      expect(reply, isNotNull);
      expect(reply!['totalMs'], 4000);
      // 关了面板再打开：同一份快照不重读、不重算。
      expect(
        identical(await crossAppAudioPreviewReply(snapshot), reply),
        isTrue,
      );
      // 文件型快照是原生的缓存文件：试听只读，绝不能删掉它（制卡还要用）。
      expect(await File('${tmp.path}/lookup.pcm').exists(), isTrue);
    });

    test('mining applies the offsets the panel produced', () async {
      final CrossAppAudioSnapshot snapshot = await writeSnapshot(
        _pcm(_mono8k, 8000, const <({int startMs, int endMs})>[
          (startMs: 5000, endMs: 6000),
        ]),
      );
      GalAudioSlice? encoded;
      final ({String path, Directory dir})? out =
          await prepareCrossAppSentenceAudio(
            snapshot,
            startDeltaMs: -1000,
            endDeltaMs: -200,
            encode: (GalAudioSlice clip, String outputPath) async {
              encoded = clip;
              await File(outputPath).writeAsBytes(<int>[1]);
              return true;
            },
          );
      expect(out, isNotNull);
      final int clipMs = encoded!.pcm.length * 1000 ~/ _mono8k.byteRate;
      // 默认 = 1000 ms 语音 + 前后各 kCrossAppAudioPadMs；起点提前 1 s、终点收回 0.2 s。
      expect(clipMs, 1000 + 2 * kCrossAppAudioPadMs + 1000 - 200);
      await deleteCrossAppAudioDir(out!.dir);
    });

    test('offsets that collapse the clip mine no audio', () async {
      final CrossAppAudioSnapshot snapshot = await writeSnapshot(
        _pcm(_mono8k, 4000, const <({int startMs, int endMs})>[
          (startMs: 1000, endMs: 2000),
        ]),
      );
      bool encoded = false;
      final ({String path, Directory dir})? out =
          await prepareCrossAppSentenceAudio(
            snapshot,
            startDeltaMs: 5000,
            encode: (GalAudioSlice clip, String outputPath) async {
              encoded = true;
              return true;
            },
          );
      expect(out, isNull);
      expect(encoded, isFalse);
    });
  });
}
