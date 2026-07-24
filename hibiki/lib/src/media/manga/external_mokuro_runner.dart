import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 外部 mokuro CLI 后备：当内置 ONNX OCR 引擎在本平台不可用（或用户偏好外部工具）时，
/// 调用系统上安装的 [mokuro](https://github.com/kha-white/mokuro) 命令行对一个裸图片
/// 目录做整卷 OCR，产出 `.mokuro` 文件后交给既有 [MangaImporter.importFromMokuroPath]
/// 落库。
///
/// 探测顺序（[resolveExecutable]）：**设置指定路径 → `HIBIKI_MOKURO` 环境变量 →
/// PATH（`where`/`which mokuro`）**。子进程经可注入的 [MokuroProcessRunner] 抽象跑，
/// 单测注 fake、绝不真 spawn。
class ExternalMokuroRunner {
  ExternalMokuroRunner({
    String? configuredPath,
    MokuroProcessRunner processRunner = const RealMokuroProcessRunner(),
    Map<String, String>? environment,
  })  : _configuredPath = configuredPath,
        _processRunner = processRunner,
        _environment = environment ?? Platform.environment;

  /// 用户在设置里手填的可执行路径（或命令名）；空/null = 不指定，退回下一探测源。
  final String? _configuredPath;
  final MokuroProcessRunner _processRunner;
  final Map<String, String> _environment;

  /// 按优先级解析出要执行的 mokuro 命令（绝对路径或命令名）；三源皆无返回 null。
  ///
  /// 设置指定路径与 `HIBIKI_MOKURO` 原样返回（可能是绝对路径，也可能是 PATH 上的命令
  /// 名），交给 [Process.start] 解析；找不到时启动阶段抛错、由 [probe]/[run] 兜成可读
  /// 失败。第三源用 `where`/`which` 探 PATH，取首个命中行。
  Future<String?> resolveExecutable() async {
    final String? cfg = _configuredPath?.trim();
    if (cfg != null && cfg.isNotEmpty) return cfg;
    final String? env = _environment['HIBIKI_MOKURO']?.trim();
    if (env != null && env.isNotEmpty) return env;
    return _whichMokuro();
  }

  Future<String?> _whichMokuro() async {
    final String tool = Platform.isWindows ? 'where' : 'which';
    try {
      final MokuroProcessResult r = await _processRunner.runToCompletion(
        tool,
        <String>['mokuro'],
        timeout: const Duration(seconds: 10),
      );
      if (r.exitCode != 0) return null;
      final String line = r.stdout
          .split(RegExp(r'[\r\n]+'))
          .map((String l) => l.trim())
          .firstWhere((String l) => l.isNotEmpty, orElse: () => '');
      return line.isEmpty ? null : line;
    } catch (_) {
      return null;
    }
  }

