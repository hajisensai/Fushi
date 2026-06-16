import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:flutter/foundation.dart';

/// 一次 ffmpeg 执行的结果。
///
/// [returnCode] 为 null 表示超时被强杀；[output] 是合并的 stderr 文本
/// （ffmpeg 把流信息/进度写 stderr），内嵌字幕「列举」靠解析它。
class FfmpegRunResult {
  const FfmpegRunResult({
    required this.returnCode,
    required this.output,
    this.executable,
    this.attemptedExecutables = const <String>[],
    this.fallbackReason,
  });

  final int? returnCode;
  final String output;
  final String? executable;
  final List<String> attemptedExecutables;
  final String? fallbackReason;

  bool get isSuccess => returnCode == 0;

  String get failureSummary {
    final List<String> parts = <String>[_formatFfmpegReturnCode(returnCode)];
    if (executable != null && executable!.isNotEmpty) {
      parts.add('executable=$executable');
    }
    if (attemptedExecutables.isNotEmpty) {
      parts.add('attempted=${attemptedExecutables.join(' -> ')}');
    }
    if (fallbackReason != null && fallbackReason!.isNotEmpty) {
      parts.add('fallback=$fallbackReason');
    }
    final String stderr = _summarizeFfmpegOutput(output);
    if (stderr.isNotEmpty) {
      parts.add('stderr=$stderr');
    }
    return parts.join('; ');
  }

  FfmpegRunResult withExecutionContext({
    required String executable,
    required List<String> attemptedExecutables,
    String? fallbackReason,
  }) {
    return FfmpegRunResult(
      returnCode: returnCode,
      output: output,
      executable: executable,
      attemptedExecutables: List<String>.unmodifiable(attemptedExecutables),
      fallbackReason: fallbackReason ?? this.fallbackReason,
    );
  }
}

typedef FfmpegProcessRunner = Future<FfmpegRunResult> Function(
  String executable,
  List<String> args,
  Duration timeout,
);

const int _windowsStatusInvalidImageFormatSigned = -1073741701;
const int _windowsStatusInvalidImageFormatUnsigned = 0xC000007B;

String _formatFfmpegReturnCode(int? returnCode) {
  if (returnCode == null) return 'ffmpeg timed out';
  if (returnCode == _windowsStatusInvalidImageFormatSigned ||
      returnCode == _windowsStatusInvalidImageFormatUnsigned) {
    return 'ffmpeg exit $returnCode '
        '(Windows STATUS_INVALID_IMAGE_FORMAT / 0xC000007B)';
  }
  return 'ffmpeg exit $returnCode';
}

String _summarizeFfmpegOutput(String output) {
  final String oneLine = output.trim().replaceAll(RegExp(r'\s+'), ' ');
  const int maxLength = 500;
  if (oneLine.length <= maxLength) return oneLine;
  return '${oneLine.substring(0, maxLength)}...';
}

String describeFfmpegProcessException(ProcessException exception) {
  final StringBuffer buffer = StringBuffer('ffmpeg launch failed');
  if (exception.executable.isNotEmpty) {
    buffer.write(': executable=${exception.executable}');
  }
  if (exception.errorCode != 0) {
    buffer.write('; errorCode=${exception.errorCode}');
  }
  if (exception.message.isNotEmpty) {
    buffer.write('; message=${exception.message}');
  }
  return buffer.toString();
}

ProcessException _withFfmpegLaunchContext(
  ProcessException exception, {
  required List<String> attemptedExecutables,
  String? fallbackReason,
}) {
  final List<String> parts = <String>[];
  if (exception.message.isNotEmpty) {
    parts.add(exception.message);
  }
  if (attemptedExecutables.isNotEmpty) {
    parts.add('attempted=${attemptedExecutables.join(' -> ')}');
  }
  if (fallbackReason != null && fallbackReason.isNotEmpty) {
    parts.add('fallback=$fallbackReason');
  }
  return ProcessException(
    exception.executable,
    exception.arguments,
    parts.join('; '),
    exception.errorCode,
  );
}

