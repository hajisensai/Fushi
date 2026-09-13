import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:meta/meta.dart';

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

/// 从 ffmpeg 日志里抽取「真正的失败原因行」，供 [FfmpegRunResult.failureSummary]
/// 与失败 OSD 显示。
///
/// 根因（TODO-910 / BUG-835）：ffmpeg 的日志**开头恒是 banner**——version /
/// `built with` / `configuration:` / 库版本，`-hide_banner` 只去版本行，`-i` 的
/// 输入/流信息也在开头。真正的失败行（`Conversion failed!` /
/// `Stream map '0:a:3' matches no streams` / `Could not open file` /
/// `Invalid data found` / `Encoder ... not found` 等）出现在日志**末尾**。旧的
/// [_summarizeFfmpegOutput] 从头截断 500 字 → 用户与日志只看到没用的 banner
/// （移动端 ffmpeg-kit 的 configuration 极长，500 字全被 banner 吃满），真因永远
/// 被截掉。本函数从尾段抽真因，让失败摘要可读。
///
/// 策略（从尾往头扫，跳过 banner/进度/Metadata 噪声行）：
/// 1. 拆成非空行（去掉行内首尾空白）。
/// 2. **优先**：自尾向首找第一条「含错误关键词」的行，返回它。
/// 3. **退化**：无任何错误关键词行（如只有 banner），返回最后一条非噪声信息行
///    （跳过 `Input #` / `Metadata:` / `Stream #` / `Duration:` / `ffmpeg version`
///    / `built with` / `configuration:` / `lib*` 版本行 / 纯进度 `frame=` 等）；
///    全是噪声则返回最后一条非空行。
/// 4. 全空 → 空串（调用方据此不追加 detail）。
String extractFfmpegFailureReason(String stderr) {
  final List<String> lines = stderr
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) return '';

  const List<String> errorMarkers = <String>[
    'error',
    'failed',
    'invalid',
    'could not',
    'cannot',
    'no such',
    'matches no streams',
    'unable',
    'permission denied',
    'not found',
    'unsupported',
    'unrecognized',
    'unknown',
    'does not contain',
  ];
  for (int i = lines.length - 1; i >= 0; i--) {
    final String lower = lines[i].toLowerCase();
    if (errorMarkers.any(lower.contains)) {
      return lines[i];
    }
  }

  // 退化：无错误关键词（典型是被截断的纯 banner）。返回最后一条非噪声信息行。
  bool isNoise(String line) {
    final String lower = line.toLowerCase();
    return line.startsWith('Input #') ||
        line.startsWith('Output #') ||
        line.startsWith('Stream #') ||
        line.startsWith('Metadata:') ||
        line.startsWith('Duration:') ||
        lower.startsWith('frame=') ||
        lower.startsWith('size=') ||
        lower.contains('encoder') ||
        lower.startsWith('ffmpeg version') ||
        lower.startsWith('built with') ||
        lower.startsWith('configuration:') ||
        lower.startsWith('lib');
  }

  for (int i = lines.length - 1; i >= 0; i--) {
    if (!isNoise(lines[i])) return lines[i];
  }
  return lines.last;
}

/// 把 ffmpeg 日志压成一行给 [FfmpegRunResult.failureSummary] 显示。
///
/// BUG-835：不再从**头**截断（那永远是 banner，真因在尾段）。先用
/// [extractFfmpegFailureReason] 抽出末尾的真因行；抽不出才退化到整段压平。再折成
/// 单行并限长，避免超长 configuration 撑爆 toast。
String _summarizeFfmpegOutput(String output) {
  final String reason = extractFfmpegFailureReason(output);
  final String chosen = reason.isNotEmpty ? reason : output.trim();
  final String oneLine = chosen.replaceAll(RegExp(r'\s+'), ' ').trim();
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

  /// 跑一次 ffprobe，返回退出码 + **stdout** 文本（ffprobe 的 JSON 报告写 stdout，
  /// 不是 stderr）。TODO-1045 元数据探测用：桌面 [CliFfmpegBackend] 起 ffprobe 进程、
  /// 移动端 [KitFfmpegBackend] 走 `FFprobeKit.executeWithArguments`。与 [run] 分开
  /// （不同可执行、不同输出流），不污染既有 ffmpeg 调用路径。
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout);
}

