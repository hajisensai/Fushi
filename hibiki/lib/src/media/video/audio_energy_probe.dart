import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/media/video/video_clip_exporter.dart';

/// 视频/有声书的「逐帧音频能量包络」抽取（TODO-701 阶段1，自动对轴用）。
///
/// 经 [FfmpegBackend] 抽象跑一遍 ffmpeg：用 `astats` 计算每个分析窗口的 RMS 电平，
/// 再用 `ametadata=print` 把每帧的 `lavfi.astats.Overall.RMS_level`（连同 `pts_time`）
/// 打到 stderr，解析成等间隔的能量序列（dB，越大越响）。`-f null -` 不产出文件，只读
/// 元数据。结果喂 `subtitle_auto_align.dart` 的纯算法做互相关求整体平移。
///
/// **降级**：移动端 [KitFfmpegBackend] 的 `getOutput` 未必含逐帧 `ametadata` 行，或
/// ffmpeg 不可用/超时——此时返回空包络，调用方靠 `subtitle_auto_align` 的置信门控
/// 安全降级（不写穿延迟），并 `debugPrint` 诊断而非静默。

/// 默认分析窗口（毫秒）。与 [kSubtitleAutoAlignBinMs] 对齐：100ms 一帧 RMS，既给互相关
/// 足够分辨率，又把一部 2h 电影的样本控制在 ~72000 行内。
const int kAudioEnergyWindowMs = 100;

/// 自动对轴探测的默认时间上界（毫秒）：只抽视频前 20 分钟的音频能量。求一个**全局
/// 固定整体平移**（与手动延迟同义）足够——整轨抽包络对 2h 4K REMUX 要数十秒~分钟
/// （astats 读穿整条音轨），前 N 分钟即可定位偏移。截断同时作用于 ffmpeg `-t`（少抽
/// 音频）与字幕 cue 栅格化上界（[buildCueActivityEnvelope] 的 durationMs），两侧栅格都
/// 从 t=0 同 binMs 起、截到同一上界，相位一致不偏。0 或负值表示不截断（抽整轨）。
const int kSubtitleAutoAlignProbeLimitMs = 20 * 60 * 1000;

/// **纯函数**：构造抽取逐帧音频 RMS 能量的 ffmpeg 参数。
///
/// 关键链路（必须 `astats` + `ametadata=print` **配对**）：
/// - `aresample=<rate>`：统一采样率，让窗口时长稳定。
/// - `asetnsamples=n=<N>:p=0`：把音频切成定长样本块（N = rate * windowMs / 1000），
///   每块对应一个分析窗口（≈[windowMs] 毫秒）。
/// - `astats=metadata=1:reset=1`：对**每个**样本块算统计并写进 frame metadata
///   （`reset=1` 让统计逐块复位，否则只在 EOF 出一条汇总——单 `astats` 的陷阱）。
/// - `ametadata=print:key=lavfi.astats.Overall.RMS_level`：把每块的 RMS_level 连同
///   `pts_time` 打到 stderr（这步才让逐帧能量「可见」，否则 astats 只是写进 metadata
///   没人读）。
/// - `-map 0:a:<idx>`（可选）：多音轨时裁到用户正在听的那条轨。越界由 [resolveAudioMapIndex]
///   （BUG-345 同范式）拦截：[audioStreamIndex] >= [audioStreamCount] 时不加 `-map` 回退默认
///   轨——外挂音轨场景 mpv 轨序号未必 = ffmpeg `0:a:N`，越界会让 ffmpeg `Stream map matches
///   no streams` 硬失败→空包络→上层 noData 安全降级（不误移），故宁可回退默认轨。
/// - `-t <limitSeconds>`（可选）：只抽前 [limitSeconds] 秒音频（大文件性能截断，与字幕
///   cue 栅格化上界同步，见 [kSubtitleAutoAlignProbeLimitMs]）。须置于输入**之后**（输出
///   选项），裁的是已解码音频时长。
/// - `-f null -`：丢弃音频输出，只要 stderr 上的元数据。
///
/// 无 IO，可单测。
List<String> buildFfmpegPcmEnvelopeArgs({
  required String inputPath,
  int windowMs = kAudioEnergyWindowMs,
  int sampleRate = 8000,
  int? audioStreamIndex,
  int? audioStreamCount,
  int? limitSeconds,
}) {
  final int win = windowMs <= 0 ? kAudioEnergyWindowMs : windowMs;
  final int rate = sampleRate <= 0 ? 8000 : sampleRate;
  final int nsamples = (rate * win) ~/ 1000;
  final int blockSamples = nsamples <= 0 ? 1 : nsamples;
  // 越界回退：与制卡裁剪路径共用 BUG-345 边界判定，越界则不加 `-map` 用默认轨。
  final int? mapIndex = resolveAudioMapIndex(
    audioStreamIndex: audioStreamIndex,
    audioStreamCount: audioStreamCount,
  );
  final List<String> args = <String>[
    '-hide_banner',
    '-nostats',
    '-i',
    inputPath
  ];
  if (mapIndex != null) {
    args.addAll(<String>['-map', '0:a:$mapIndex']);
  }
  // 性能截断：只解码前 limitSeconds 秒（输出选项，须在 -i 之后）。
  if (limitSeconds != null && limitSeconds > 0) {
    args.addAll(<String>['-t', '$limitSeconds']);
  }
  args.addAll(<String>[
    '-af',
    'aresample=$rate,'
        'asetnsamples=n=$blockSamples:p=0,'
        'astats=metadata=1:reset=1,'
        'ametadata=print:key=lavfi.astats.Overall.RMS_level',
    '-f',
    'null',
    '-',
  ]);
  return args;
}

