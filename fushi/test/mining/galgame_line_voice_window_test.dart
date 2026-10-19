import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_line_voice_window.dart';
import 'package:fushi/src/mining/galgame_window_video.dart';

/// 长句 gal 语音被截断（用户反馈：句子长的卡音频被截、短的完整；卡上片段显示十几秒，
/// 音频几秒就结束）的纯函数层守卫。
void main() {
  const PcmFormat kMono16 = PcmFormat(
    sampleRate: 16000,
    channels: 1,
    bitsPerSample: 16,
    isFloat: false,
  );
  const PcmFormat kStereoFloat = PcmFormat(
    sampleRate: 48000,
    channels: 2,
    bitsPerSample: 32,
    isFloat: true,
  );

  /// [segments]：(毫秒, 幅度 0..1) 依次拼接的正弦段。
  GalAudioSlice synth(PcmFormat format, List<(int, double)> segments) {
    final BytesBuilder out = BytesBuilder();
    int n = 0;
    for (final (int ms, double amp) in segments) {
      final int frames = format.sampleRate * ms ~/ 1000;
      final ByteData data = ByteData(frames * format.blockAlign);
      for (int f = 0; f < frames; f++, n++) {
        final double v =
            amp * math.sin(2 * math.pi * 220 * n / format.sampleRate);
        for (int c = 0; c < format.channels; c++) {
          final int offset =
              f * format.blockAlign + c * (format.bitsPerSample ~/ 8);
          if (format.isFloat) {
            data.setFloat32(offset, v, Endian.little);
          } else {
            data.setInt16(offset, (v * 32767).round(), Endian.little);
          }
        }
      }
      out.add(data.buffer.asUint8List());
    }
    return GalAudioSlice(pcm: out.toBytes(), format: format);
  }

  int durationMs(GalAudioSlice s) => s.pcm.length * 1000 ~/ s.format.byteRate;

  test('一句的窗口上限覆盖长独白，且与 native kUtteranceMaxForwardMs 同值', () {
    expect(
      kGalLineVoiceMaxMs,
      greaterThanOrEqualTo(20000),
      reason: '旧的 5s / 6s 封顶正是长句被截的根因',
    );
    expect(
      kGalLineVoiceMaxMs,
      lessThanOrEqualTo(60000),
      reason: '不能超过 loopback 环容量（native kRingSeconds = 60）',
    );
  });

  test('dropPcmTailMs 按帧对齐切掉尾部，<=0 原样返回', () {
    final GalAudioSlice slice = synth(kStereoFloat, <(int, double)>[
      (1000, 0.5),
    ]);
    expect(identical(dropPcmTailMs(slice, 0), slice), isTrue);
    final GalAudioSlice cut = dropPcmTailMs(slice, 250);
    expect(durationMs(cut), 750);
    expect(cut.pcm.length % kStereoFloat.blockAlign, 0);
    expect(dropPcmTailMs(slice, 5000).pcm, isEmpty);
  });

  test('语音后跟长段底噪：裁到最后一个有声帧 + 余量', () {
    final GalAudioSlice slice = synth(kMono16, <(int, double)>[
      (800, 0.01), // 预卷：BGM 底噪
      (4000, 0.4), // 人声
      (6000, 0.01), // 玩家停在这句上，尾巴全是底噪
    ]);
    final GalAudioSlice trimmed = trimLoopbackTrailingFloor(slice);
    final int ms = durationMs(trimmed);
    expect(ms, greaterThanOrEqualTo(4800), reason: '人声一个字都不能少');
    expect(
      ms,
      lessThanOrEqualTo(4800 + kGalVoiceTailPadMs + kGalVoiceTailFrameMs),
    );
  });

  test('float32 混音同样生效', () {
    final GalAudioSlice slice = synth(kStereoFloat, <(int, double)>[
      (3000, 0.3),
      (5000, 0.02),
    ]);
    final int ms = durationMs(trimLoopbackTrailingFloor(slice));
    expect(
      ms,
      inInclusiveRange(3000, 3000 + kGalVoiceTailPadMs + kGalVoiceTailFrameMs),
    );
  });

  test('末尾低能量短于门限（句中停顿 / 话没说完）不裁', () {
    final GalAudioSlice slice = synth(kMono16, <(int, double)>[
      (3000, 0.4),
      (kGalVoiceTailMinQuietMs - 300, 0.01),
    ]);
    expect(identical(trimLoopbackTrailingFloor(slice), slice), isTrue);
  });

  test('人声一直响到窗口末尾（卡上那句被截的形状）不裁', () {
    final GalAudioSlice slice = synth(kMono16, <(int, double)>[
      (750, 0.01),
      (4300, 0.4),
    ]);
    expect(identical(trimLoopbackTrailingFloor(slice), slice), isTrue);
  });

  test('BGM 始终盖过人声、分不出底噪时不裁', () {
    final GalAudioSlice slice = synth(kMono16, <(int, double)>[(9000, 0.3)]);
    expect(identical(trimLoopbackTrailingFloor(slice), slice), isTrue);
  });

  test('视频片段终点跟随音频：在一句上停 20s 再制卡，片段不再拖成 20s 静帧', () {
    expect(
      galWindowVideoEndTick(
        fromTickMs: 1000,
        toTickMs: 21000,
        audioDurationMs: 5040,
      ),
      1000 + 5040 + kGalWindowVideoFallbackTailMs,
    );
    expect(
      galWindowVideoEndTick(
        fromTickMs: 1000,
        toTickMs: 4000,
        audioDurationMs: 9000,
      ),
      4000,
      reason: '下一句先到时仍以下一句为界，音频更长由最后一帧拉长覆盖',
    );
    expect(
      galWindowVideoEndTick(
        fromTickMs: 1000,
        toTickMs: 21000,
        audioDurationMs: null,
      ),
      21000,
    );
  });
}