/// 解析 ffmpeg 可执行文件（桌面 [CliFfmpegBackend] 用）。优先级：
/// 1. `FUSHI_FFMPEG`（绝对路径，显式覆盖，开发/特殊部署）；
/// 2. **app 程序旁捆绑的 `ffmpeg(.exe)`**（打包时塞进各桌面产物 → 开箱即用，不依赖
///    用户自己装 ffmpeg；否则没装 ffmpeg 的电脑会丢内封字幕/cue 动图/制卡音频）；
/// 3. 回退系统 PATH 上的 `ffmpeg`。
String resolveFfmpegExecutable() => resolveFfmpegExecutableFrom(
      override: ffmpegExplicitOverride(),
      bundledPath: _bundledFfmpegPath(),
    );

/// 宿主**显式装配**的 ffmpeg / ffprobe 可执行路径（无头服务端从 `fushi_server.yaml`
/// 的 `ffmpeg:` / `ffprobe:` 装；app 不装 = null）。
///
/// 语义与 `FUSHI_FFMPEG` 环境变量完全同构、且优先于它：走「显式覆盖」分支——不做
/// 捆绑损坏回退、跑不起来如实抛。之所以不是「配置项写进子进程环境」：
/// `Platform.environment` 只读，服务端启动后没法给自己设环境变量；此前配置项只做
/// 展示 + 提示用户去设 `FUSHI_FFMPEG`，等于配置文件里放了个不生效的键。
String? ffmpegPathOverride;
String? ffprobePathOverride;

/// 「显式覆盖」的单一入口：宿主装配值 > 环境变量（新名 > 旧名）> null。
/// 所有拿 override 的地方（解析、CLI 后端、后端选择）都只问这里。
String? ffmpegExplicitOverride() =>
    resolveHostOverrideFrom(ffmpegPathOverride, ffmpegEnvOverride());

/// ffprobe 版的 [ffmpegExplicitOverride]。
String? ffprobeExplicitOverride() =>
    resolveHostOverrideFrom(ffprobePathOverride, ffprobeEnvOverride());

/// 纯函数：宿主装配值非空（trim 后）就用它，否则退到环境变量链的结果。
/// 空串/纯空白按「没装」——与 [resolveEnvOverrideFrom] 同一条约定。
String? resolveHostOverrideFrom(String? hostOverride, String? envOverride) {
  final String? host = hostOverride?.trim();
  if (host != null && host.isNotEmpty) return host;
  return envOverride;
}

/// BUG-1664：ffmpeg 可执行的环境覆盖——**新名优先，旧名回退**（`HIBIKI_FFMPEG` 是改名
/// 前公开给用户的变量名，仍须认）。
///
/// 收成单一入口是因为原先 5 个调用点各自手写 `env['FUSHI_FFMPEG'] ?? env['FUSHI_FFMPEG']`
/// ——两边同名，注释承诺的旧名回退**从未生效**（改名批次的复制粘贴漏改）。让"回退去问
/// 哪个名字"只存在一处，这类错误就无处可写。
String? ffmpegEnvOverride() => resolveEnvOverrideFrom(
      Platform.environment,
      const <String>['FUSHI_FFMPEG', 'HIBIKI_FFMPEG'],
    );

/// ffprobe 版的 [ffmpegEnvOverride]（同样新名优先、旧名回退）。
String? ffprobeEnvOverride() => resolveEnvOverrideFrom(
      Platform.environment,
      const <String>['FUSHI_FFPROBE', 'HIBIKI_FFPROBE'],
    );

/// 纯函数：在 [env] 里按 [names] 的先后顺序取第一个**非空**值（新名在前、旧名在后）。
///
/// 空串按「没设」处理：`FUSHI_FFMPEG=` 这种空赋值不该把旧名的有效路径挡掉，也不该被
/// 当成可执行路径喂给 `Process.start`。纯函数是为了让优先级本身可被单测钉住——
/// `Platform.environment` 不可注入，行为只能靠这一层来锁。
String? resolveEnvOverrideFrom(Map<String, String> env, List<String> names) {
  for (final String name in names) {
    final String? value = env[name];
    if (value != null && value.trim().isNotEmpty) return value;
  }
  return null;
}

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
String? _bundledFfmpegPath() => _bundledExecutablePath('ffmpeg');

