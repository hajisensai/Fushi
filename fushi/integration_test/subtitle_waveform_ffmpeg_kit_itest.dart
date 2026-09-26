import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/audio_energy_probe.dart';
import 'package:fushi/src/media/video/ffmpeg_kit_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:integration_test/integration_test.dart';

/// 设备验证：字幕波形对轴的逐帧 RMS 在移动端（进程内 ffmpeg-kit）真能拿到。
///
/// 按真实规模造 20 分钟音频（= [kSubtitleAutoAlignProbeLimitMs]，20ms 窗口约 6 万帧），
/// 在含逗号 / 分号 / 方括号 / 单引号 / 空格 / 中文的缓存子目录里跑：
/// - 旧通道（逐帧行打 stderr、经 `getOutput` 回传）只打印拿到了多少帧，作对照证据；
/// - 新通道（[extractAudioEnergyEnvelope]，`ametadata` 写 `file=`）必须拿满且响/静分得开。
///
/// 只在 Android / iOS 有意义（桌面走 CLI 后端，另有单测覆盖）：
/// flutter drive --driver=test_driver/integration_test.dart
///   --target=integration_test/subtitle_waveform_ffmpeg_kit_itest.dart -d <emulator>
Uint8List _alternatingWav({required int seconds}) {
  const int rate = 8000;
  final int total = seconds * rate;
  final ByteData b = ByteData(44 + total * 2);
  void ascii(int off, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + total * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, total * 2, Endian.little);
  // 奇数秒响（440Hz 半幅正弦）、偶数秒静音。
  for (int i = 0; i < total; i++) {
    final bool loud = (i ~/ rate).isOdd;
    final int v =
        loud ? (math.sin(2 * math.pi * 440 * i / rate) * 16383).round() : 0;
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ffmpeg-kit: waveform RMS arrives via file channel at full scale',
      (WidgetTester tester) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    const int seconds = kSubtitleAutoAlignProbeLimitMs ~/ 1000;
    const int expectedFrames = seconds * 1000 ~/ kSubtitleWaveformWindowMs;

    await tester.runAsync(() async {
      final Directory dir =
          Directory.systemTemp.createTempSync("waveform a b,c;[x]'q 字");
      try {
        final File wav = File('${dir.path}/in.wav')
          ..writeAsBytesSync(_alternatingWav(seconds: seconds));
        setFfmpegBackendForTesting(const KitFfmpegBackend());

        // 对照：旧通道（stderr / getOutput）。
        final Stopwatch legacyWatch = Stopwatch()..start();
        final FfmpegRunResult legacy = await resolveFfmpegBackend().run(
          buildFfmpegPcmEnvelopeArgs(
            inputPath: wav.path,
            windowMs: kSubtitleWaveformWindowMs,
            limitSeconds: seconds,
          ),
          const Duration(minutes: 5),
        );
        legacyWatch.stop();
        final int legacyFrames =
            parseAudioRmsEnvelopeFromFfmpegLog(legacy.output).length;

        // 新通道：file=。
        final Stopwatch fileWatch = Stopwatch()..start();
        final List<double> env = await extractAudioEnergyEnvelope(
          videoPath: wav.path,
          windowMs: kSubtitleWaveformWindowMs,
        );
        fileWatch.stop();

        debugPrint('[waveform-itest] expected=$expectedFrames '
            'legacy(stderr)=$legacyFrames rc=${legacy.returnCode} '
            '${legacyWatch.elapsedMilliseconds}ms | '
            'file=${env.length} ${fileWatch.elapsedMilliseconds}ms');

        expect(env.length,
            inInclusiveRange(expectedFrames - 10, expectedFrames + 1));
        // 第 0 秒静音、第 1 秒响：各取该秒中段 30 帧的峰值。
        final double quiet = env.sublist(10, 40).reduce(math.max);
        final double loud = env.sublist(60, 90).reduce(math.max);
        expect(loud, greaterThan(-20.0));
        expect(quiet, lessThan(-60.0));
        // 末尾那一秒（第 1199 秒，奇数 = 响）也要拿到，证明没有被截断在中途。
        final double tail = env.sublist(env.length - 30).reduce(math.max);
        expect(tail, greaterThan(-20.0));
      } finally {
        setFfmpegBackendForTesting(null);
        dir.deleteSync(recursive: true);
      }
    });
  });
}
