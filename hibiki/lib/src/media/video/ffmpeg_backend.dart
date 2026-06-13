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
  const FfmpegRunResult({required this.returnCode, required this.output});

  final int? returnCode;
  final String output;

  bool get isSuccess => returnCode == 0;
}

typedef FfmpegProcessRunner = Future<FfmpegRunResult> Function(
  String executable,
  List<String> args,
  Duration timeout,
);

const int _windowsStatusInvalidImageFormatSigned = -1073741701;
const int _windowsStatusInvalidImageFormatUnsigned = 0xC000007B;
const int _windowsBadExeFormatErrorCode = 193;

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
    return FfmpegRunResult(returnCode: code, output: output);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return const FfmpegRunResult(returnCode: null, output: '');
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

bool _isWindowsBadExeFormatProcessException(
  Object error, {
  required bool isWindows,
}) =>
    isWindows &&
    error is ProcessException &&
    error.errorCode == _windowsBadExeFormatErrorCode;

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
    return runner(o, args, timeout);
  }

  final String? bundled = bundledPath?.trim();
  if (bundled != null && bundled.isNotEmpty) {
    try {
      final FfmpegRunResult bundledResult =
          await runner(bundled, args, timeout);
      if (!_isWindowsInvalidImageFormatExitCode(
        bundledResult.returnCode,
        isWindows: isWindows,
      )) {
        return bundledResult;
      }
      debugPrint(
        '[hibiki-ffmpeg] bundled ffmpeg is STATUS_INVALID_IMAGE_FORMAT; '
        'falling back to PATH ffmpeg: $bundled',
      );
    } on ProcessException catch (e) {
      if (!_isWindowsBadExeFormatProcessException(e, isWindows: isWindows)) {
        rethrow;
      }
      debugPrint(
        '[hibiki-ffmpeg] bundled ffmpeg is not a valid Windows executable; '
        'falling back to PATH ffmpeg: $bundled',
      );
    }
  }

  return runner('ffmpeg', args, timeout);
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
      return FfmpegRunResult(returnCode: rc?.getValue(), output: output);
    } on TimeoutException {
      await FFmpegKit.cancel();
      return const FfmpegRunResult(returnCode: null, output: '');
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
