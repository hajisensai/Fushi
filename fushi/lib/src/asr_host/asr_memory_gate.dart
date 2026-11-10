/// Android 设备端 ASR 的内存门槛：开跑前按「这台机器此刻能腾出多少内存」判这个
/// 模型跑不跑得动，跑不动就抛 [AsrInsufficientMemoryException]（带可读原因与能跑
/// 的更小模型），而不是开跑后被系统 lowmemorykiller 杀掉整个 app。
///
/// **为什么要有这一层**（反馈 jbTZ4GIEyU，BUG-4367）：ZTE A103ZT（约 4 GB 内存，
/// Android 12）后台转录一本 m4b，进程 malloc 30 秒内从 77 MB 涨到 1390 MB、RSS
/// 从 540 MB 涨到 1.6 GB，前台被系统按低内存杀掉，连续两次。转录链路
/// （`AsrTranscriptionService.start` → 后台 isolate 建 ORT 会话 + fbank + 批量
/// encoder）此前在任何平台都不看设备内存，手机上「能不能跑」只体现在模型说明里
/// 的一句「手机上能跑，但很慢」。
///
/// 判据只用两个真实可读的量：
///
/// - **进程天花板**：物理内存 × [kAndroidAsrProcessCeilingFraction] 减去本进程
///   当前 RSS。Android 的 lmkd 在系统整体吃紧时杀前台进程，前台 app 能稳定占住的
///   内存远小于物理内存；上面那台 4 GB 机器在 RSS ≈ 1.6 GB 时被杀，0.4 正好落在
///   被杀线之下。
/// - **此刻可用**：`/proc/meminfo` 的 `MemAvailable`（内核估的「不换出就能拿到」
///   的内存）。两者取小。
///
/// 估算峰值见 [estimateAsrPeakMemoryBytes]。只在 Android 上生效（拍板范围）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi_asr_core/asr_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';

/// 转录链路与模型大小无关的工作集：PCM 块（300 s × 16 kHz）、fbank 工作线程、
/// ffmpeg 解码子进程的管道缓冲、批量 encoder 的激活与 ORT arena 的底座。
///
/// 标定：jbTZ4GIEyU 那次 ReazonSpeech int8（全套约 161 MB）转录让 RSS 净涨约
/// 1.07 GB；`161 MB × 3 + 600 MB ≈ 1.08 GB` 与实测吻合。
const int kAsrMemoryBaseWorkingSetBytes = 600 * 1024 * 1024;

/// 模型文件 → 常驻内存的倍数：ORT 建会话时权重本体 + 图优化后的副本 + 多个
/// 贪心解码会话各自持有的 decoder / joiner。
const int kAsrMemoryModelMultiplier = 3;

/// 前台 app 在 Android 上能稳定占住的内存占物理内存的比例（见文件头）。
const double kAndroidAsrProcessCeilingFraction = 0.4;

/// 一次读到的设备内存状况。字节为单位；[availableBytes] 读不到（老内核没有
/// `MemAvailable`）时为 null，只按天花板判。
@immutable
class DeviceMemorySnapshot {
  const DeviceMemorySnapshot({
    required this.totalBytes,
    required this.availableBytes,
    required this.processRssBytes,
  });

  final int totalBytes;
  final int? availableBytes;
  final int processRssBytes;

  @override
  String toString() =>
      'DeviceMemorySnapshot(total=$totalBytes, available=$availableBytes, '
      'rss=$processRssBytes)';
}

/// 纯函数：估算用 [pack] 的 [variant] 跑一次转录的进程内存净增峰值。
int estimateAsrPeakMemoryBytes(AsrModelPack pack, AsrEncoderVariant variant) =>
    pack.totalBytes(variant) * kAsrMemoryModelMultiplier +
    kAsrMemoryBaseWorkingSetBytes;

/// 纯函数：此刻还能给转录腾出多少内存（可为负 = 本进程已经超过天花板）。
int asrMemoryHeadroomBytes(DeviceMemorySnapshot memory) {
  final int ceiling =
      (memory.totalBytes * kAndroidAsrProcessCeilingFraction).floor() -
      memory.processRssBytes;
  final int? available = memory.availableBytes;
  return available == null ? ceiling : math.min(ceiling, available);
}

/// 开跑被内存门槛拦下。`toString` 就是给用户看的那句话（各入口的错误态都是
/// `'$error'` 原样显示——转录弹层、有声书自动转录队列、视频字幕），所以不用逐个
/// 入口去认这个类型。
class AsrInsufficientMemoryException implements Exception {
  const AsrInsufficientMemoryException({
    required this.modelName,
    required this.requiredBytes,
    required this.headroomBytes,
    required this.memory,
    this.suggestedModelName,
  });

  /// 被拦下的模型显示名。
  final String modelName;

  /// 估算需要的内存（[estimateAsrPeakMemoryBytes]）。
  final int requiredBytes;

  /// 此刻能腾出的内存（[asrMemoryHeadroomBytes]）。
  final int headroomBytes;

  /// 判定时读到的设备内存（日志 / 反馈排查用）。
  final DeviceMemorySnapshot memory;

  /// 同语言同素材里放得下的模型；null = 一个都放不下。
  final String? suggestedModelName;

  /// 给用户看的完整说明（当前语言）。
  String get message {
    final String head = t.asr_memory_insufficient(
      model: modelName,
      need: FushiByteFormat.bytes(requiredBytes),
      spare: FushiByteFormat.bytes(math.max(0, headroomBytes)),
    );
    final String? suggested = suggestedModelName;
    final String tail = suggested == null
        ? t.asr_memory_no_fitting_model
        : t.asr_memory_suggest_model(model: suggested);
    return '$head $tail';
  }