/// ffmpeg 执行底座抽象：所有 ffmpeg 调用经它，与「系统 CLI / 捆绑库」实现解耦。
///
/// 只有一个原语 [run]——跑一次 ffmpeg，返回退出码 + stderr 文本：
/// - 5 个 extract 函数（音/视频封面、视频帧、字幕抽取、音频裁剪）只看
///   [FfmpegRunResult.returnCode] 与产出文件。
/// - 内嵌字幕「列举」用 `run(['-hide_banner','-i',path])` 拿 [FfmpegRunResult.output]
///   喂 `parseSubtitleStreamsFromFfmpegLog`，无需独立 probe API（两后端通用）。
///
/// 实现：桌面 [CliFfmpegBackend]（系统/捆绑 ffmpeg CLI）、移动端 [KitFfmpegBackend]
/// （进程内自编 ffmpeg-kit）。经 [resolveFfmpegBackend] 按平台分流。
abstract class FfmpegBackend {
  Future<FfmpegRunResult> run(List<String> args, Duration timeout);
}

/// 解析 ffmpeg 可执行文件（桌面 [CliFfmpegBackend] 用）。优先级：
/// 1. `HIBIKI_FFMPEG`（绝对路径，显式覆盖，开发/特殊部署）；
/// 2. **app 程序旁捆绑的 `ffmpeg(.exe)`**（打包时塞进各桌面产物 → 开箱即用，不依赖
///    用户自己装 ffmpeg；否则没装 ffmpeg 的电脑会丢内封字幕/cue 动图/制卡音频）；
/// 3. 回退系统 PATH 上的 `ffmpeg`。
String resolveFfmpegExecutable() => resolveFfmpegExecutableFrom(
      override: Platform.environment['HIBIKI_FFMPEG'],
      bundledPath: _bundledFfmpegPath(),
    );

/// 纯函数：按「覆盖 > 捆绑 > PATH」决定 ffmpeg 可执行（便于单测优先级）。
String resolveFfmpegExecutableFrom({
  required String? override,
  required String? bundledPath,
}) {
  final String? o = override?.trim();
  if (o != null && o.isNotEmpty) return o;
  if (bundledPath != null && bundledPath.isNotEmpty) return bundledPath;
  return 'ffmpeg';
}

/// app 可执行文件同目录下的捆绑 ffmpeg 路径（存在才返回，否则 null）。
///
/// Windows 找 `ffmpeg.exe`，其余找 `ffmpeg`。`Platform.resolvedExecutable` 是
/// 本进程的可执行文件：Windows `…\Hibiki\hibiki.exe` → 找 `…\Hibiki\ffmpeg.exe`；
/// macOS `Hibiki.app/Contents/MacOS/Hibiki` → 找同目录 `ffmpeg`；Linux 同理。
/// 任何异常（沙箱/只读/解析失败）静默返回 null，回退 PATH。
String? _bundledFfmpegPath() {
  try {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final File candidate = File('$exeDir${Platform.pathSeparator}$name');
    if (candidate.existsSync()) return candidate.path;
  } catch (_) {}
  return null;
}

/// 共享：跑一次指定可执行文件的 ffmpeg，返回退出码 + stderr 文本。两后端（CLI/FFI
/// 回退）共用，杜绝重复 drain/超时逻辑。
///
/// 语义复刻原 `_runFfmpeg`：drain stdout 防管道死锁、收集 stderr 作 output、
/// `exitCode.timeout` 超时则 SIGKILL 返回 `returnCode:null`。可执行文件不存在时
/// `Process.start` 抛 [ProcessException]，**向上传播**（各调用方自行 catch，沿用旧契约）。
/// stderr 用宽容 UTF-8 解码（`allowMalformed`），绝不因个别非法字节抛错。
Future<FfmpegRunResult> runFfmpegProcess(
  String executable,
  List<String> args,
  Duration timeout,
) async {
  final Process process = await Process.start(executable, args);
  // Drain both pipes: a full OS pipe buffer (ffmpeg writes progress to stderr)
  // would otherwise deadlock the process before it can exit.
  unawaited(process.stdout.drain<void>());
  final Future<String> stderrText =
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  try {
    final int code = await process.exitCode.timeout(timeout);
    final String output = await stderrText;
    return FfmpegRunResult(
      returnCode: code,
      output: output,
      executable: executable,
      attemptedExecutables: <String>[executable],
    );
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return FfmpegRunResult(
      returnCode: null,
      output: '',
      executable: executable,
      attemptedExecutables: <String>[executable],
    );
  }
}

