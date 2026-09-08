/// `asr_core` 的 ffmpeg 接口 → 本仓 [FfmpegBackend] 的转接（五端一律注入本仓后端：
/// 包自带的裸 CLI 后端会丢掉子进程登记表、`FUSHI_FFMPEG` 覆盖与捆绑损坏回退）。
///
/// 从 app 的 `asr_host.dart` 平移到引擎：无头服务端的 ASR 任务与 app 共用。
/// 三条穿透契约：`run` 的 output 是 **stderr**、`runProbe` 是 **stdout**；超时 =
/// `returnCode == null` 而非抛异常；可执行缺失 = 抛 `ProcessException`。
library;

import 'package:asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart' as host_ffmpeg;

class FushiAsrFfmpegBackend implements asr.FfmpegBackend {
  const FushiAsrFfmpegBackend();

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

  static asr.FfmpegRunResult _convert(host_ffmpeg.FfmpegRunResult r) =>
      asr.FfmpegRunResult(
        returnCode: r.returnCode,
        output: r.output,
        executable: r.executable,
        attemptedExecutables: r.attemptedExecutables,
        fallbackReason: r.fallbackReason,
      );
}