  /// 探测 mokuro 是否可用并返回版本串（`mokuro --version` 的首个非空行）。
  /// 未找到可执行 / 非零退出 / 超时 / 无输出 → 返回 null（设置页据此显示「未检测到」）。
  Future<String?> probe() async {
    final String? exe = await resolveExecutable();
    if (exe == null) return null;
    try {
      final MokuroProcessResult r = await _processRunner.runToCompletion(
        exe,
        <String>['--version'],
        timeout: const Duration(seconds: 15),
      );
      if (r.exitCode != 0) return null;
      final String text = (r.stdout.trim().isNotEmpty ? r.stdout : r.stderr);
      final String line = text
          .split(RegExp(r'[\r\n]+'))
          .map((String l) => l.trim())
          .firstWhere((String l) => l.isNotEmpty, orElse: () => '');
      return line.isEmpty ? null : line;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 对 [imageDirPath] 目录跑 `mokuro --disable_confirmation <dir>`，逐行解析 tqdm
  /// 进度（含 `N/M` → [MokuroRunEvent.progress]；解析不出的输出不落进度，靠起始的
  /// [MokuroRunEvent.running] 让 UI 显示「运行中」）。进程正常退出后定位产出的 `.mokuro`
  /// 文件，以 [MokuroRunEvent.finished] 收尾。
  ///
  /// 失败以 stream error（[MokuroRunnerException]）结束：找不到可执行 / 启动失败 /
  /// 非零退出 / [idleTimeout] 内无任何输出（挂死）/ 跑完找不到 `.mokuro`。取消订阅即
  /// SIGKILL 子进程。
  Stream<MokuroRunEvent> run(
    String imageDirPath, {
    Duration idleTimeout = const Duration(minutes: 5),
  }) {
    late final StreamController<MokuroRunEvent> controller;
    final Directory imageDir = Directory(imageDirPath);
    MokuroProcessHandle? handle;
    Timer? idle;
    StreamSubscription<String>? sub;
    bool cancelled = false;

    void resetIdle() {
      idle?.cancel();
      idle = Timer(idleTimeout, () {
        handle?.kill();
        if (!controller.isClosed) {
          controller
              .addError(const MokuroRunnerException('mokuro 长时间无输出，已超时终止'));
        }
      });
    }

    Future<void> startRun() async {
      final String? exe = await resolveExecutable();
      if (exe == null) {
        controller.addError(const MokuroRunnerException('未找到 mokuro 可执行文件'));
        await controller.close();
        return;
      }
      try {
        handle = await _processRunner
            .start(exe, <String>['--disable_confirmation', imageDirPath]);
      } catch (e) {
        controller.addError(MokuroRunnerException('启动 mokuro 失败：$e'));
        await controller.close();
        return;
      }
      if (cancelled) {
        handle?.kill();
        await controller.close();
        return;
      }
      controller.add(const MokuroRunEvent.running());
      resetIdle();
      sub = handle!.lines.listen((String line) {
        resetIdle();
        final MokuroRunEvent? progress = parseProgressLine(line);
        if (progress != null && !controller.isClosed) {
          controller.add(progress);
        }
      });

      final int code = await handle!.exitCode;
      idle?.cancel();
      await sub?.cancel();
      if (cancelled) {
        if (!controller.isClosed) await controller.close();
        return;
      }
      if (code != 0) {
        controller.addError(MokuroRunnerException('mokuro 以非零退出码 $code 结束'));
        await controller.close();
        return;
      }
      final String? mokuroPath = locateMokuroFile(imageDir);
      if (mokuroPath == null) {
        controller.addError(
            const MokuroRunnerException('mokuro 运行完成但未找到 .mokuro 产物'));
      } else {
        controller.add(MokuroRunEvent.finished(mokuroPath));
      }
      await controller.close();
    }

    controller = StreamController<MokuroRunEvent>(
      onListen: () {
        unawaited(startRun());
      },
      onCancel: () async {
        cancelled = true;
        idle?.cancel();
        handle?.kill();
        await sub?.cancel();
      },
    );
    return controller.stream;
  }

  /// 从一行输出里宽松解析 tqdm 的 `N/M` 进度；解析不出返回 null。
  /// 纯函数、@visibleForTesting 暴露给单测。
  static MokuroRunEvent? parseProgressLine(String line) {
    final RegExpMatch? m = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(line);
    if (m == null) return null;
    final int done = int.parse(m.group(1)!);
    final int total = int.parse(m.group(2)!);
    if (total <= 0 || done > total) return null;
    return MokuroRunEvent.progress(done: done, total: total);
  }

  /// 在 [imageDir] 同级目录与其自身内定位 mokuro 产出的 `.mokuro` 文件。
  /// 优先取「文件名（去扩展）== 目录名」的那个（mokuro 惯例 `<卷名>.mokuro`），否则
  /// 退回修改时间最新的一个；一个都没有返回 null。
  static String? locateMokuroFile(Directory imageDir) {
    final List<File> candidates = <File>[];
    for (final Directory d in <Directory>[imageDir.parent, imageDir]) {
      if (!d.existsSync()) continue;
      for (final FileSystemEntity e in d.listSync()) {
        if (e is File && p.extension(e.path).toLowerCase() == '.mokuro') {
          candidates.add(e);
        }
      }
    }
    if (candidates.isEmpty) return null;
    final String wantBase = p.basename(imageDir.path);
    for (final File f in candidates) {
      if (p.basenameWithoutExtension(f.path) == wantBase) return f.path;
    }
    candidates.sort((File a, File b) =>
        b.statSync().modified.compareTo(a.statSync().modified));
    return candidates.first.path;
  }
}

/// 外部 mokuro CLI 运行的进度/完成事件（与内置 `MangaOcrVolumeEvent` 分开：外部产物是
/// `.mokuro` 文件而非内部 `manga.json`，落库路径不同，故不复用同一事件类型）。
class MokuroRunEvent {
  /// 进程已起、尚无可解析进度时先发一次，让 UI 显示「运行中」不定态。
  const MokuroRunEvent.running()
      : done = 0,
        total = 0,
        mokuroPath = null,
        finished = false,
        isRunning = true;

  const MokuroRunEvent.progress({required this.done, required this.total})
      : mokuroPath = null,
        finished = false,
        isRunning = false;

  const MokuroRunEvent.finished(String this.mokuroPath)
      : done = 0,
        total = 0,
        finished = true,
        isRunning = false;

  final int done;
  final int total;

  /// finished 事件携带定位到的 `.mokuro` 文件绝对路径。
  final String? mokuroPath;
  final bool finished;

  /// running 起始事件标记（无 N/M 可报时用于驱动 UI 的不定态）。
  final bool isRunning;
}

/// 单次子进程运行结果（探测/版本用）。
class MokuroProcessResult {
  const MokuroProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// 长进程句柄：合并后的逐行输出流（stdout+stderr）、可 await 的退出码、SIGKILL 句柄。
class MokuroProcessHandle {
  const MokuroProcessHandle({
    required this.lines,
    required this.exitCode,
    required this.kill,
  });

  /// 合并 stdout+stderr、按 `\r`/`\n` 切分后的逐行流（含 tqdm 的 `\r` 就地刷新行）。
  final Stream<String> lines;
  final Future<int> exitCode;
  final void Function() kill;
}

/// 可注入的子进程运行器抽象：真实现走 `dart:io` Process，单测注 fake 不真 spawn。
abstract class MokuroProcessRunner {
  /// 跑一次命令、收集完整 stdout/stderr（`--version` / `where` 探测）。
  Future<MokuroProcessResult> runToCompletion(
    String executable,
    List<String> args, {
    Duration? timeout,
  });

  /// 起一个长进程并返回逐行输出句柄（OCR 进度流）。
  Future<MokuroProcessHandle> start(String executable, List<String> args);
}

/// 生产实现：`Process.start` + 宽容 UTF-8 解码 + 按 CR/LF 切行合并两条管道。
class RealMokuroProcessRunner implements MokuroProcessRunner {
  const RealMokuroProcessRunner();

  @override
  Future<MokuroProcessResult> runToCompletion(
    String executable,
    List<String> args, {
    Duration? timeout,
  }) async {
    final Process proc = await Process.start(executable, args);
    final Future<String> outF =
        proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final Future<String> errF =
        proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    final Future<int> codeF = proc.exitCode;
    int code;
    if (timeout != null) {
      try {
        code = await codeF.timeout(timeout);
      } on TimeoutException {
        proc.kill(ProcessSignal.sigkill);
        rethrow;
      }
    } else {
      code = await codeF;
    }
    return MokuroProcessResult(
      exitCode: code,
      stdout: await outF,
      stderr: await errF,
    );
  }

  @override
  Future<MokuroProcessHandle> start(
      String executable, List<String> args) async {
    final Process proc = await Process.start(executable, args);
    final StreamController<String> controller = StreamController<String>();
    final _CrLfLineAccumulator acc = _CrLfLineAccumulator((String l) {
      if (!controller.isClosed) controller.add(l);
    });
    int openStreams = 2;
    void onStreamDone() {
      openStreams -= 1;
      if (openStreams == 0) {
        acc.flush();
        if (!controller.isClosed) controller.close();
      }
    }

    proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(acc.add, onDone: onStreamDone, onError: (_) => onStreamDone());
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(acc.add, onDone: onStreamDone, onError: (_) => onStreamDone());
    return MokuroProcessHandle(
      lines: controller.stream,
      exitCode: proc.exitCode,
      kill: () => proc.kill(ProcessSignal.sigkill),
    );
  }
}

/// 按 `\r` 或 `\n` 切分累积的文本块成行（tqdm 用 `\r` 就地刷新进度条，故不能只切 `\n`）。
/// 不完整的尾段留在缓冲里，等下一 `\r`/`\n` 或 [flush] 才吐出。
class _CrLfLineAccumulator {
  _CrLfLineAccumulator(this._emit);

  final void Function(String line) _emit;
  String _buffer = '';

  void add(String chunk) {
    _buffer += chunk;
    final List<String> parts = _buffer.split(RegExp(r'[\r\n]+'));
    _buffer = parts.removeLast();
    for (final String part in parts) {
      if (part.isNotEmpty) _emit(part);
    }
  }

  void flush() {
    if (_buffer.isNotEmpty) {
      _emit(_buffer);
      _buffer = '';
    }
  }
}

/// 外部 mokuro CLI 运行失败（可读消息）。
class MokuroRunnerException implements Exception {
  const MokuroRunnerException(this.message);

  final String message;

  @override
  String toString() => 'MokuroRunnerException: $message';
}
