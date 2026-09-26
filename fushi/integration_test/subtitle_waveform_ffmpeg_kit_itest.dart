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
/// 在含逗号 / 分号 / 方括号 / 单引号 / 空格 / 中文的缓存子目录里造一段「偶数秒静音、
/// 奇数秒响」的音频（默认 6 分钟 = 1.8 万个 20ms 窗口；`WAVEFORM_ITEST_SECONDS` 可调，须为
/// 偶数），经 [extractAudioEnergyEnvelope] 抽包络：帧数必须拿满、首尾响静分得开。
///
/// `WAVEFORM_ITEST_LEGACY=true` 改跑旧通道（逐帧行打 stderr、经 `getOutput` 回传，且不拼
/// 大帧）作对照，只打印不断言，不与新通道同跑（互不污染平台通道）。
///
/// 只在 Android / iOS 有意义（桌面走 CLI 后端，另有单测覆盖），且必须是 **arm 设备**：
/// ffmpeg-kit 只带 arm 库，x86_64 模拟器靠 ARM 转译跑时**任何** ffmpeg-kit 命令（连
/// `-version`）都会在结束后被整条重跑、永不回调完成（实测 60 秒重跑 288 次，疑为转译层
/// 对 fftools `setjmp`/`longjmp` 退出路径的处理问题），在那里跑只会超时。真机直接：
///   flutter drive --driver=test_driver/integration_test.dart
///     --target=integration_test/subtitle_waveform_ffmpeg_kit_itest.dart -d <device>
const int _seconds =
    int.fromEnvironment('WAVEFORM_ITEST_SECONDS', defaultValue: 360);
const bool _legacy = bool.fromEnvironment('WAVEFORM_ITEST_LEGACY');

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

  testWidgets('ffmpeg-kit: waveform RMS arrives via the file channel',
      (WidgetTester tester) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    const int expectedFrames = _seconds * 1000 ~/ kSubtitleWaveformWindowMs;

    await tester.runAsync(() async {
      final Directory dir =
          Directory.systemTemp.createTempSync("waveform a b,c;[x]'q 字");
      try {
        final File wav = File('${dir.path}/in.wav')
          ..writeAsBytesSync(_alternatingWav(seconds: _seconds));
        setFfmpegBackendForTesting(const KitFfmpegBackend());
        final Stopwatch watch = Stopwatch()..start();

        if (_legacy) {
          // 旧实现：逐帧行打 stderr，最后一个滤镜后不拼大帧。
          final List<String> args = buildFfmpegPcmEnvelopeArgs(
            inputPath: wav.path,
            windowMs: kSubtitleWaveformWindowMs,
            limitSeconds: _seconds,
          );
          final int af = args.indexOf('-af');
          args[af + 1] = args[af + 1]
              .substring(0, args[af + 1].lastIndexOf(',asetnsamples='));
          final FfmpegRunResult legacy = await resolveFfmpegBackend()
              .run(args, const Duration(minutes: 5));
          debugPrint('[waveform-itest] legacy expected=$expectedFrames '
              'got=${parseAudioRmsEnvelopeFromFfmpegLog(legacy.output).length} '
              'rc=${legacy.returnCode} ${watch.elapsedMilliseconds}ms');
          return;
        }

        final List<double> env = await extractAudioEnergyEnvelope(
          videoPath: wav.path,
          windowMs: kSubtitleWaveformWindowMs,
        );
        debugPrint('[waveform-itest] file expected=$expectedFrames '
            'got=${env.length} ${watch.elapsedMilliseconds}ms');

        expect(env.length,
            inInclusiveRange(expectedFrames - 10, expectedFrames + 1));
        // 第 0 秒静音、第 1 秒响：各取该秒中段 30 帧的峰值。
        final double quiet = env.sublist(10, 40).reduce(math.max);
        final double loud = env.sublist(60, 90).reduce(math.max);
        expect(loud, greaterThan(-20.0));
        expect(quiet, lessThan(-60.0));
        // 最后一秒（奇数秒 = 响）也要拿到，证明没有被截断在中途。
        final double tail = env.sublist(env.length - 30).reduce(math.max);
        expect(tail, greaterThan(-20.0));
        debugPrint('[waveform-itest] PASS');
      } finally {
        setFfmpegBackendForTesting(null);
        dir.deleteSync(recursive: true);
      }
    });
  });
}
