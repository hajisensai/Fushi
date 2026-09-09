/// `asr_core` 的 ffmpeg 接口 → 本仓 [FfmpegBackend] 的转接（五端一律注入本仓后端：
/// 包自带的裸 CLI 后端会丢掉子进程登记表、`FUSHI_FFMPEG` 覆盖与捆绑损坏回退）。
///
/// 从 app 的 `asr_host.dart` 平移到引擎：无头服务端的 ASR 任务与 app 共用。
/// 三条穿透契约：`run` 的 output 是 **stderr**、`runProbe` 是 **stdout**；超时 =
/// `returnCode == null` 而非抛异常；可执行缺失 = 抛 `ProcessException`。
library;

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart' as host_ffmpeg;

class FushiAsrFfmpegBackend implements asr.FfmpegBackend {
  const FushiAsrFfmpegBackend();

  /// 每次取用时解析，不在构造时固化。
  ///
  /// 本仓的 `resolveFfmpegBackend()` 有进程级缓存，而
  /// `setFfmpegBackendForTesting()` 会把它换掉——构造时固化会让测试替换失效。
  host_ffmpeg.FfmpegBackend get _backend => host_ffmpeg.resolveFfmpegBackend();

  @override
  Future<asr.FfmpegRunResult> run(List<String> args, Duration timeout) async =>
      _convert(await _backend.run(args, timeout));

  @override
  Future<asr.FfmpegRunResult> runProbe(
    List<String> args,
    Duration timeout,
  ) async =>
      _convert(await _backend.runProbe(args, timeout));

  /// 逐字段转，不做任何解释。
  ///
  /// 三条契约必须原样穿过去，错一条都很难发现：
  /// - `run` 的 `output` 是 **stderr**、`runProbe` 的是 **stdout**（前者用来认
  ///   「没有 s16le muxer」，后者是 ffprobe 的 JSON）；颠倒了会变成「能转录但
  ///   每次都慢一档」；
  /// - 超时是 `returnCode == null`，**不是**抛 `TimeoutException`；
  /// - 可执行文件缺失是抛 `ProcessException`，**不是**返回失败结果。
  ///   后两条本方法不碰（异常直接穿透、null 原样带过），这里只是把这条纪律写下来。
  static asr.FfmpegRunResult _convert(host_ffmpeg.FfmpegRunResult r) =>
      asr.FfmpegRunResult(
        returnCode: r.returnCode,
        output: r.output,
        executable: r.executable,
        attemptedExecutables: r.attemptedExecutables,
        fallbackReason: r.fallbackReason,
      );
}
