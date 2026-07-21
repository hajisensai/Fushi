// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/mining/galgame_audio_encode.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';
import 'package:hibiki/src/mining/window_capture_channel.dart';

/// 真机语音制卡验证（不启动游戏，只做系统 loopback 捕获）。
///
/// 外层脚本先把一个**真在播对白语音**的 galgame 驱动进对话；本测试在 ~[GALV_SECONDS] 秒内
/// 每 1.2s 抓一段 loopback，保留**峰值最大**（最像语音）的那段，再截目标游戏窗口，dump
/// WAV+PNG+meta 到 GALV_OUT。外层再经 AnkiConnect 推卡。
///
/// 不初始化 AppModel / 不开 Drift DB（只 pump 平凡 widget 让 runner 起 native 通道），绝不碰生产库。
///
/// 环境变量：
///   - GALV_WINDOW_MATCH：目标游戏窗口标题子串（截图用；缺则截第一个有标题窗口）。
///   - GALV_OUT：dump 目录（缺省 systemTemp）。
///   - GALV_SECONDS：捕获轮询总秒数（缺省 50）。
///   - GALV_NAME：媒体文件 basename（缺省 galvoiced）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loopback 捕获最响一段对白语音并 dump', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 200));

    final Map<String, String> env = Platform.environment;
    final String outDir = env['GALV_OUT'] ?? Directory.systemTemp.path;
    final String match = env['GALV_WINDOW_MATCH'] ?? '';
    final int seconds = int.tryParse(env['GALV_SECONDS'] ?? '') ?? 50;
    final String name = env['GALV_NAME'] ?? 'galvoiced';
    Directory(outDir).createSync(recursive: true);

    final LoopbackGalAudioSource loopback = LoopbackGalAudioSource();
    final PcmFormat? fmt = await loopback.start();
    if (fmt == null) {
      print('GALV SKIP: loopback 无法启动（非 Windows / native 缺失）');
      return;
    }
    print(
        'GALV START fmt=${fmt.sampleRate}/${fmt.channels}/${fmt.bitsPerSample} '
        'float=${fmt.isFloat} seconds=$seconds match="$match"');

    Uint8List? bestPcm;
    double bestPeak = 0;
    double bestRms = 0;
    final DateTime deadline = DateTime.now().add(Duration(seconds: seconds));
    int polls = 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final GalAudioSlice? s = await loopback.grabRecent(3000);
      polls++;
      if (s == null || s.isEmpty) {
        continue;
      }
      final (double peak, double rms) = _peakRms(s.pcm, s.format);
      if (peak > bestPeak) {
        bestPeak = peak;
        bestRms = rms;
        bestPcm = Uint8List.fromList(s.pcm);
      }
      if (polls % 5 == 0) {
        print('GALV POLL $polls bestPeak=${bestPeak.toStringAsFixed(4)} '
            'bestRms=${bestRms.toStringAsFixed(5)}');
      }
    }
    await loopback.stop();

    if (bestPcm == null || bestPeak <= 0) {
      print('GALV RESULT name=$name captured=false peak=0 '
          'note=无声（游戏未播语音或 loopback 静音）');
      return;
    }

    // 取整段最响的（最多 4s）拼 WAV。
    final int durMs = pcmDurationMs(bestPcm.length, fmt.byteRate);
    final Uint8List sub = slicePcmByMs(bestPcm, fmt, 0, math.min(4000, durMs));
    final Uint8List wav = buildWavBytes(sub, fmt);
    final String wavPath = '$outDir/$name.wav';
    File(wavPath).writeAsBytesSync(wav);

    // 截目标游戏窗口。
    String? pngPath;
    final Uint8List? png = await _captureMatchingWindow(match);
    if (png != null && png.isNotEmpty) {
      pngPath = '$outDir/$name.png';
      File(pngPath).writeAsBytesSync(png);
    }

    final String metaPath = '$outDir/$name.json';
    File(metaPath).writeAsStringSync(jsonEncode(<String, Object?>{
      'mediaBase': name,
      'game': match.isEmpty ? name : match,
      'source': 'loopback',
      'fmt': '${fmt.sampleRate}/${fmt.channels}/${fmt.bitsPerSample}',
      'pcmBytes': sub.length,
      'peak': bestPeak,
      'rms': bestRms,
      'wav': '$name.wav',
      'png': pngPath != null ? '$name.png' : null,
    }));

    print('GALV RESULT name=$name captured=true '
        'peak=${bestPeak.toStringAsFixed(4)} rms=${bestRms.toStringAsFixed(5)} '
        'durMs=${pcmDurationMs(sub.length, fmt.byteRate)} '
        'wav=$wavPath png=${pngPath ?? "none"}');
    expect(bestPeak, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// 计算一段 PCM 的峰值与 RMS（归一化到 0..1）。支持 16bit 整型与 32bit float。
(double, double) _peakRms(List<int> pcm, PcmFormat fmt) {
  final Uint8List bytes = Uint8List.fromList(pcm);
  final ByteData bd = ByteData.sublistView(bytes);
  double peak = 0;
  double sumSq = 0;
  int n = 0;
  if (fmt.isFloat && fmt.bitsPerSample == 32) {
    for (int i = 0; i + 4 <= bytes.length; i += 4) {
      final double v = bd.getFloat32(i, Endian.little).abs();
      if (v > peak) peak = v;
      sumSq += v * v;
      n++;
    }
  } else if (fmt.bitsPerSample == 16) {
    for (int i = 0; i + 2 <= bytes.length; i += 2) {
      final double v = bd.getInt16(i, Endian.little).abs() / 32768.0;
      if (v > peak) peak = v;
      sumSq += v * v;
      n++;
    }
  } else if (fmt.bitsPerSample == 32) {
    for (int i = 0; i + 4 <= bytes.length; i += 4) {
      final double v = bd.getInt32(i, Endian.little).abs() / 2147483648.0;
      if (v > peak) peak = v;
      sumSq += v * v;
      n++;
    }
  }
  final double rms = n > 0 ? math.sqrt(sumSq / n) : 0;
  return (peak, rms);
}

/// 截标题含 [match] 的第一个窗口（[match] 空则截首个有标题窗口）。失败返回 null。
Future<Uint8List?> _captureMatchingWindow(String match) async {
  final List<ExternalWindowInfo> wins =
      await WindowCaptureChannel.listWindows();
  ExternalWindowInfo? target;
  for (final ExternalWindowInfo w in wins) {
    if (w.title.trim().isEmpty) continue;
    if (match.isEmpty || w.title.contains(match)) {
      target = w;
      break;
    }
  }
  if (target == null) return null;
  final WindowCaptureResult r =
      await WindowCaptureChannel.captureWindow(target.hwnd);
  return r.pngBytes;
}
