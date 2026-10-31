import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/video/strm_file.dart'
    show lacksLocalMediaFile;
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
/// `getOutput` 默认只等 5 秒尚未送达的异步日志——此前的实现与注释都记录移动端拿不到逐帧行，
/// 用户侧表现是「可视化字幕调轴只有 Windows 有」。文件通道不经日志，与后端无关，五端同一条
/// 数据路径；stderr 仍作兜底解析（极旧的 ffmpeg 不认 `file=` 时）。
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

/// 流音源（媒体服务器 / 在线源，没有本地文件）的波形 / 自动对轴探测上界（毫秒）：3 分钟。
///
/// 本地文件读前 20 分钟是本机磁盘 IO；流则要真的把这段音频从服务器拉下来——最坏与
/// 实时播放一样慢（20 分钟 = 等 20 分钟），反馈人实测「要等待很久」。全局固定整体
/// 平移只需要足够多的对白与字幕互相关，前 3 分钟（1800 帧 @100ms）够用；对白太少时
/// 互相关置信度不足会走既有的低置信降级、不乱平移。
const int kStreamSubtitleAlignProbeLimitMs = 3 * 60 * 1000;

/// **纯函数**：按音源种类给出探测时间上界。页面的抽音、`-t` 截断、cue 栅格化上界、
/// 波形时间窗必须同取这一个值，否则两侧栅格长度不一致、波形窗口与实际音频错位。
int subtitleAlignProbeLimitMs({required bool fromStream}) => fromStream
    ? kStreamSubtitleAlignProbeLimitMs
    : kSubtitleAutoAlignProbeLimitMs;

/// [buildFfmpegPcmEnvelopeArgs] 记完逐帧 RMS 后，把音频拼回多大的输出帧（秒）。
/// 小帧直接进 null 复用器的逐帧开销比 astats 本身还大，见该函数文档。
const int _kEnvelopeOutputFrameSeconds = 6;

