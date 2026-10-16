/// 本机 GPT-SoVITS 推理服务（官方整合包的 `api_v2.py`）的进程托管：启动、等就绪、
/// 收日志尾、停止。
///
/// 进程经 [HelperProcessRegistry] 启动：app 退出 / 应用内更新前统一终止，不留一个
/// 占着显存和端口的孤儿 python。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
/// 已就绪。没有专门的健康端点，用 FastAPI 自带的 `GET /openapi.json`（不触发合成），
/// 并且要求路由表里有 api_v2 特有的 `/tts` 与 `/set_gpt_weights`——端口上随便一个
/// FastAPI 服务（或别的程序）不能被当成 GPT-SoVITS 借用。
typedef GptSovitsProbe = Future<bool> Function(int port);

/// openapi 文档是不是 GPT-SoVITS `api_v2.py` 的（纯函数，测试直接调）。
bool gptSovitsOpenApiLooksLikeApiV2(String body) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return false;
  }
  final Object? paths = json is Map ? json['paths'] : null;
  return paths is Map &&
      paths.containsKey('/tts') &&
      paths.containsKey('/set_gpt_weights');
}

/// openapi 文档读取上限：api_v2 的只有几 KB，超过就不是它。
const int _kOpenApiMaxBytes = 1024 * 1024;

Future<bool> gptSovitsDefaultProbe(int port) async {
  // 只打本机回环（本进程拉起的服务）：故意不走 app 代理，登记在
  // outbound_http_discipline_guard_test 的 kBareOutboundRegistry。
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..findProxy = (Uri _) => 'DIRECT';
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/openapi.json'),
    );
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 5),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((Object _) {});
      return false;
    }
    final BytesBuilder bytes = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 5),
    )) {
      bytes.add(chunk);
      if (bytes.length > _kOpenApiMaxBytes) return false;
    }
    return gptSovitsOpenApiLooksLikeApiV2(
      utf8.decode(bytes.takeBytes(), allowMalformed: true),
    );
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// [pid] 这个进程是不是以 [executable] 为映像在跑（用来认领上次崩溃留下的、本 app
/// 安装目录里起的服务）。测试注入。
typedef GptSovitsPidOwnerCheck =
    Future<bool> Function(int pid, String executable);

/// 结束一个按 pid 认领的进程（测试注入）。
typedef GptSovitsPidKill = bool Function(int pid);

Future<bool> gptSovitsDefaultPidOwnerCheck(int pid, String executable) async {
  String? path;
  try {
    if (Platform.isWindows) {
      final ProcessResult r = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-Process -Id $pid -ErrorAction SilentlyContinue).Path',
      ]).timeout(const Duration(seconds: 10));
      if (r.exitCode == 0) path = '${r.stdout}'.trim();
    } else {
      path = Link('/proc/$pid/exe').resolveSymbolicLinksSync();
    }
  } on Object {
    return false;
  }
  if (path == null || path.isEmpty) return false;
  String norm(String v) {
    final String n = v.replaceAll(r'\', '/');
    return Platform.isWindows ? n.toLowerCase() : n;
  }

  return norm(path) == norm(File(executable).absolute.path);
}

bool _defaultPidKill(int pid) {
  try {
    return Process.killPid(pid);
  } on Object {
    return false;
  }
}

