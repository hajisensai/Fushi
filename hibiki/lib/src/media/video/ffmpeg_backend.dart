import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

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

/// ffmpeg 执行底座抽象：所有 ffmpeg 调用经它，与「系统 CLI / 捆绑库」实现解耦。
///
/// 只有一个原语 [run]——跑一次 ffmpeg，返回退出码 + stderr 文本：
/// - 5 个 extract 函数（音/视频封面、视频帧、字幕抽取、音频裁剪）只看
///   [FfmpegRunResult.returnCode] 与产出文件。
/// - 内嵌字幕「列举」用 `run(['-hide_banner','-i',path])` 拿 [FfmpegRunResult.output]
///   喂 `parseSubtitleStreamsFromFfmpegLog`，无需独立 probe API（两后端通用）。
///
/// 移动端/未装 ffmpeg 的桌面端将由捆绑后端（ffmpeg_kit）实现本接口接入
/// [resolveFfmpegBackend]；当前仅 [CliFfmpegBackend]。
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

/// 系统 ffmpeg（`Process.start`）后端：桌面与 Linux，及任何捆绑后端不可用时的回退。
///
/// [run] 复刻原 `_runFfmpeg` 语义：drain stdout 防管道死锁、收集 stderr 作 output、
/// `exitCode.timeout` 超时则 SIGKILL 返回 `returnCode:null`。ffmpeg 不存在时
/// `Process.start` 抛 [ProcessException]，**向上传播**（各调用方自行 catch，沿用旧契约）。
/// stderr 用宽容 UTF-8 解码（`allowMalformed`），绝不因个别非法字节抛错。
class CliFfmpegBackend implements FfmpegBackend {
  const CliFfmpegBackend();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    final Process process = await Process.start(resolveFfmpegExecutable(), args);
    // Drain both pipes: a full OS pipe buffer (ffmpeg writes progress to stderr)
    // would otherwise deadlock the process before it can exit.
    unawaited(process.stdout.drain<void>());
    final Future<String> stderrText = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final int code = await process.exitCode.timeout(timeout);
      final String output = await stderrText;
      return FfmpegRunResult(returnCode: code, output: output);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return const FfmpegRunResult(returnCode: null, output: '');
    }
  }
}

/// 捆绑 ffmpeg（`ffmpeg_kit_flutter_new_min`）后端：移动端（Android/iOS）无系统 CLI
/// ffmpeg，改经 ffmpeg-kit 跑同一套命令，让移动端复用桌面的全部 ffmpeg 功能（内封
/// 字幕枚举/抽取、cue 动图、句子音频裁剪、视频帧）——与 [CliFfmpegBackend] **同契约**，
/// 5 个 extract 函数 + 字幕枚举零改动。
///
/// `executeWithArguments` 同步执行（await 到会话结束），随后 [getReturnCode] /
/// [getOutput]（= 合并日志，喂 `parseSubtitleStreamsFromFfmpegLog`）即就绪。超时用
/// `.timeout` + [FFmpegKit.cancel]（调用方串行，cancel-all 安全）。min(LGPL) 变体内置
/// 字幕 demux/转码、gif/aac 编码与各路解码（opus/h264/hevc…），不含 GPL 的 x264。
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
/// - Android / iOS → 捆绑 [KitFfmpegBackend]（移动端无系统 ffmpeg）。
/// - 桌面（Windows/macOS/Linux）→ 系统 CLI（沿用今日行为，打包/用户提供 ffmpeg）。
FfmpegBackend resolveFfmpegBackend() => _cachedBackend ??= _selectBackend();

FfmpegBackend _selectBackend() {
  final String? override = Platform.environment['HIBIKI_FFMPEG']?.trim();
  if (override != null && override.isNotEmpty) return const CliFfmpegBackend();
  if (Platform.isAndroid || Platform.isIOS) return const KitFfmpegBackend();
  return const CliFfmpegBackend();
}