bool _isWindowsInvalidImageFormatExitCode(
  int? returnCode, {
  required bool isWindows,
}) {
  if (!isWindows || returnCode == null) return false;
  return returnCode == _windowsStatusInvalidImageFormatSigned ||
      returnCode == _windowsStatusInvalidImageFormatUnsigned;
}

/// 判断 bundled ffmpeg 的执行结果是否「跑起来了但根本没产出 ffmpeg 的工作输出」
/// ——即「文件存在却无法真正初始化为 ffmpeg」，应回退 PATH（BUG-283）。
///
/// 背景（续 BUG-275）：BUG-275 修了 bundled `Process.start` 阶段抛 ProcessException
/// 的回退，但还有一类损坏让 `Process.start` **成功**、进程真的起来、随后才在加载期
/// 崩掉——典型是 STATUS_DLL_NOT_FOUND(0xC0000135) / STATUS_ENTRYPOINT_NOT_FOUND
/// (0xC0000139)：bundled ffmpeg.exe 本体没坏，但它依赖的 avcodec/avformat 等 DLL 被
/// 杀软隔离或漏打包。此时退出码不是 BUG-275 认的 STATUS_INVALID_IMAGE_FORMAT，
/// 旧逻辑直接把这条空结果原样返回，从不回退 PATH → 字幕枚举拿到空 stderr → 解析出
/// 零条轨 → **无异常、无回退、静默无内封字幕**（用户报「读取不到内封字幕了」）。
///
/// 不死盯具体退出码（不同损坏方式码各异），改用一个稳健的语义信号：**一个真正能跑
/// 的 ffmpeg，无论退出码是否为 0，都会往 stderr 写东西**（banner / version /
/// `-i` 的流信息 / 真错误）。所以「退出码非 0、非超时（null）、且 stderr 完全为空」
/// 就是「这个二进制没真正运行起来」的标志，唯一正确处置是回退 PATH 的 ffmpeg。
///
/// 排除项（这些**不**回退，保持原契约）：
/// - `returnCode == null`（超时被 SIGKILL）：是慢 IO 而非坏二进制，回退会让用户再等
///   一遍同样慢的文件；调用方按超时降级。
/// - `returnCode == 0`（成功）：哪怕 stderr 恰好为空也是成功（如某些 extract 只写
///   输出文件、不写 stderr）。
/// - `output` 非空：ffmpeg 确实跑了（即便退出码非 0，如 `-i` 无输出文件恒非 0）。
bool _bundledProducedNoUsableOutput(FfmpegRunResult result) {
  final int? code = result.returnCode;
  if (code == null || code == 0) return false;
  return result.output.trim().isEmpty;
}

String _bundledFallbackReason(FfmpegRunResult result, bool isWindows) {
  if (_isWindowsInvalidImageFormatExitCode(
    result.returnCode,
    isWindows: isWindows,
  )) {
    return 'bundled ffmpeg produced STATUS_INVALID_IMAGE_FORMAT (0xC000007B)';
  }
  return 'bundled ffmpeg produced no usable output '
      '(returnCode=${result.returnCode})';
}