  @override
  String toString() => message;
}

/// 纯函数：门槛判定。放得下返回 null；放不下返回要抛的异常，
/// [alternatives]（同语言同素材可选的包，按注册表顺序）里第一个按 int8 估算
/// 放得下的作为建议。
AsrInsufficientMemoryException? asrMemoryGateVerdict({
  required AsrModelPack pack,
  required AsrEncoderVariant variant,
  required DeviceMemorySnapshot memory,
  required List<AsrModelPack> alternatives,
}) {
  final int needed = estimateAsrPeakMemoryBytes(pack, variant);
  final int headroom = asrMemoryHeadroomBytes(memory);
  if (needed <= headroom) return null;
  String? suggested;
  for (final AsrModelPack candidate in alternatives) {
    if (candidate.id == pack.id) continue;
    if (estimateAsrPeakMemoryBytes(candidate, AsrEncoderVariant.int8) <=
        headroom) {
      suggested = candidate.displayName;
      break;
    }
  }
  return AsrInsufficientMemoryException(
    modelName: pack.displayName,
    requiredBytes: needed,
    headroomBytes: headroom,
    memory: memory,
    suggestedModelName: suggested,
  );
}

/// 纯函数：从 `/proc/meminfo`（或 `/proc/self/status`）文本里取某个 kB 字段的
/// 字节数。
int? parseProcMeminfoBytes(String content, String field) {
  final RegExp pattern = RegExp(
    '^${RegExp.escape(field)}:\\s+(\\d+)\\s*kB',
    multiLine: true,
  );
  final Match? m = pattern.firstMatch(content);
  final int? kb = m == null ? null : int.tryParse(m.group(1)!);
  return kb == null ? null : kb * 1024;
}

/// 纯函数：从 `/proc/self/status` 文本里取 `VmRSS`（字节）。
int? parseProcStatusRssBytes(String content) =>
    parseProcMeminfoBytes(content, 'VmRSS');

/// 读本机内存状况。只在 Android 上返回值（拍板范围）；其它平台返回 null =
/// 不设门槛。
///
/// `/proc/meminfo` 与 `/proc/self/status` 对 app 进程恒可读；真读不到（文件系统
/// 异常、字段缺失）时同样返回 null 并打日志——没有数据就没法判，照旧开跑而不是
/// 凭空拦人，但原因留在日志里。
DeviceMemorySnapshot? readAndroidMemorySnapshot() {
  if (!Platform.isAndroid) return null;
  try {
    final String meminfo = File('/proc/meminfo').readAsStringSync();
    final String status = File('/proc/self/status').readAsStringSync();
    final int? total = parseProcMeminfoBytes(meminfo, 'MemTotal');
    final int? rss = parseProcStatusRssBytes(status);
    if (total == null || rss == null) {
      debugPrint(
        '[Fushi] ASR memory gate: MemTotal/VmRSS missing; gate skipped',
      );
      return null;
    }
    return DeviceMemorySnapshot(
      totalBytes: total,
      availableBytes: parseProcMeminfoBytes(meminfo, 'MemAvailable'),
      processRssBytes: rss,
    );
  } on FileSystemException catch (error) {
    debugPrint('[Fushi] ASR memory gate: cannot read /proc ($error)');
    return null;
  }
}

/// 带内存门槛的转录服务：`start` 之前先过 [asrMemoryGateVerdict]。
///
/// 门槛放在 `start` 上而不是各个入口：转录弹层、有声书自动转录队列、视频字幕、
/// 控制通道、TTS 回校全都经 `createAsrTranscriptionService` 拿到这个服务、再调
/// `start`，一处拦住所有入口，不会出现「弹层拦了、后台队列照样被杀」。
class MemoryGatedAsrTranscriptionService extends AsrTranscriptionService {
  MemoryGatedAsrTranscriptionService({
    required super.backend,
    required super.audioProfile,
    super.loader,
    super.pcm,
    super.openStore,
    super.jobsRoot,
    DeviceMemorySnapshot? Function() memoryProbe = readAndroidMemorySnapshot,
  }) : _memoryProbe = memoryProbe;

  final DeviceMemorySnapshot? Function() _memoryProbe;

  /// 按当前注册表判这门语言在本素材上用 [variant] 跑不跑得动；跑不动抛
  /// [AsrInsufficientMemoryException]。
  void ensureMemoryFor(AsrLanguage language, AsrEncoderVariant variant) {
    final DeviceMemorySnapshot? memory = _memoryProbe();
    if (memory == null) return;
    final AsrModelPack pack = asrModelPackFor(language, profile: audioProfile);
    final AsrInsufficientMemoryException? failure = asrMemoryGateVerdict(
      pack: pack,
      variant: variant,
      memory: memory,
      alternatives: <AsrModelPack>[
        for (final AsrModelPack candidate in asrModelRegistry.packs)
          if (candidate.languages.contains(language) &&
              candidate.servesProfile(audioProfile))
            candidate,
      ],
    );
    if (failure == null) return;
    debugPrint(
      '[Fushi] ASR memory gate refused ${pack.id}: need '
      '${failure.requiredBytes}, headroom ${failure.headroomBytes}, $memory',
    );
    throw failure;
  }

  @override
  Future<AsrRunningTranscription> start({
    required List<String> audioPaths,
    required AsrLanguage language,
    required AsrEncoderVariant variant,
    required AsrAccelerationPreference preference,
    List<AsrSegmentSpan>? segments,
  }) async {
    ensureMemoryFor(language, variant);
    return super.start(
      audioPaths: audioPaths,
      language: language,
      variant: variant,
      preference: preference,
      segments: segments,
    );
  }
}
