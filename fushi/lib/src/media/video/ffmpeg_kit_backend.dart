/// Android / iOS 的进程内 ffmpeg 后端（ffmpeg-kit 插件实现）。
///
/// 从引擎的 `ffmpeg_backend.dart` 拆出：引擎不能依赖 Flutter 插件，抽象
/// [FfmpegBackend] + 桌面 CLI 后端留在引擎，这个插件实现留在 app，由
/// `installEngineHostBindings()` 经 `ffmpegPlatformBackendProvider` 装进去。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:ffmpeg_kit_flutter/session.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';

/// 会话收尾（取消 / 读退出码 / 读日志）各自的独立上限。
///
/// 这三步都是 method channel 往返，不属于「ffmpeg 跑多久」的预算，但同样可能
/// 不回包（见 [KitFfmpegBackend] 类注释里的 BUG-2542）。给它们一个**与主预算
/// 无关的**小上限：拿不到就当拿不到，绝不让收尾把已经判定的结果拖成挂死。
const Duration _kKitSessionEpilogueTimeout = Duration(seconds: 10);

/// 启动 ffmpeg-kit 会话（init + createSession + asyncExecute 三次往返）的上限。
///
/// 与主预算取较小值：跑 8 分钟的合成不该容忍 8 分钟的**启动**。
const Duration _kKitSessionStartTimeout = Duration(seconds: 30);

/// 无界 await 收敛后的阶段标记，写进 [FfmpegRunResult.output]，让错误日志页能
/// 区分「启动没回包」/「ffmpeg 真跑超时」/「收尾没回包」——三者在用户眼里都是
/// 「点了没反应」，但修法完全不同。
@visibleForTesting
enum KitSessionPhase {
  start('start (init/createSession/asyncExecute did not return)'),
  execute('execute (ffmpeg session did not complete in time)'),
  epilogue('epilogue (getReturnCode/getOutput did not return)');

  const KitSessionPhase(this.detail);

  final String detail;
}

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
/// [Completer]，`.timeout` 等到会话结束后再读 [Session.getReturnCode] /
/// [Session.getOutput]（= 合并日志，喂 `parseSubtitleStreamsFromFfmpegLog`）；
/// 超时只精确取消**本次** session（`FFmpegKit.cancel(session.getSessionId())`），绝不碰并发
/// 会话——曾用无参 `FFmpegKit.cancel()` 取消全部会话，误杀并发字幕抽取/制卡任务，表现为
/// 偶发丢内封字幕（BUG-905）。
///
/// **每一次 method channel 往返都在时间预算内（BUG-2542）**：`run` / `runProbe`
/// 曾把 `.timeout()` 只套在完成回调的 [Completer] 上，而启动（`executeWithArgumentsAsync`
/// 内含 init/createSession/asyncExecute 三次往返）、超时分支里的 `cancel`、以及
/// 收尾的 `getReturnCode` / `getOutput` 全是**裸 await**。任一不回包，`run()` 就
/// 永不返回；调用方（片段导出、制卡、字幕抽取）的「进行中」标志随之永久为真，
/// 此后每次点击都撞在防重入门上——用户看到的就是「点了没反应，连失败提示都没有」。
/// 桌面 CLI 后端不受影响（子进程有独立超时），所以这是移动端专属的挂死面。
/// 收敛后每一步都有上限，超时一律返回 `returnCode: null` 的失败结果，并在
/// [FfmpegRunResult.output] 里写明卡在哪个阶段。
class KitFfmpegBackend implements FfmpegBackend {
  const KitFfmpegBackend();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) {
    return runKitFfmpegSession(
      timeout: timeout,
      executable: 'ffmpeg-kit',
      start: (void Function() onComplete) =>
          FFmpegKit.executeWithArgumentsAsync(args, (_) => onComplete()),
    );
  }

  /// 移动端 ffprobe：进程内 `FFprobeKit.executeWithArgumentsAsync`，
  /// `session.getOutput()` 拿 ffprobe 的 JSON 报告（喂
  /// `parseAudioMetadataFromFfprobeJson`）。与 [run] 同款超时/cancel 语义。
  /// TODO-1045：移动端也能读 M4B 容器 tag（方案 A 的关键假设）。
  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) {
    return runKitFfmpegSession(
      timeout: timeout,
      executable: 'ffprobe-kit',
      start: (void Function() onComplete) =>
          FFprobeKit.executeWithArgumentsAsync(args, (_) => onComplete()),
    );
  }
}