/// 解析 ffprobe 可执行文件（TODO-1045 元数据探测用）。与 [resolveFfmpegExecutable]
/// 同款优先级：`FUSHI_FFPROBE` 覆盖 > 程序旁捆绑 `ffprobe(.exe)`（打包时与 ffmpeg
/// 并排塞进各桌面产物）> 系统 PATH 上的 `ffprobe`。
String resolveFfprobeExecutable() => resolveFfprobeExecutableFrom(
      override: ffprobeExplicitOverride(),
      bundledPath: _bundledFfprobePath(),
    );

/// 纯函数：按「覆盖 > 捆绑 > PATH」决定 ffprobe 可执行（镜像
/// [resolveFfmpegExecutableFrom]，便于单测优先级）。
String resolveFfprobeExecutableFrom({
  required String? override,
  required String? bundledPath,
}) {
  final String? o = override?.trim();
  if (o != null && o.isNotEmpty) return o;
  if (bundledPath != null && bundledPath.isNotEmpty) return bundledPath;
  return 'ffprobe';
}

/// app 可执行文件同目录下的捆绑 ffprobe 路径（存在才返回，否则 null）。镜像
/// [_bundledFfmpegPath]：捆绑 ffmpeg 的产物旁通常并排放着同版本 ffprobe(.exe)。
String? _bundledFfprobePath() => _bundledExecutablePath('ffprobe');

