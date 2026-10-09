/// 「读完整个容器」类 ffmpeg 长任务的观察式运行：按**进度**判活，而不是给一个总时长。
///
/// 为什么不用 [FfmpegBackend.run] 的固定超时（BUG-3102）：整轨 `-c copy` 抽字幕要把
/// 整个容器读一遍，耗时只取决于磁盘吞吐——同一个 30 GB 的 REMUX 在 NVMe 上十几秒、
/// 在 USB 机械盘 / NAS 上、或同时有 libmpv 播放和别的 ffmpeg 在抢 IO 时可以是十几分钟。
/// 「按体积估一个总预算」（旧实现 60 s + 8 s/GB，隐含 ≥125 MB/s 的吞吐假设）在慢盘上
/// 必然误杀一个**一直在推进**的进程；把预算放大又会让真正卡死的进程挂很久。正确的判据
/// 是：ffmpeg 报告的已处理媒体时间（`-progress` 的 `out_time_us`）在 [FfmpegWatch.stallTimeout]
/// 内没有任何推进，才算卡死。
///
/// 调用方要让进度在整个文件里连续推进：只映射稀疏的字幕流时，`out_time_us` 只在字幕
/// 包处跳一下（长段无对白就几分钟不动）。见 `graphic_subtitle_track_ocr.dart` 的做法：
/// 同一次读文件里再加一个 `-f null` 输出拷贝视频包，进度就跟随文件读取位置。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:meta/meta.dart';

/// 观察式运行的参数。
class FfmpegWatch {
  const FfmpegWatch({required this.stallTimeout, this.onProgress, this.cancel});

  /// 已处理媒体时间连续这么久没有推进 → 判卡死、强杀。
  final Duration stallTimeout;

  /// 已处理到的媒体时间（单调不减，只在推进时回调）。
  final void Function(Duration processed)? onProgress;

  /// 完成即取消：强杀进程，结果 `returnCode: null`。
  final Future<void>? cancel;
}

/// 支持观察式运行的后端（桌面 CLI / 移动端 ffmpeg-kit）。不支持的后端（测试替身等）
/// 由调用方退回 [FfmpegBackend.run]。与 `client is MediaServerBrowser` 同一判能力范式。
abstract interface class FfmpegWatchedRunner {
  /// 跑一次 ffmpeg（[args] 不含进度参数，由实现自行加）。卡死 / 取消返回
  /// `returnCode: null`，[FfmpegRunResult.output] 里写明原因。
  Future<FfmpegRunResult> runWatched(List<String> args, FfmpegWatch watch);
}

/// 卡死时写进 [FfmpegRunResult.output] 的标记（错误日志里区分「卡死」与「被取消」）。
String ffmpegStallMarker(Duration stallTimeout) =>
    'ffmpeg made no progress for ${stallTimeout.inSeconds}s (stalled)';

/// 被取消时写进 [FfmpegRunResult.output] 的标记。
const String kFfmpegCancelledMarker = 'ffmpeg cancelled';

/// CLI 观察式运行前置的参数：`-nostdin`（不碰继承来的 stdin）+ 把机器可读进度写到
/// stdout + 关掉 stderr 上的人类可读进度行（stderr 只留真错误，喂失败摘要）。
const List<String> kFfmpegWatchedCliPrefix = <String>[
  '-nostdin',
  '-progress',
  'pipe:1',
  '-nostats',
];

/// 解析 `-progress` 输出的一行，返回已处理媒体时间；不是时间行 / 值无效（ffmpeg 在
/// 还没有输出包时写 `N/A`）返回 null。
///
/// 只认 `out_time_us`：`out_time_ms` 是 ffmpeg 的历史命名错误（值其实也是微秒），
/// `out_time` 是 `HH:MM:SS.micro` 文本，三者同源，认一个就够。
Duration? parseFfmpegProgressLine(String line) {
  const String key = 'out_time_us=';
  final String trimmed = line.trim();
  if (!trimmed.startsWith(key)) return null;
  final int? us = int.tryParse(trimmed.substring(key.length));
  if (us == null || us < 0) return null;
  return Duration(microseconds: us);
}

/// 观察一个**已经起来**的 ffmpeg 进程直到它结束 / 卡死 / 被取消。
///
/// stdout 按行喂 [parseFfmpegProgressLine]；stderr 收集作失败摘要。卡死判据见文件头。
/// 卡死与取消都 SIGKILL 并**等进程真正退出**再返回（调用方随后要删临时目录，Windows
/// 上进程还活着就删不掉它打开的输出文件）。[clock] / [checkInterval] 供测试注入。
@visibleForTesting
Future<FfmpegRunResult> watchFfmpegProcess(
  Process process,
  FfmpegWatch watch, {
  required String executable,
  DateTime Function() clock = DateTime.now,
  Duration? checkInterval,
}) async {
  Duration processed = Duration.zero;
  DateTime lastAdvance = clock();
  String? abortReason;

  final Future<String> stderrText = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final Future<void> stdoutDone = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .forEach((String line) {
        final Duration? at = parseFfmpegProgressLine(line);
        if (at == null || at <= processed) return;
        processed = at;
        lastAdvance = clock();
        watch.onProgress?.call(at);
      });

  void abort(String reason) {
    if (abortReason != null) return;
    abortReason = reason;
    process.kill(ProcessSignal.sigkill);
  }

  final Duration interval =
      checkInterval ??
      Duration(
        milliseconds: (watch.stallTimeout.inMilliseconds ~/ 4).clamp(50, 1000),
      );
  final Timer watchdog = Timer.periodic(interval, (_) {
    if (clock().difference(lastAdvance) >= watch.stallTimeout) {
      abort(ffmpegStallMarker(watch.stallTimeout));
    }
  });
  unawaited(watch.cancel?.then((_) => abort(kFfmpegCancelledMarker)));

  try {
    final int code = await process.exitCode;
    await stdoutDone;
    final String err = await stderrText;
    final String? reason = abortReason;
    return FfmpegRunResult(
      returnCode: reason == null ? code : null,
      output: reason == null ? err : '$reason\n$err'.trimRight(),
      executable: executable,
      attemptedExecutables: <String>[executable],
    );
  } finally {
    watchdog.cancel();
  }
}

/// 起一个 ffmpeg 进程并 [watchFfmpegProcess]。可执行不存在时 `Process.start` 抛
/// [ProcessException]，向上传播（与 `runFfmpegProcess` 同契约，捆绑 → PATH 回退靠它）。
Future<FfmpegRunResult> runFfmpegWatchedProcess(
  String executable,
  List<String> args,
  FfmpegWatch watch,
) async {
  final Process process = await HelperProcessRegistry.instance.start(
    executable,
    <String>[...kFfmpegWatchedCliPrefix, ...args],
  );
  return watchFfmpegProcess(process, watch, executable: executable);
}