/// [KitFfmpegBackend.run] 与 [KitFfmpegBackend.runProbe] 的公共会话驱动。
///
/// 两者只差「用哪个 Kit 启动」（`FFmpegKit` / `FFprobeKit` 的 complete callback
/// 类型不同，无法直接共用函数指针），故由调用方传 [start] 闭包；启动、等待、
/// 取消、读结果四段的超时语义完全一致，收在这里一处，避免两份同构代码再次
/// 各自漏掉某一步的上限。
///
/// [start] / [cancelSession] 是注入点：生产走 `FFmpegKit` / `FFprobeKit` 与
/// `FFmpegKit.cancel`，测试注入「永不回包」的假件来复现三个挂死阶段——ffmpeg-kit
/// 的真 method channel 住在 platform-interface 包里，mock 它并不比注入更真实，
/// 而这一层恰好就是超时语义的所在处。
@visibleForTesting
Future<FfmpegRunResult> runKitFfmpegSession({
  required Future<Session> Function(void Function() onComplete) start,
  required Duration timeout,
  required String executable,
  Future<void> Function(int sessionId) cancelSession = FFmpegKit.cancel,
  Duration epilogueTimeout = _kKitSessionEpilogueTimeout,
  Duration startTimeout = _kKitSessionStartTimeout,
}) async {
  final Completer<void> done = Completer<void>();
  final Session session;
  try {
    // 启动本身也可能不回包（native loader 卡死 / ABI 不匹配 / 插件未注册）。
    // 取 min(主预算, 30s)：主预算是给 ffmpeg **跑**的，不该被启动吃掉。
    session = await start(() {
      if (!done.isCompleted) done.complete();
    }).timeout(timeout < startTimeout ? timeout : startTimeout);
  } on TimeoutException {
    // 拿不到 session 就没有 sessionId，无法精确取消；宁可让这次会话在 native
    // 侧自生自灭，也不用无参 cancel() 误杀并发会话（BUG-905）。
    return _kitTimeoutResult(executable, KitSessionPhase.start);
  }

  try {
    await done.future.timeout(timeout);
  } on TimeoutException {
    final int? sessionId = session.getSessionId();
    if (sessionId != null) {
      try {
        // 取消也是 method channel 往返：不加上限，超时机制就会被它自己要取消
        // 的东西挂住。取消失败不改变结论（这次会话已判超时）。
        await cancelSession(sessionId).timeout(epilogueTimeout);
      } on TimeoutException {
        // 落进下面的统一超时结果，阶段仍记 execute：真因是会话没跑完。
      }
    }
    return _kitTimeoutResult(executable, KitSessionPhase.execute);
  }

  // 会话已完成，读退出码与合并日志。这两步再挂住就只能当结果拿不到——但绝不
  // 能因此让 run() 永不返回。
  try {
    final ReturnCode? rc =
        await session.getReturnCode().timeout(epilogueTimeout);
    final String output =
        (await session.getOutput().timeout(epilogueTimeout)) ?? '';
    return FfmpegRunResult(
      returnCode: rc?.getValue(),
      output: output,
      executable: executable,
      attemptedExecutables: <String>[executable],
    );
  } on TimeoutException {
    return _kitTimeoutResult(executable, KitSessionPhase.epilogue);
  }
}

/// 统一的超时失败结果。`returnCode: null` 与既有契约一致（`isSuccess == false`，
/// `failureSummary` 里显示为 timed out），[FfmpegRunResult.output] 带上阶段标记：
/// 旧实现恒返回空串，等于把「卡在哪」这唯一有用的线索也抹掉了。
FfmpegRunResult _kitTimeoutResult(String executable, KitSessionPhase phase) {
  return FfmpegRunResult(
    returnCode: null,
    output: '$executable timed out in ${phase.detail}',
    executable: executable,
    attemptedExecutables: <String>[executable],
  );
}