/// 共享：app 可执行文件同目录下名为 [name]（Windows 补 `.exe`）的捆绑工具路径，
/// 存在才返回，否则 null；任何异常静默返回 null 回退 PATH。ffmpeg / ffprobe 共用。
String? _bundledExecutablePath(String name) {
  try {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String fileName = Platform.isWindows ? '$name.exe' : name;
    final File candidate = File('$exeDir${Platform.pathSeparator}$fileName');
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
  final Process process =
      await HelperProcessRegistry.instance.start(executable, args);
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

/// 共享：跑一次指定可执行文件的 **ffprobe**，返回退出码 + **stdout** 文本。
///
/// 与 [runFfmpegProcess] 的关键区别：ffprobe 的 `-print_format json` 报告写到
/// **stdout**（ffmpeg 把工作输出写 stderr），故这里收集 stdout 作 [FfmpegRunResult.output]、
/// drain stderr 防管道死锁——正好与 ffmpeg 反过来。超时 SIGKILL 返回 `returnCode:null`；
/// 可执行文件不存在时 `Process.start` 抛 [ProcessException] **向上传播**（调用方 catch
/// 后回退文件名兜底）。stdout 用宽容 UTF-8 解码，绝不因个别非法字节抛错。
Future<FfmpegRunResult> runFfprobeProcess(
  String executable,
  List<String> args,
  Duration timeout,
) async {
  final Process process =
      await HelperProcessRegistry.instance.start(executable, args);
  final Future<String> stdoutText =
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  unawaited(process.stderr.drain<void>());
  try {
    final int code = await process.exitCode.timeout(timeout);
    final String output = await stdoutText;
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
      fushiDebugPrint(
        '[fushi-ffmpeg] bundled ffmpeg ran but produced no usable output '
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
      // 显式 FUSHI_FFMPEG 覆盖走上面的分支、不进这里，旧契约不变（如实报错）。
      fallbackReason = 'bundled ffmpeg launch failed '
          '(errorCode=${e.errorCode}, message=${e.message})';
      fushiDebugPrint(
        '[fushi-ffmpeg] bundled ffmpeg failed to launch '
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

/// 桌面 ffprobe 执行（`resolveFfprobeExecutable` 解析：覆盖>捆绑>PATH）：先试解析出的
/// 可执行，若它是捆绑路径且 `Process.start` 抛 [ProcessException]（损坏/权限/架构不匹配），
/// 回退 PATH 上的 `ffprobe`；两者都跑不起来则向上抛（调用方回退文件名兜底）。
///
/// 不复用 ffmpeg 的 stderr-空回退启发式（那些针对 ffmpeg 的工作输出写 stderr）：
/// ffprobe JSON 写 stdout，无 tag 的容器也会输出合法的 `{"format":{...}}`，故只需处理
/// 「二进制跑不起来」这一类回退。纯函数 [runCliFfprobeForTesting] 暴露给单测。
Future<FfmpegRunResult> _runCliFfprobe({
  required String? override,
  required String? bundledPath,
  required List<String> args,
  required Duration timeout,
  required FfmpegProcessRunner runner,
}) async {
  final String resolved = resolveFfprobeExecutableFrom(
      override: override, bundledPath: bundledPath);
  try {
    return (await runner(resolved, args, timeout)).withExecutionContext(
      executable: resolved,
      attemptedExecutables: <String>[resolved],
    );
  } on ProcessException catch (e) {
    // 显式覆盖跑不起来沿旧契约如实抛（不悄悄换 PATH）。
    final String? o = override?.trim();
    final bool isOverride = o != null && o.isNotEmpty && resolved == o;
    // 已经就是裸 PATH `ffprobe` 了，无处可退，向上抛。
    if (isOverride || resolved == 'ffprobe') rethrow;
    final List<String> attempted = <String>[resolved, 'ffprobe'];
    final String reason = 'bundled ffprobe launch failed '
        '(errorCode=${e.errorCode}, message=${e.message})';
    try {
      return (await runner('ffprobe', args, timeout)).withExecutionContext(
        executable: 'ffprobe',
        attemptedExecutables: attempted,
        fallbackReason: reason,
      );
    } on ProcessException catch (e2) {
      throw _withFfmpegLaunchContext(
        e2,
        attemptedExecutables: attempted,
        fallbackReason: reason,
      );
    }
  }
}

@visibleForTesting
Future<FfmpegRunResult> runCliFfprobeForTesting({
  required String? override,
  required String? bundledPath,
  required List<String> args,
  required Duration timeout,
  required FfmpegProcessRunner runner,
}) =>
    _runCliFfprobe(
      override: override,
      bundledPath: bundledPath,
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
        override: ffmpegExplicitOverride(),
        bundledPath: _bundledFfmpegPath(),
        isWindows: Platform.isWindows,
        args: args,
        timeout: timeout,
        runner: runFfmpegProcess,
      );

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      _runCliFfprobe(
        override: ffprobeExplicitOverride(),
        bundledPath: _bundledFfprobePath(),
        args: args,
        timeout: timeout,
        runner: runFfprobeProcess,
      );
}

FfmpegBackend? _cachedBackend;

/// 进程级单例 ffmpeg 后端选择。
///
/// - 显式覆盖（宿主装配 [ffmpegPathOverride] 或 `FUSHI_FFMPEG`，绝对路径）→ 系统 CLI
///   （开发/特殊部署/无头服务端配置，优先）。
/// - Android / iOS → app 经 [ffmpegPlatformBackendProvider] 装的 `KitFfmpegBackend`
///   （进程内自编 ffmpeg-kit；移动端无系统 ffmpeg 且 iOS 禁 exec 子进程）。
/// - 桌面（Windows/macOS/Linux）→ 系统 CLI（打包/用户提供 ffmpeg）。
FfmpegBackend resolveFfmpegBackend() => _cachedBackend ??= _selectBackend();

@visibleForTesting
void setFfmpegBackendForTesting(FfmpegBackend? backend) {
  _cachedBackend = backend;
}

/// 平台专属后端装配点：Flutter app 在 `main()` 里装 `KitFfmpegBackend`
/// （Android / iOS 进程内 ffmpeg-kit，实现留在 app，引擎不依赖插件）；无头
/// 服务端与桌面不装，走系统 CLI。`FUSHI_FFMPEG` 覆盖永远优先于它。
FfmpegBackend Function()? ffmpegPlatformBackendProvider;

FfmpegBackend _selectBackend() {
  // 显式覆盖（宿主装配 / FUSHI_FFMPEG）→ 系统 CLI，永远优先于平台后端。
  final String? override = ffmpegExplicitOverride()?.trim();
  if (override != null && override.isNotEmpty) return const CliFfmpegBackend();
  return ffmpegPlatformBackendProvider?.call() ?? const CliFfmpegBackend();
}