/// 自起服务的 pid 记录文件名（放在整合包根，即启动的工作目录）。
const String kGptSovitsPidFileName = '.fushi_gpt_sovits.pid';

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
    GptSovitsPidOwnerCheck? pidOwnerCheck,
    GptSovitsPidKill? pidKill,
    this.readyTimeout = const Duration(minutes: 5),
    this.probeInterval = const Duration(seconds: 1),
  }) : _spawn = spawn ?? _registrySpawn,
       _probe = probe ?? gptSovitsDefaultProbe,
       _pidOwnerCheck = pidOwnerCheck ?? gptSovitsDefaultPidOwnerCheck,
       _pidKill = pidKill ?? _defaultPidKill;

  final GptSovitsSpawn _spawn;
  final GptSovitsProbe _probe;
  final GptSovitsPidOwnerCheck _pidOwnerCheck;
  final GptSovitsPidKill _pidKill;

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

  /// 每次 [stop] / [dispose] 自增：进行中的 [_start] 每个 await 之后比对，变了就说明
  /// 这次启动已被取消，不再 spawn / 不再置 running，已 spawn 的进程立即杀掉。
  int _generation = 0;

  /// 端口上已有别人起的服务、本对象直接借用（不拥有进程，停不了它）。
  bool _external = false;

  /// 端口上是上次（崩溃前）本 app 从同一整合包起的服务：按 pid 认领，可以停。
  int? _adoptedPid;
  final List<String> _log = <String>[];

  GptSovitsServerPhase get phase => _phase;
  GptSovitsServerFailure? get failure => _failure;
  bool get isRunning => _phase == GptSovitsServerPhase.running;

  /// 正在运行（或启动中）的服务地址；没起返回 null。
  String? get endpoint => _owns ? _spec?.endpoint : null;
  int? get port => _owns ? _spec?.port : null;

  /// 服务是不是借用的外部进程（UI 据此说明「停止」停不了它）。
  bool get isExternal => _external && isRunning;

  bool get _owns =>
      _process != null || ((_external || _adoptedPid != null) && isRunning);
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

  static File _pidFile(GptSovitsLaunchSpec spec) => File(
    '${spec.workingDirectory}${Platform.pathSeparator}'
    '$kGptSovitsPidFileName',
  );

  void _writePidFile(GptSovitsLaunchSpec spec, int pid) {
    try {
      _pidFile(spec).writeAsStringSync(
        jsonEncode(<String, Object?>{'pid': pid, 'port': spec.port}),
      );
    } on FileSystemException {
      // 写不出来只是失去「崩溃后认领」的能力，不挡启动。
    }
  }

  void _deletePidFile(GptSovitsLaunchSpec spec, int pid) {
    final File file = _pidFile(spec);
    try {
      if (_readPid(file, spec.port) == pid) file.deleteSync();
    } on FileSystemException {
      // 同上。
    }
  }

  static int? _readPid(File file, int port) {
    try {
      if (!file.existsSync()) return null;
      final Object? raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map || raw['port'] != port) return null;
      final Object? pid = raw['pid'];
      return pid is int && pid > 0 ? pid : null;
    } on Object {
      return null;
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
      _start(spec, _generation)
          .then(
            completer.complete,
            onError: (Object e) {
              completer.complete(false);
            },
          )
          .whenComplete(() {
            if (identical(_starting, completer)) _starting = null;
          }),
    );
    return completer.future;
  }

  Future<bool> _start(GptSovitsLaunchSpec spec, int generation) async {
    bool cancelled() => generation != _generation;
    if (!File(spec.executable).existsSync()) {
      _set(GptSovitsServerPhase.failed, GptSovitsServerFailure.notInstalled);
      return false;
    }
    // 端口上已经有一个 GPT-SoVITS 服务：上次 app 崩溃留下的（pid 文件对得上、映像
    // 就是本整合包的 python）→ 认领，停止按钮可用；否则（用户自己手动起的）直接借用，
    // 不再起第二个抢显存，这种情况下本对象不拥有进程，停止按钮也停不了它。
    _log.clear();
    _spec = spec;
    _external = false;
    _adoptedPid = null;
    _set(GptSovitsServerPhase.starting);
    final bool alreadyServing = await _probe(spec.port);
    if (cancelled()) return false;
    if (alreadyServing) {
      final int? pid = _readPid(_pidFile(spec), spec.port);
      final bool ours =
          pid != null && await _pidOwnerCheck(pid, spec.executable);
      if (cancelled()) return false;
      if (ours) {
        _adoptedPid = pid;
        _appendLog('[adopted the service left by a previous run, pid $pid]');
      } else {
        _external = true;
        _appendLog('[reusing the service already listening on ${spec.port}]');
      }
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
      if (cancelled()) return false;
      _appendLog(e.message);
      _set(GptSovitsServerPhase.failed, GptSovitsServerFailure.spawnFailed);
      return false;
    }
    if (cancelled()) {
      // spawn 期间用户点了停止 / app 在退出：刚起的进程不能留成孤儿。
      process.kill();
      return false;
    }
    _process = process;
    _writePidFile(spec, process.pid);
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
        _deletePidFile(spec, process.pid);
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
      if (exited || !identical(_process, process) || cancelled()) return false;
      final bool ready = await _probe(spec.port);
      if (exited || !identical(_process, process) || cancelled()) return false;
      if (ready) {
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

  /// 停止本对象起的（或认领的）服务并等它真正退出（释放显存与端口）。启动中调用
  /// 会取消那次启动：不再 spawn，已 spawn 的进程一并杀掉。
  Future<void> stop() async {
    _generation++;
    _starting = null;
    final Process? process = _process;
    final int? adopted = _adoptedPid;
    final GptSovitsLaunchSpec? spec = _spec;
    _process = null;
    _adoptedPid = null;
    _external = false;
    _set(GptSovitsServerPhase.stopped);
    if (adopted != null) {
      _pidKill(adopted);
      if (spec != null) _deletePidFile(spec, adopted);
    }
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
    _generation++;
    _process?.kill();
    _process = null;
    super.dispose();
  }
}
