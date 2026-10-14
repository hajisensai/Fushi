/// 本机 GPT-SoVITS 推理服务（官方整合包的 `api_v2.py`）的进程托管：启动、等就绪、
/// 收日志尾、停止。
///
/// 进程经 [HelperProcessRegistry] 启动：app 退出 / 应用内更新前统一终止，不留一个
/// 占着显存和端口的孤儿 python。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';

/// 服务状态。`starting` 期间端口还没在听（加载底模要几十秒）。
enum GptSovitsServerPhase { stopped, starting, running, failed }

/// 服务启动失败的原因（UI 翻译成文案；日志尾另给）。
enum GptSovitsServerFailure {
  /// 安装目录里没有内置 python / `api_v2.py`（没装完或被删了）。
  notInstalled,

  /// 进程起不来（权限、杀软拦截……）。
  spawnFailed,

  /// 进程起来后又退出了（显卡驱动、缺依赖、端口被占……看日志尾）。
  exited,

  /// 等了 [GptSovitsLocalServer.readyTimeout] 端口还没就绪。
  timeout,
}

/// 启动参数：可执行文件、参数、工作目录全由安装布局决定（见
/// `gpt_sovits_local_install.dart`），这里只管跑。
class GptSovitsLaunchSpec {
  const GptSovitsLaunchSpec({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.port,
    this.environment = const <String, String>{},
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final int port;
  final Map<String, String> environment;

  /// 本机服务地址（预设里填的就是它）。
  String get endpoint => 'http://127.0.0.1:$port';
}

/// 探活：api_v2 在模块加载时就把底模读完，之后才 `uvicorn.run`，所以端口能答就是
/// 已就绪。没有专门的健康端点，用 FastAPI 自带的 `GET /openapi.json`（不触发合成）。
typedef GptSovitsProbe = Future<bool> Function(int port);

Future<bool> gptSovitsDefaultProbe(int port) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/openapi.json'),
    );
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 5),
    );
    await response.drain<void>().catchError((Object _) {});
    return response.statusCode == HttpStatus.ok;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 起子进程的入口（测试注入假进程）。
typedef GptSovitsSpawn =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

Future<Process> _registrySpawn(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => HelperProcessRegistry.instance.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
);

class GptSovitsLocalServer extends EngineChangeNotifier {
  GptSovitsLocalServer({
    GptSovitsSpawn? spawn,
    GptSovitsProbe? probe,
    this.readyTimeout = const Duration(minutes: 5),
    this.probeInterval = const Duration(seconds: 1),
  }) : _spawn = spawn ?? _registrySpawn,
       _probe = probe ?? gptSovitsDefaultProbe;

  final GptSovitsSpawn _spawn;
  final GptSovitsProbe _probe;

  /// 首次启动要把底模读进显存，慢盘 / 慢卡上一两分钟很常见。
  final Duration readyTimeout;
  final Duration probeInterval;

  /// 日志尾保留的行数（失败时给用户看、复制给作者）。
  static const int logTailLines = 200;

  GptSovitsServerPhase _phase = GptSovitsServerPhase.stopped;
  GptSovitsServerFailure? _failure;
  Process? _process;
  GptSovitsLaunchSpec? _spec;
  Completer<bool>? _starting;

  /// 端口上已有别人起的服务、本对象直接借用（不拥有进程，停不了它）。
  bool _external = false;
  final List<String> _log = <String>[];

  GptSovitsServerPhase get phase => _phase;
  GptSovitsServerFailure? get failure => _failure;
  bool get isRunning => _phase == GptSovitsServerPhase.running;

  /// 正在运行（或启动中）的服务地址；没起返回 null。
  String? get endpoint => _owns ? _spec?.endpoint : null;
  int? get port => _owns ? _spec?.port : null;

  /// 服务是不是借用的外部进程（UI 据此说明「停止」停不了它）。
  bool get isExternal => _external && isRunning;