/// **纯函数**：解析 `buildFfmpegPcmEnvelopeArgs` 跑出的 ffmpeg stderr，提取按时间排序
/// 的逐帧 RMS 能量序列（dB）。
///
/// ametadata=print 的输出形如（成对的两行）：
/// ```
/// frame:0    pts:0       pts_time:0
/// lavfi.astats.Overall.RMS_level=-30.123456
/// frame:1    pts:800     pts_time:0.1
/// lavfi.astats.Overall.RMS_level=-22.500000
/// ```
/// 按出现顺序收集 `RMS_level` 值（已随时间单调排序，与窗口次序一致）。`-inf`（纯静音
/// 块的 dB）映射为一个很低的有限值（[silenceDb]），避免污染后续 min/max 归一化。
/// 无匹配行返回空列表（移动端 KitFfmpegBackend 拿不到逐帧行时即此情形）。
List<double> parseAudioRmsEnvelopeFromFfmpegLog(
  String ffmpegStderr, {
  double silenceDb = -120.0,
}) {
  if (ffmpegStderr.isEmpty) return const <double>[];
  final List<double> values = <double>[];
  final RegExp pattern = RegExp(
      r'lavfi\.astats\.Overall\.RMS_level\s*=\s*(-?\d+(?:\.\d+)?|-?inf)');
  for (final RegExpMatch m in pattern.allMatches(ffmpegStderr)) {
    final String raw = m.group(1)!;
    if (raw == '-inf' || raw == 'inf') {
      values.add(silenceDb);
      continue;
    }
    final double? v = double.tryParse(raw);
    if (v == null) continue;
    values.add(v.isFinite ? v : silenceDb);
  }
  return values;
}

/// **纯函数**：按容器字节数放大单趟探测的超时（与字幕抽取 `subtitleExtractTimeoutForBytes`
/// 同范式，BUG-104）。逐帧 astats 要把整条音轨读穿，读时随容器体积增长；固定超时对大
/// 体积交错容器（多 GB REMUX）会在冷缓存 + 播放 IO 争用下静默失败。基线 60s + 8s/GB，
/// clamp 到 [60s, 1200s]。该公式是 `@visibleForTesting` 的字幕抽取版的同义实现（那个不能
/// 跨文件用），不引依赖，便于单测。
Duration audioEnergyProbeTimeoutForBytes(int sizeBytes) {
  final double gb = sizeBytes / (1024 * 1024 * 1024);
  final int seconds = (60 + gb * 8).clamp(60, 1200).round();
  return Duration(seconds: seconds);
}

/// 抽取 [videoPath] 的逐帧音频 RMS 能量包络（经 [FfmpegBackend]）。
///
/// 超时复用 [subtitleExtractTimeoutForBytes]（按容器字节数放大，BUG-104 同范式）。
/// 失败 / 超时 / 空输出一律返回空列表（优雅降级），并 `debugPrint` 诊断——尤其移动端
/// [KitFfmpegBackend] 的 `getOutput` 可能不含逐帧 `ametadata` 行，此时空包络会让上层
/// 自动对轴按置信门控降级，**不**错误平移。
Future<List<double>> extractAudioEnergyEnvelope({
  required String videoPath,
  int windowMs = kAudioEnergyWindowMs,
  int? audioStreamIndex,
  int? audioStreamCount,
  int? limitMs = kSubtitleAutoAlignProbeLimitMs,
}) async {
  if (!File(videoPath).existsSync()) {
    debugPrint('[audio-energy] input missing: $videoPath');
    return const <double>[];
  }
  final int sizeBytes = _fileSizeOrZero(videoPath);
  final Duration timeout = audioEnergyProbeTimeoutForBytes(sizeBytes);
  // 性能截断：limitMs 换算成 ffmpeg `-t` 秒数（向上取整，保证覆盖到上界那一格）；
  // <=0 或 null 表示抽整轨。与 [buildCueActivityEnvelope] 的 durationMs 上界须取同值。
  final int? limitSeconds =
      (limitMs != null && limitMs > 0) ? (limitMs + 999) ~/ 1000 : null;
  try {
    final FfmpegRunResult result = await resolveFfmpegBackend().run(
      buildFfmpegPcmEnvelopeArgs(
        inputPath: videoPath,
        windowMs: windowMs,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
        limitSeconds: limitSeconds,
      ),
      timeout,
    );
    if (result.returnCode == null) {
      debugPrint('[audio-energy] timed out for "$videoPath" '
          '(size=$sizeBytes bytes) — auto-align skipped this time');
      return const <double>[];
    }
    final List<double> envelope =
        parseAudioRmsEnvelopeFromFfmpegLog(result.output);
    if (envelope.isEmpty) {
      // 跑成功但拿不到逐帧 RMS 行：移动端 KitFfmpegBackend.getOutput 不含 ametadata
      // 逐帧打印的典型表现。上层据空包络置信门控降级，不静默。
      debugPrint('[audio-energy] no per-frame RMS in ffmpeg output for '
          '"$videoPath" (returnCode=${result.returnCode}, '
          'executable=${result.executable}); auto-align will degrade');
    }
    return envelope;
  } on ProcessException catch (e) {
    debugPrint('[audio-energy] ffmpeg unavailable: $e');
    return const <double>[];
  } catch (e, stack) {
    debugPrint('[audio-energy] failed: $e\n$stack');
    return const <double>[];
  }
}

int _fileSizeOrZero(String path) {
  try {
    return File(path).lengthSync();
  } catch (_) {
    return 0;
  }
}