Future<FfmpegRunResult> _runCliFfmpeg({
  required String? override,
  required String? bundledPath,
  required bool isWindows,
  required List<String> args,
  required Duration timeout,
  required FfmpegProcessRunner runner,
}) async {
  final String? o = override?.trim();
  if (o != null && o.isNotEmpty) {
    final FfmpegRunResult result = await runner(o, args, timeout);
    return result.withExecutionContext(
      executable: o,
      attemptedExecutables: <String>[o],
    );
  }

  final String? bundled = bundledPath?.trim();
  if (bundled != null && bundled.isNotEmpty) {
    String? fallbackReason;
    try {
      final FfmpegRunResult bundledResult =
          (await runner(bundled, args, timeout)).withExecutionContext(
        executable: bundled,
        attemptedExecutables: <String>[bundled],
      );
      // 回退条件统一：① Windows STATUS_INVALID_IMAGE_FORMAT 退出码（BUG-275 实证的
      // 损坏 PE）② bundled 跑起来了但完全没产出 ffmpeg 工作输出（DLL 缺失等加载期崩，
      // BUG-283）——两者都意味着 bundled 这个文件无法真正当 ffmpeg 用，回退 PATH。
      // 其余结果（含 `-i` 恒非 0 但 stderr 满是流信息的正常枚举）原样返回。
      final bool fallBack = _isWindowsInvalidImageFormatExitCode(
            bundledResult.returnCode,
            isWindows: isWindows,
          ) ||
          _bundledProducedNoUsableOutput(bundledResult);
      if (!fallBack) {
        return bundledResult;
      }
      fallbackReason = _bundledFallbackReason(bundledResult, isWindows);
      debugPrint(
        '[hibiki-ffmpeg] bundled ffmpeg ran but produced no usable output '
        '(returnCode=${bundledResult.returnCode}); '
        'falling back to PATH ffmpeg: $bundled',
      );
    } on ProcessException catch (e) {
      // bundledPath 已通过 `_bundledFfmpegPath()` 的 `existsSync()`：文件在磁盘上
      // 却 `Process.start` 抛 ProcessException，意味着「找到了 bundled ffmpeg 但
      // 它跑不起来」——损坏 / 架构不匹配 / 无执行权限。这种损坏在 Windows 上的
      // errorCode 随损坏方式而异（实测 STATUS_INVALID_IMAGE_FORMAT 时退出码非 0，
      // 而彻底无效的 PE 在启动期抛 ProcessException，errorCode 可能是
      // ERROR_FILE_NOT_FOUND(2) / ERROR_BAD_EXE_FORMAT(193) /
      // ERROR_EXE_MACHINE_TYPE_MISMATCH(216) 等）。既然 bundled 这个文件确实存在
      // 却跑不起来，唯一正确处置就是回退到 PATH 上的 ffmpeg（app 拥有的安全网），
      // 而不是死盯单一错误码——否则字幕枚举 / 制卡音频会把真失败吞成「无字幕」。
      // 显式 HIBIKI_FFMPEG 覆盖走上面的分支、不进这里，旧契约不变（如实报错）。
      fallbackReason = 'bundled ffmpeg launch failed '
          '(errorCode=${e.errorCode}, message=${e.message})';
      debugPrint(
        '[hibiki-ffmpeg] bundled ffmpeg failed to launch '
        '(errorCode=${e.errorCode}); falling back to PATH ffmpeg: $bundled',
      );
    }
    final List<String> attempted = <String>[bundled, 'ffmpeg'];
    final FfmpegRunResult pathResult;
    try {
      pathResult = await runner('ffmpeg', args, timeout);
    } on ProcessException catch (e) {
      throw _withFfmpegLaunchContext(
        e,
        attemptedExecutables: attempted,
        fallbackReason: fallbackReason,
      );
    }
    return pathResult.withExecutionContext(
      executable: 'ffmpeg',
      attemptedExecutables: attempted,
      fallbackReason: fallbackReason,
    );
  }

  final FfmpegRunResult result = await runner('ffmpeg', args, timeout);
  return result.withExecutionContext(
    executable: 'ffmpeg',
    attemptedExecutables: <String>['ffmpeg'],
  );
}