/// **纯函数**：构造抽取逐帧音频 RMS 能量的 ffmpeg 参数。
///
/// 关键链路（必须 `astats` + `ametadata=print` **配对**）：
/// - `aresample=<rate>`：统一采样率，让窗口时长稳定。
/// - `asetnsamples=n=<N>:p=0`：把音频切成定长样本块（N = rate * windowMs / 1000），
///   每块对应一个分析窗口（≈[windowMs] 毫秒）。
/// - `astats=metadata=1:reset=1`：对**每个**样本块算统计并写进 frame metadata
///   （`reset=1` 让统计逐块复位，否则只在 EOF 出一条汇总——单 `astats` 的陷阱）。
///   `measure_perchannel=none:measure_overall=RMS_level` 只算我们要的那一项：默认 astats
///   每块要算二十来项统计（峰值 / 直流 / 熵 / 过零率……），全都被丢掉。实测 20 分钟音频
///   20ms 窗口（6 万块）在桌面 ffmpeg 7.1 上 28.5s → 12.3s、逐帧输出逐字节相同；移动端
///   ffmpeg-kit（6.0）同样认这两个选项（FFmpeg 4.4 起），手机上这一步的耗时决定波形
///   能不能在超时内出来。
/// - `ametadata=print:key=lavfi.astats.Overall.RMS_level`：把每块的 RMS_level 连同
///   `pts_time` 打出来（这步才让逐帧能量「可见」，否则 astats 只是写进 metadata
///   没人读）。给了 [metadataFilePath] 时追加 `:file=<转义路径>` 写进该文件（见文件头：
///   移动端日志通道不可靠）；不给则打到 stderr。
/// - `-map 0:a:<idx>`（可选）：多音轨时裁到用户正在听的那条轨。越界由 [resolveAudioMapIndex]
///   （BUG-345 同范式）拦截：[audioStreamIndex] >= [audioStreamCount] 时不加 `-map` 回退默认
///   轨——外挂音轨场景 mpv 轨序号未必 = ffmpeg `0:a:N`，越界会让 ffmpeg `Stream map matches
///   no streams` 硬失败→空包络→上层 noData 安全降级（不误移），故宁可回退默认轨。
/// - `-t <limitSeconds>`（可选）：只抽前 [limitSeconds] 秒音频（大文件性能截断，与字幕
///   cue 栅格化上界同步，见 [kSubtitleAutoAlignProbeLimitMs]）。**必须是输入选项**（置于
///   `-i` **之前**）：作输出选项时它只在输出端按帧截断，而末尾的大帧
///   `asetnsamples`（见下）要攒满 [_kEnvelopeOutputFrameSeconds] 秒、滤镜图还会预读，
///   `ametadata` 在输出端停下前已多打了一截逐帧行——实测 20 分钟上界抽出 1212 秒
///   （60600 帧），10 秒上界抽出 18 秒。波形面板把整条包络均匀铺在
///   `[0, 上界)` 上，多出的尾巴把整条波形压缩约 1%，3 分半处就与字幕线 / 播放头错开
///   2 秒（BUG：有声段画成静音）。输入端截断让解复用在上界停下，帧数恰为上界 / 窗口。
/// - `-vn`：丢弃视频流（TODO-1244 回归修复）。**必须**加——否则没有 `-map 0:a`（越界/无
///   显式音轨的默认回退路径）时，ffmpeg 会把输入的视频流也映射进 `-f null -` 输出，并试图
///   用 null 复用器的默认视频编码器 `wrapped_avframe` 编码它。旧桌面捆绑的**最小
///   ffmpeg-min**（TODO-1214，编码器白名单只留 libx264/pcm）**没有** `wrapped_avframe`
///   → 整条命令在打开输出阶段 `Encoder not found` 硬失败 → 零逐帧 RMS 行 → 空包络 →
///   **对轴界面波形完全不显示**。`-vn` 只喂音频给 astats，且省掉无谓的
///   视频解码/编码（本就只要音频能量）。统一 FFmpeg 为全量构建、有 `wrapped_avframe`，
///   不加 `-vn` 也不会失败；`-vn` 仍保留（省视频解码，兼容系统 ffmpeg）。
/// - 末尾再一个 `asetnsamples=n=<rate*[_kEnvelopeOutputFrameSeconds]>:p=0`：`ametadata`
///   已经逐小块记完，**再把音频拼回大帧**才交给编码器 / null 复用器：6 万个 20ms 小帧
///   逐帧过 pcm 编码器与 null 复用器的开销比 astats 本身还大，拼成 6s 一帧后 20 分钟只剩
///   200 个输出帧。实测 ffmpeg 7.1：12.3s → 5.0s，逐帧 RMS 输出逐字节相同。
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
  final List<String> args = <String>['-hide_banner', '-nostats'];
  // 性能截断：只读前 limitSeconds 秒。必须是输入选项（-i 之前），作输出选项会被末尾
  // 大帧 asetnsamples 拖过上界、包络比时间窗长，见上方文档。
  if (limitSeconds != null && limitSeconds > 0) {
    args.addAll(<String>['-t', '$limitSeconds']);
  }
  args.addAll(<String>['-i', inputPath]);
  if (mapIndex != null) {
    args.addAll(<String>['-map', '0:a:$mapIndex']);
  }
  // TODO-1244 回归修复：丢弃视频流。没有 `-map 0:a` 时若不加 `-vn`，ffmpeg 会把视频流也
  // 送进 `-f null -`，用 null 复用器的默认视频编码器 wrapped_avframe 编码——旧桌面捆绑的最小
  // ffmpeg-min 无此编码器，整条命令 `Encoder not found` 硬失败→空包络→波形不显示（统一
  // FFmpeg 已有该编码器）。只要音频，`-vn` 保留。
  args.add('-vn');
  // 逐帧行写文件（移动端日志通道不可靠，见文件头）；不给路径则沿旧行为打 stderr。
  final String printTarget = metadataFilePath == null
      ? ''
      : ':file=${escapeFfmpegFilterOptionValue(metadataFilePath)}';
  args.addAll(<String>[
    '-af',
    'aresample=$rate,'
        'asetnsamples=n=$blockSamples:p=0,'
        'astats=metadata=1:reset=1:'
        'measure_perchannel=none:measure_overall=RMS_level,'
        'ametadata=print:key=lavfi.astats.Overall.RMS_level$printTarget,'
        'asetnsamples=n=${rate * _kEnvelopeOutputFrameSeconds}:p=0',
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
/// 无匹配行返回空列表。匹配规则等价于正则
/// `lavfi\.astats\.Overall\.RMS_level\s*=\s*(-?\d+(?:\.\d+)?|-?inf)`（`\s` 含 Unicode 空白）。
///
/// 解析在 Rust（native/fushi_compute `ffc_signal_parse_rms_log`，整段文本一次调用）。
/// 库不可用抛 `FushiComputeUnavailableError`。
List<double> parseAudioRmsEnvelopeFromFfmpegLog(
  String ffmpegStderr, {
  double silenceDb = -120.0,
}) {
  if (ffmpegStderr.isEmpty) return const <double>[];
  return parseAudioRmsEnvelopeFromFfmpegLogBytes(
    utf8.encode(ffmpegStderr),
    silenceDb: silenceDb,
  );
}

/// [parseAudioRmsEnvelopeFromFfmpegLog] 的字节版：直接吃 `file=` 写出的逐帧文件内容
/// （UTF-8），省掉解码成 Dart 字符串再走正则的一趟。不是合法 UTF-8 抛 [FormatException]
/// （与 `File.readAsStringSync` 同）。
List<double> parseAudioRmsEnvelopeFromFfmpegLogBytes(
  Uint8List utf8Bytes, {
  double silenceDb = -120.0,
}) => ffcParseRmsLog(utf8Bytes, silenceDb: silenceDb);

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
  // 没有本机媒体字节的路径（网络流 / `.strm` / DVD title）不碰文件系统，与
  // video_member_file.dart 的 hasLocalMediaFile 同一判据；其余一次 async stat 拿
  // 存在性与体积：视频可能在网络盘上，同步 stat 会冻结 UI isolate（BUG-3756）。
  final FileStat? videoStat = lacksLocalMediaFile(videoPath)
      ? null
      : await File(videoPath).stat();
  if (videoStat == null || videoStat.type == FileSystemEntityType.notFound) {
    debugPrint('[audio-energy] input missing: $videoPath');
    return const <double>[];
  }
  final int sizeBytes = videoStat.size < 0 ? 0 : videoStat.size;
  final Duration timeout = audioEnergyProbeTimeoutForBytes(sizeBytes);
  // 性能截断：limitMs 换算成 ffmpeg `-t` 秒数（向上取整，保证覆盖到上界那一格）；
  // <=0 或 null 表示抽整轨。与 [buildCueActivityEnvelope] 的 durationMs 上界须取同值。
  final int? limitSeconds = (limitMs != null && limitMs > 0)
      ? (limitMs + 999) ~/ 1000
      : null;
  Directory? tempDir;
  try {
    tempDir = Directory.systemTemp.createTempSync('fushi_audio_energy_');
    final File metadataFile = File(
      '${tempDir.path}${Platform.pathSeparator}rms.txt',
    );
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
      debugPrint(
        '[audio-energy] timed out for "$videoPath" '
        '(size=$sizeBytes bytes) — auto-align skipped this time',
      );
      return const <double>[];
    }
    List<double> envelope = metadataFile.existsSync()
        ? parseAudioRmsEnvelopeFromFfmpegLogBytes(
            metadataFile.readAsBytesSync(),
          )
        : const <double>[];
    if (envelope.isEmpty) {
      envelope = parseAudioRmsEnvelopeFromFfmpegLog(result.output);
    }
    if (envelope.isEmpty) {
      // 文件与 stderr 都没有逐帧 RMS 行：ffmpeg 失败（看 failureSummary）或输入无音轨。
      // 上层据空包络置信门控降级，不静默。
      debugPrint(
        '[audio-energy] no per-frame RMS for "$videoPath": '
        '${result.failureSummary}; auto-align will degrade',
      );
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

/// **纯函数**：把逐帧 RMS 能量包络（[extractAudioEnergyEnvelope] 返回的 dB 序列，越大越响，
/// 静音块为很低的有限值 [silenceDb]）降采样到 [targetBuckets] 个桶，并**归一化到 0..1**，
/// 供波形 painter 直接按桶宽绘制（TODO-1051 阶段A / TODO-1244，字幕对轴波形可视化）。
///
/// **分贝 → 线性振幅**（`amp = 10^(dB/20)`）：先把每帧 dB 转成线性振幅再做峰值 / 归一化。
/// 这是「波形密度 / 对比正确」的根因修——分贝是对数量纲，房间底噪（约 -60~-80dB）与语音峰值
/// （约 -15~-30dB）在分贝轴上只差几十，直接线性拉伸 dB 会让底噪几乎和语音一样高、糊成一条带；
/// 成熟波形工具（Audacity / Aegisub）画的都是线性振幅，静音塌到接近 0、语音尖峰凸出，句子边界可辨。
///
/// **桶内取峰值（max），不取桶内 RMS**：入参 [frames] 本身已是逐帧 RMS 包络（见
/// [kSubtitleWaveformWindowMs]），再对每桶做二次 RMS 会二次平滑、淹没瞬态；波形可视化要让
/// 用户一眼看出响度尖峰的节奏以核对字幕对齐，故每桶取该区间**最大**线性振幅，保留瞬态。
///
/// **归一化**：以「桶内最小振幅」为地基、「第 [normalizeCeilingPercentile] 分位振幅」为上限做
/// 线性拉伸 `(v - min) / (ceil - min)` 并 clamp 到 0..1。用高分位而非绝对峰值当上限，避免单个
/// 响亮瞬态把整段语音压成贴地一线（成熟波形工具同款离群点抑制；分位落点四舍五入到最近样本）。
/// 全同值（含单一静音，`ceil == min`）时不除零、返回全 0。桶数很少（单测的 2~3 桶）时分位落到
/// 最大值，退化为经典 min/max 归一化。
///
/// **退化输入（一律 sane，不抛、不越界）**：
/// - [frames] 空 或 [targetBuckets] <= 0 → 返回空列表 `[]`。
/// - [targetBuckets] >= 帧数 → 每帧各占一桶（不上采样、不插值补桶），返回长度 = 帧数。
/// - 否则输出长度恰为 [targetBuckets]，第 i 桶覆盖 `frames[i*n/B .. (i+1)*n/B)`（末桶收尾到 n），
///   每桶至少含 1 帧，无空桶、无越界读。
///
/// 幂等：无内部状态、无 IO，同输入恒定同输出。计算在 Rust（native/fushi_compute）。
/// 同一条包络要按不同宽度反复降采样时（波形面板缩放 / 改宽）用 [FfcEnergyEnvelope]：
/// dB → 振幅只在构造时算一遍，本函数每次调用都要重算。
List<double> downsampleEnergyEnvelope(
  List<double> frames,
  int targetBuckets, {
  double normalizeCeilingPercentile = 0.99,
}) {
  if (frames.isEmpty || targetBuckets <= 0) return <double>[];
  return FfcEnergyEnvelope.fromDb(
    frames,
  ).downsample(targetBuckets, percentile: normalizeCeilingPercentile);
}