  bool get _owns => _process != null || (_external && isRunning);
  List<String> get logTail => List<String>.unmodifiable(_log);

  void _set(GptSovitsServerPhase phase, [GptSovitsServerFailure? failure]) {
    _phase = phase;
    _failure = failure;
    notifyListeners();
  }

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > logTailLines) {
      _log.removeRange(0, _log.length - logTailLines);
    }
  }

  /// 启动并等就绪。已在跑 / 正在起时复用同一次（并发调用者共享结论）。
  /// 返回是否就绪。
  Future<bool> start(GptSovitsLaunchSpec spec) {
    final Completer<bool>? pending = _starting;
    if (pending != null) return pending.future;
    if (_phase == GptSovitsServerPhase.running && _owns) {
      return Future<bool>.value(true);
    }
    final Completer<bool> completer = Completer<bool>();
    _starting = completer;
    unawaited(
      _start(spec)
          .then(
            completer.complete,
            onError: (Object e) {
              completer.complete(false);
            },
          )
          .whenComplete(() => _starting = null),
    );
    return completer.future;
  }

  Future<bool> _start(GptSovitsLaunchSpec spec) async {
    if (!File(spec.executable).existsSync()) {
      _set(GptSovitsServerPhase.failed, GptSovitsServerFailure.notInstalled);
      return false;
    }
    // 端口上已经有一个（上次 app 崩溃留下的、或用户自己手动起的）服务：直接用，
    // 不再起第二个抢显存。这种情况下本对象不拥有进程，停止按钮也停不了它。
    _log.clear();
    _spec = spec;
    _external = false;
    _set(GptSovitsServerPhase.starting);
    if (await _probe(spec.port)) {
      _external = true;
      _appendLog('[reusing the service already listening on ${spec.port}]');
      _set(GptSovitsServerPhase.running);
      return true;
    }
    final Process process;
    try {
      process = await _spawn(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        environment: <String, String>{
          // python 输出不缓冲，日志实时进日志尾；强制 UTF-8，中文 Windows 的 GBK
          // 控制台编码会让 print 日文时直接抛 UnicodeEncodeError 把服务带崩。
          'PYTHONUNBUFFERED': '1',
          'PYTHONIOENCODING': 'utf-8',
          ...spec.environment,
        },
      );
    } on ProcessException catch (e) {
      _appendLog(e.message);
      _set(GptSovitsServerPhase.failed, GptSovitsServerFailure.spawnFailed);
      return false;
    }
    _process = process;
    for (final Stream<List<int>> stream in <Stream<List<int>>>[
      process.stdout,
      process.stderr,
    ]) {
      stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_appendLog, onError: (Object _) {});
    }
    bool exited = false;
    unawaited(
      process.exitCode.then((int code) {
        exited = true;
        _appendLog('[exit $code]');
        if (!identical(_process, process)) return;
        _process = null;
        // 用户点了停止的走 stop() 自己置 stopped；这里只处理意外退出。
        if (_phase != GptSovitsServerPhase.stopped) {
          _set(GptSovitsServerPhase.failed, GptSovitsServerFailure.exited);
        }
      }),
    );

    final DateTime deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (exited || !identical(_process, process)) return false;
      if (await _probe(spec.port)) {
        if (exited || !identical(_process, process)) return false;
        _set(GptSovitsServerPhase.running);
        return true;
      }
      await Future<void>.delayed(probeInterval);
    }
    _appendLog('[not ready after ${readyTimeout.inSeconds} s]');
    process.kill();
    _process = null;
    _set(GptSovitsServerPhase.failed, GptSovitsServerFailure.timeout);
    return false;
  }

  /// 停止本对象起的服务并等它真正退出（释放显存与端口）。
  Future<void> stop() async {
    final Process? process = _process;
    _process = null;
    _external = false;
    _set(GptSovitsServerPhase.stopped);
    if (process == null) return;
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  @override
  void dispose() {
    _process?.kill();
    _process = null;
    super.dispose();
  }
}