@visibleForTesting
Future<FfmpegRunResult> runCliFfmpegForTesting({
  required String? override,
  required String? bundledPath,
  required bool isWindows,
  required List<String> args,
  required Duration timeout,
  required FfmpegProcessRunner runner,
}) =>
    _runCliFfmpeg(
      override: override,
      bundledPath: bundledPath,
      isWindows: isWindows,
      args: args,
      timeout: timeout,
      runner: runner,
    );

/// 系统 ffmpeg（`Process.start`）后端：桌面三端（Windows/macOS/Linux）。
/// 委托 [runFfmpegProcess]，可执行文件经 [resolveFfmpegExecutable] 解析（覆盖>捆绑>PATH）。
class CliFfmpegBackend implements FfmpegBackend {
  const CliFfmpegBackend();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) =>
      _runCliFfmpeg(
        override: Platform.environment['HIBIKI_FFMPEG'],
        bundledPath: _bundledFfmpegPath(),
        isWindows: Platform.isWindows,
        args: args,
        timeout: timeout,
        runner: runFfmpegProcess,
      );
}

/// 移动端（Android/iOS）后端：进程内调用「自编」的 ffmpeg-kit（arthenica 源码 +
/// NDK r25 重编的最小变体，无外部 GPL 库），经其 `package:ffmpeg_kit_flutter` API 跑
/// 同一套 ffmpeg 命令。替代崩溃的第三方预编译 ffmpeg-kit 变体（其
/// `libffmpegkit_abidetect.so` 在 Android 16/API36 JNI_OnLoad 返回非法版本，启动即崩，
/// BUG-122）。自编 AAR vendored 在 third_party/ffmpeg_kit_flutter/android/libs。
///
/// 与 [CliFfmpegBackend] **同契约**（args→退出码+合并日志），5 个 extract 函数 +
/// （替代的崩溃包是第三方预编译 ffmpeg-kit 变体，见 BUG-122）。
/// 字幕枚举零改动。`executeWithArguments` await 到会话结束，随后 [FFmpegSession.getReturnCode]
/// / [FFmpegSession.getOutput]（= 合并日志，喂 `parseSubtitleStreamsFromFfmpegLog`）就绪；
/// 超时用 `.timeout` + [FFmpegKit.cancel]（调用方串行，cancel-all 安全）。
class KitFfmpegBackend implements FfmpegBackend {
  const KitFfmpegBackend();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    try {
      final session =
          await FFmpegKit.executeWithArguments(args).timeout(timeout);
      final ReturnCode? rc = await session.getReturnCode();
      final String output = (await session.getOutput()) ?? '';
      return FfmpegRunResult(
        returnCode: rc?.getValue(),
        output: output,
        executable: 'ffmpeg-kit',
        attemptedExecutables: const <String>['ffmpeg-kit'],
      );
    } on TimeoutException {
      await FFmpegKit.cancel();
      return const FfmpegRunResult(
        returnCode: null,
        output: '',
        executable: 'ffmpeg-kit',
        attemptedExecutables: <String>['ffmpeg-kit'],
      );
    }
  }
}

FfmpegBackend? _cachedBackend;

/// 进程级单例 ffmpeg 后端选择。
///
/// - `HIBIKI_FFMPEG` 覆盖（绝对路径）→ 系统 CLI（开发/特殊部署，优先）。
/// - Android / iOS → [KitFfmpegBackend]（进程内自编 ffmpeg-kit；移动端无系统 ffmpeg
///   且 iOS 禁 exec 子进程）。
/// - 桌面（Windows/macOS/Linux）→ 系统 CLI（打包/用户提供 ffmpeg）。
FfmpegBackend resolveFfmpegBackend() => _cachedBackend ??= _selectBackend();

@visibleForTesting
void setFfmpegBackendForTesting(FfmpegBackend? backend) {
  _cachedBackend = backend;
}

FfmpegBackend _selectBackend() {
  final String? override = Platform.environment['HIBIKI_FFMPEG']?.trim();
  if (override != null && override.isNotEmpty) return const CliFfmpegBackend();
  if (Platform.isAndroid || Platform.isIOS) return const KitFfmpegBackend();
  return const CliFfmpegBackend();
}
