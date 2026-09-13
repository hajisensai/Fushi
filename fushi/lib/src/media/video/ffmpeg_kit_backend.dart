/// Android / iOS 的进程内 ffmpeg 后端（ffmpeg-kit 插件实现）。
///
/// 从引擎的 `ffmpeg_backend.dart` 拆出：引擎不能依赖 Flutter 插件，抽象
/// [FfmpegBackend] + 桌面 CLI 后端留在引擎，这个插件实现留在 app，由
/// `installEngineHostBindings()` 经 `ffmpegPlatformBackendProvider` 装进去。
library;

import 'dart:async';

import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';

/// 移动端（Android/iOS）后端：进程内调用「自编」的 ffmpeg-kit（arthenica 源码 +
/// NDK r25 重编的最小变体；TODO-2357 起带 `--enable-gpl --enable-x264`，产物许可为
/// GPLv3，与 Hibiki 自身一致），经其 `package:ffmpeg_kit_flutter` API 跑
/// 同一套 ffmpeg 命令。替代崩溃的第三方预编译 ffmpeg-kit 变体（其
/// `libffmpegkit_abidetect.so` 在 Android 16/API36 JNI_OnLoad 返回非法版本，启动即崩，
/// BUG-122）。自编 AAR vendored 在 third_party/ffmpeg_kit_flutter/android/libs。
///
/// 与 [CliFfmpegBackend] **同契约**（args→退出码+合并日志），5 个 extract 函数 +
/// （替代的崩溃包是第三方预编译 ffmpeg-kit 变体，见 BUG-122）。
/// 字幕枚举零改动。异步启动 `executeWithArgumentsAsync`（立即返回 session），完成回调喂
/// [Completer]，`.timeout` 等到会话结束后再读 [FFmpegSession.getReturnCode] /
/// [FFmpegSession.getOutput]（= 合并日志，喂 `parseSubtitleStreamsFromFfmpegLog`）；
/// 超时只精确取消**本次** session（`FFmpegKit.cancel(session.getSessionId())`），绝不碰并发
/// 会话——曾用无参 `FFmpegKit.cancel()` 取消全部会话，误杀并发字幕抽取/制卡任务，表现为
/// 偶发丢内封字幕（BUG-905）。
class KitFfmpegBackend implements FfmpegBackend {
  const KitFfmpegBackend();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    // 异步启动：立即拿到本次 session，超时才能精确取消它而不误杀并发会话（BUG-905）。
    final Completer<void> done = Completer<void>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (_) {
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      final int? sessionId = session.getSessionId();
      if (sessionId != null) {
        await FFmpegKit.cancel(sessionId);
      }
      return const FfmpegRunResult(
        returnCode: null,
        output: '',
        executable: 'ffmpeg-kit',
        attemptedExecutables: <String>['ffmpeg-kit'],
      );
    }
    final ReturnCode? rc = await session.getReturnCode();
    final String output = (await session.getOutput()) ?? '';
    return FfmpegRunResult(
      returnCode: rc?.getValue(),
      output: output,
      executable: 'ffmpeg-kit',
      attemptedExecutables: const <String>['ffmpeg-kit'],
    );
  }

  /// 移动端 ffprobe：进程内 `FFprobeKit.executeWithArguments`，`session.getOutput()`
  /// 拿 ffprobe 的 JSON 报告（喂 `parseAudioMetadataFromFfprobeJson`）。与 [run] 同款
  /// 超时/cancel 语义。TODO-1045：移动端也能读 M4B 容器 tag（方案 A 的关键假设）。
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async {
    // 与 [run] 同款异步启动 + 精确取消语义（BUG-905）。
    final Completer<void> done = Completer<void>();
    final session = await FFprobeKit.executeWithArgumentsAsync(
      args,
      (_) {
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      final int? sessionId = session.getSessionId();
      if (sessionId != null) {
        await FFmpegKit.cancel(sessionId);
      }
      return const FfmpegRunResult(
        returnCode: null,
        output: '',
        executable: 'ffprobe-kit',
        attemptedExecutables: <String>['ffprobe-kit'],
      );
    }
    final ReturnCode? rc = await session.getReturnCode();
    final String output = (await session.getOutput()) ?? '';
    return FfmpegRunResult(
      returnCode: rc?.getValue(),
      output: output,
      executable: 'ffprobe-kit',
      attemptedExecutables: const <String>['ffprobe-kit'],
    );
  }
}
