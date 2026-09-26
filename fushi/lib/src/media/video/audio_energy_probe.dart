import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';

/// 视频/有声书的「逐帧音频能量包络」抽取（TODO-701 阶段1，自动对轴用）。
///
/// 经 [FfmpegBackend] 抽象跑一遍 ffmpeg：用 `astats` 计算每个分析窗口的 RMS 电平，
/// 再用 `ametadata=print` 把每帧的 `lavfi.astats.Overall.RMS_level`（连同 `pts_time`）
/// 打到 stderr，解析成等间隔的能量序列（dB，越大越响）。`-f null -` 不产出文件，只读
/// 元数据。结果喂 `subtitle_auto_align.dart` 的纯算法做互相关求整体平移。
///
/// **逐帧行走文件，不走日志**：`ametadata=print` 带 `file=` 把逐帧行写进临时文件，再由
/// Dart 读回解析。此前只打 stderr，桌面 CLI 读子进程管道没问题，移动端 ffmpeg-kit 却要把
/// 每一行日志跨 JNI / 平台通道异步搬回来（20ms 窗口抽 20 分钟 = 6 万帧、12 万条日志），
/// `getOutput` 默认只等 5 秒异步日志——结果不全或为空，波形对轴在 Android / iOS 从来打不开
/// （「可视化字幕调轴只有 Windows 有」）。文件通道与后端无关，五端同一条数据路径；stderr
/// 仍作兜底解析（极旧的 ffmpeg 不认 `file=` 时）。
///
/// **降级**：ffmpeg 不可用/超时/两路都拿不到逐帧行——此时返回空包络，调用方靠
/// `subtitle_auto_align` 的置信门控安全降级（不写穿延迟），并 `debugPrint` 诊断而非静默。

/// 默认分析窗口（毫秒）。与 [kSubtitleAutoAlignBinMs] 对齐：100ms 一帧 RMS，既给互相关
/// 足够分辨率，又把一部 2h 电影的样本控制在 ~72000 行内。
const int kAudioEnergyWindowMs = 100;

/// 字幕对轴**波形可视化**的分析窗口（毫秒）。比自动对轴的采样窗口（100ms = 10 帧/秒，
/// 够互相关求整体平移，但画成波形只有 10 根柱/秒、粗得看不出句子）细 5 倍：20ms = 50
/// 帧/秒，让波形密度接近成熟工具（Audacity / Aegisub），语音节奏与句间静音清晰可辨。
/// 仅用于波形显示探测（`_loadSubtitleWaveformEnvelope`），不改自动对轴的采样率。
const int kSubtitleWaveformWindowMs = 20;

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
///   `pts_time` 打出来（这步才让逐帧能量「可见」，否则 astats 只是写进 metadata
///   没人读）。给了 [metadataFilePath] 时追加 `:file=<转义路径>` 写进该文件（见文件头：
///   移动端日志通道不可靠）；不给则打到 stderr。
/// - `-map 0:a:<idx>`（可选）：多音轨时裁到用户正在听的那条轨。越界由 [resolveAudioMapIndex]
///   （BUG-345 同范式）拦截：[audioStreamIndex] >= [audioStreamCount] 时不加 `-map` 回退默认
///   轨——外挂音轨场景 mpv 轨序号未必 = ffmpeg `0:a:N`，越界会让 ffmpeg `Stream map matches
///   no streams` 硬失败→空包络→上层 noData 安全降级（不误移），故宁可回退默认轨。
/// - `-t <limitSeconds>`（可选）：只抽前 [limitSeconds] 秒音频（大文件性能截断，与字幕
///   cue 栅格化上界同步，见 [kSubtitleAutoAlignProbeLimitMs]）。须置于输入**之后**（输出
///   选项），裁的是已解码音频时长。
/// - `-vn`：丢弃视频流（TODO-1244 回归修复）。**必须**加——否则没有 `-map 0:a`（越界/无
///   显式音轨的默认回退路径）时，ffmpeg 会把输入的视频流也映射进 `-f null -` 输出，并试图
///   用 null 复用器的默认视频编码器 `wrapped_avframe` 编码它。桌面发布捆绑的**最小
///   ffmpeg-min**（TODO-1214，编码器白名单只留 libx264/pcm）**没有** `wrapped_avframe`
///   → 整条命令在打开输出阶段 `Encoder not found` 硬失败 → 零逐帧 RMS 行 → 空包络 →
///   **对轴界面波形完全不显示**。`-vn` 只喂音频给 astats，与最小 ffmpeg 兼容，且省掉无谓的
///   视频解码/编码（本就只要音频能量）。全量 ffmpeg 有 `wrapped_avframe` 也不受影响。
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
  String? metadataFilePath,
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
  // TODO-1244 回归修复：丢弃视频流。没有 `-map 0:a` 时若不加 `-vn`，ffmpeg 会把视频流也
  // 送进 `-f null -`，用 null 复用器的默认视频编码器 wrapped_avframe 编码——桌面捆绑的最小
  // ffmpeg-min 无此编码器，整条命令 `Encoder not found` 硬失败→空包络→波形不显示。只要音频。
  args.add('-vn');
  // 逐帧行写文件（移动端日志通道不可靠，见文件头）；不给路径则沿旧行为打 stderr。
  final String printTarget = metadataFilePath == null
      ? ''
      : ':file=${escapeFfmpegFilterOptionValue(metadataFilePath)}';
  args.addAll(<String>[
    '-af',
    'aresample=$rate,'
        'asetnsamples=n=$blockSamples:p=0,'
        'astats=metadata=1:reset=1,'
        'ametadata=print:key=lavfi.astats.Overall.RMS_level$printTarget',
    '-f',
    'null',
    '-',
  ]);
  return args;
}

/// **纯函数**：把任意字符串（典型是文件路径）转义成可以放进 `-af` 滤镜图里某个滤镜
/// **选项值**的形式。
///
/// ffmpeg 对滤镜图做两层解析（官方文档 "Notes on filtergraph escaping"），每层都会吃掉
/// 引号与反斜杠：
/// 1. 滤镜选项层（`key=value:key=value`）：`:` 分隔选项，`'` 引号、`\` 转义。先把值整体
///    包进单引号（引号内除 `'` 外全是字面量——Windows 盘符的 `:`、反斜杠都安全），值里的
///    `'` 按 shell 惯例拆成 `'\''`。
/// 2. 滤镜图层（`a,b;c[x]`）：`,` `;` `[` `]` 切分滤镜/链/标签，同样认 `'` 与 `\`。对第 1
///    步的结果再把 `\` `'` `,` `;` `[` `]` 逐个加反斜杠。
///
/// 两层都转义后，路径含空格、逗号、分号、方括号、单引号、盘符冒号或非 ASCII 字符都能原样
/// 到达滤镜。参数以 argv 数组传给 ffmpeg（CLI `Process.start` / ffmpeg-kit
/// `executeWithArguments`），不经 shell，故无第三层。无 IO，可单测。
String escapeFfmpegFilterOptionValue(String value) {
  final String quoted = "'${value.replaceAll("'", r"'\''")}'";
  final StringBuffer out = StringBuffer();
  for (final int rune in quoted.runes) {
    final String ch = String.fromCharCode(rune);
    if (ch == r'\' ||
        ch == "'" ||
        ch == ',' ||
        ch == ';' ||
        ch == '[' ||
        ch == ']') {
      out.write(r'\');
    }
    out.write(ch);
  }
  return out.toString();
}

/// **纯函数**：解析 `buildFfmpegPcmEnvelopeArgs` 跑出的 ffmpeg stderr（或 `file=` 写出的
/// 逐帧文件，两者行格式相同），提取按时间排序
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
/// 无匹配行返回空列表。
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
/// 逐帧行经 `ametadata` 的 `file=` 写进 [Directory.systemTemp] 下的临时文件（五端都可写：
/// 桌面是系统临时目录，Android / iOS 是 app 缓存目录），读完即删；文件没有逐帧行时回退
/// 解析 stderr。失败 / 超时 / 两路都空一律返回空列表（优雅降级），并 `debugPrint` 诊断，
/// 空包络会让上层自动对轴按置信门控降级，**不**错误平移。
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
  Directory? tempDir;
  try {
    tempDir = Directory.systemTemp.createTempSync('fushi_audio_energy_');
    final File metadataFile =
        File('${tempDir.path}${Platform.pathSeparator}rms.txt');
    final FfmpegRunResult result = await resolveFfmpegBackend().run(
      buildFfmpegPcmEnvelopeArgs(
        inputPath: videoPath,
        windowMs: windowMs,
        audioStreamIndex: audioStreamIndex,
        audioStreamCount: audioStreamCount,
        limitSeconds: limitSeconds,
        metadataFilePath: metadataFile.path,
      ),
      timeout,
    );
    if (result.returnCode == null) {
      debugPrint('[audio-energy] timed out for "$videoPath" '
          '(size=$sizeBytes bytes) — auto-align skipped this time');
      return const <double>[];
    }
    List<double> envelope = metadataFile.existsSync()
        ? parseAudioRmsEnvelopeFromFfmpegLog(metadataFile.readAsStringSync())
        : const <double>[];
    if (envelope.isEmpty) {
      envelope = parseAudioRmsEnvelopeFromFfmpegLog(result.output);
    }
    if (envelope.isEmpty) {
      // 文件与 stderr 都没有逐帧 RMS 行：ffmpeg 失败（看 failureSummary）或输入无音轨。
      // 上层据空包络置信门控降级，不静默。
      debugPrint('[audio-energy] no per-frame RMS for "$videoPath": '
          '${result.failureSummary}; auto-align will degrade');
    }
    return envelope;
  } on ProcessException catch (e) {
    debugPrint('[audio-energy] ffmpeg unavailable: $e');
    return const <double>[];
  } catch (e, stack) {
    debugPrint('[audio-energy] failed: $e\n$stack');
    return const <double>[];
  } finally {
    try {
      tempDir?.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// **纯函数**：把音频 RMS 电平（分贝 dBFS，≤0，越大越响）转成线性振幅（0..1）。
///
/// 波形可视化的关键契约：**必须在线性振幅域画，不能直接线性拉伸分贝**。分贝是对数量纲——
/// 房间底噪（约 -60~-80dB）与语音峰值（约 -15~-30dB）在分贝轴上只差几十，直接线性归一化后
/// 底噪仍有 ~40% 柱高，语音和静音糊成一条均匀带，看不出句子边界。成熟波形工具
/// （Audacity / Aegisub）画的都是线性 PCM 振幅：`amp = 10^(dB/20)`——静音塌到接近 0、语音
/// 尖峰凸出，句间静音一眼可辨。[silenceDb]=-120dB → 1e-6 ≈ 0。dBFS ≤ 0 → 结果 ∈ (0, 1]。
double dbToLinearAmplitude(double db) => math.pow(10.0, db / 20.0).toDouble();

/// **纯函数**：取 [values] 的第 [percentile] 分位值（0..1，就地排序副本，不改入参）。
///
/// 波形归一化的「上限」用高分位（而非绝对最大值）：单个响亮瞬态（音效 / 配乐重音 / 爆音）
/// 不会把整段语音压成贴地一条线。分位落点四舍五入到最近样本，空列表返回 0。
double _percentileValue(List<double> values, double percentile) {
  if (values.isEmpty) return 0.0;
  final double p = percentile.clamp(0.0, 1.0).toDouble();
  final List<double> sorted = List<double>.of(values)..sort();
  final int idx = ((sorted.length - 1) * p).round();
  return sorted[idx];
}

/// **纯函数**：把逐帧 RMS 能量包络（[extractAudioEnergyEnvelope] 返回的 dB 序列，越大越响，
/// 静音块为很低的有限值 [silenceDb]）降采样到 [targetBuckets] 个桶，并**归一化到 0..1**，
/// 供波形 painter 直接按桶宽绘制（TODO-1051 阶段A / TODO-1244，字幕对轴波形可视化）。
///
/// **分贝 → 线性振幅**（[dbToLinearAmplitude]）：先把每帧 dB 转成线性振幅再做峰值 / 归一化。
/// 这是「波形密度 / 对比正确」的根因修——直接线性拉伸 dB 会让底噪几乎和语音一样高、糊成一条带
/// （见 [dbToLinearAmplitude] 文档）；转到线性域后静音塌到接近 0、语音尖峰凸出，句子边界可辨。
///
/// **桶内取峰值（max），不取桶内 RMS**：入参 [frames] 本身已是逐帧 RMS 包络（见
/// [kSubtitleWaveformWindowMs]），再对每桶做二次 RMS 会二次平滑、淹没瞬态；波形可视化要让
/// 用户一眼看出响度尖峰的节奏以核对字幕对齐，故每桶取该区间**最大**线性振幅，保留瞬态。
///
/// **归一化**：以「桶内最小振幅」为地基、「第 [normalizeCeilingPercentile] 分位振幅」为上限做
/// 线性拉伸 `(v - min) / (ceil - min)` 并 clamp 到 0..1。用高分位而非绝对峰值当上限，避免单个
/// 响亮瞬态把整段语音压成贴地一线（[_percentileValue]，成熟波形工具同款离群点抑制）。全同值
/// （含单一静音，`ceil == min`）时不除零、返回全 0。桶数很少（单测的 2~3 桶）时分位落到最大值，
/// 退化为经典 min/max 归一化。
///
/// **退化输入（一律 sane，不抛、不越界）**：
/// - [frames] 空 或 [targetBuckets] <= 0 → 返回空列表 `[]`。
/// - [targetBuckets] >= 帧数 → 每帧各占一桶（不上采样、不插值补桶），返回长度 = 帧数。
/// - 否则输出长度恰为 [targetBuckets]，第 i 桶覆盖 `frames[i*n/B .. (i+1)*n/B)`（末桶收尾到 n），
///   每桶至少含 1 帧，无空桶、无越界读。
///
/// 幂等：无内部状态、无 IO，同输入恒定同输出。
List<double> downsampleEnergyEnvelope(
  List<double> frames,
  int targetBuckets, {
  double normalizeCeilingPercentile = 0.99,
}) {
  final int n = frames.length;
  if (n == 0 || targetBuckets <= 0) return <double>[];

  // 桶数 >= 帧数：不上采样，每帧一桶（桶数收敛到帧数）。桶数 < 帧数：恰好 targetBuckets 桶。
  final int buckets = targetBuckets >= n ? n : targetBuckets;

  // 第一趟：每桶取区间**线性振幅**峰值（先 dB→线性，再取 max，保留瞬态）。用 i*n/B 均分
  // 边界，末桶自然收尾到 n，且因 buckets <= n，每桶起点严格递增、至少含 1 帧，无空桶。
  final List<double> peaks = List<double>.filled(buckets, 0.0);
  double minPeak = double.infinity;
  for (int b = 0; b < buckets; b++) {
    final int start = (b * n) ~/ buckets;
    final int end =
        ((b + 1) * n) ~/ buckets; // exclusive；因 buckets<=n 必有 end>start
    double peak = dbToLinearAmplitude(frames[start]);
    for (int i = start + 1; i < end; i++) {
      final double amp = dbToLinearAmplitude(frames[i]);
      if (amp > peak) peak = amp;
    }
    peaks[b] = peak;
    if (peak < minPeak) minPeak = peak;
  }

  // 第二趟：以最小振幅为地基、高分位振幅为上限线性归一化到 0..1（离群瞬态不压垮语音）。
  // 全同值（含单一静音）时 ceil == min，不除零，返回全 0。
  final double ceiling = _percentileValue(peaks, normalizeCeilingPercentile);
  final double range = ceiling - minPeak;
  if (range <= 0) return List<double>.filled(buckets, 0.0);
  for (int b = 0; b < buckets; b++) {
    final double v = (peaks[b] - minPeak) / range;
    peaks[b] = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
  }
  return peaks;
}

int _fileSizeOrZero(String path) {
  try {
    return File(path).lengthSync();
  } catch (_) {
    return 0;
  }
}
