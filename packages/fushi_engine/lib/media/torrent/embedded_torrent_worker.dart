import 'dart:async';
import 'dart:isolate';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_backend.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
import 'package:meta/meta.dart';

/// 内置 libtorrent 的专用工作 isolate（BUG-3577）。
///
/// 为什么整个 [EmbeddedTorrentHost] 都搬进来、而不是只搬 session：
/// libtorrent 的 `session_handle` 查询（`get_torrents` / `status` / 逐种子
/// `find_torrent`）全是**同步等网络线程回话**的调用，启动加载 fastResume、
/// 磁盘慢、种子多时一次就能卡几秒。以前整套宿主在 UI isolate 上同步驱动，
/// `sweepUploadPolicy` 首轮的 `ht_set_upload_mode → get_torrents` 直接把界面
/// 冻到看门狗写 hang dump。宿主自己每个 tick 又要对 session 做 N 次往返
/// （反吸血逐种子取 peer、发现协议门控反复列种子）——只搬 session 等于把每次
/// 往返都换成跨 isolate 消息，边界更碎；把**策略连同 session** 一起搬过来，
/// UI isolate 只发粗粒度命令（「扫一轮上传策略」「列一次种子」），一个 tick
/// 只有个位数消息。
///
/// 原生桥 `ht_session_ctx` 无锁、依赖「调用方天然串行」：本 isolate 是 session
/// 的唯一调用者、命令逐条执行（每条命令同步跑完才取下一条，见
/// [_EmbeddedTorrentWorkerState.handle]），这个前提原样成立。
///
/// 主 isolate 一侧的客户端是 [EmbeddedTorrentHostClient]。
typedef EmbeddedTorrentHostFactory =
    EmbeddedTorrentHost? Function(EmbeddedTorrentHostOpenArgs args);

/// 打开宿主所需的全部参数（跨 isolate 发送，只含可发送的纯数据）。
@immutable
class EmbeddedTorrentHostOpenArgs {
  const EmbeddedTorrentHostOpenArgs({
    this.libraryPath,
    required this.baseSavePath,
    this.legacySavePaths = const <String>[],
    required this.resumeDir,
    this.restoreIds,
    this.listenInterfaces = '0.0.0.0:6881,[::]:6881',
    this.enableDht = true,
  });

  final String? libraryPath;
  final String baseSavePath;
  final List<String> legacySavePaths;
  final String resumeDir;
  final Set<String>? restoreIds;
  final String listenInterfaces;
  final bool enableDht;
}

/// 生产工厂：真 DLL + 真 session（[EmbeddedTorrentHost.open]）。
EmbeddedTorrentHost? openEmbeddedTorrentHost(EmbeddedTorrentHostOpenArgs args) {
  return EmbeddedTorrentHost.open(
    libraryPath: args.libraryPath,
    baseSavePath: args.baseSavePath,
    legacySavePaths: args.legacySavePaths,
    resumeDir: args.resumeDir,
    restoreIds: args.restoreIds,
    listenInterfaces: args.listenInterfaces,
    enableDht: args.enableDht,
  );
}

/// 工作 isolate 里执行的一条命令。**必须由顶层函数构造**：闭包只捕获参数，
/// 不能捕获客户端实例（它持有 [ReceivePort]，不可发送）。
typedef EmbeddedTorrentCommand<R> =
    FutureOr<R> Function(EmbeddedTorrentWorkerState state);

/// 工作 isolate 内的状态：宿主 + 客户端派发出去的 backend 视图。
///
/// 只在工作 isolate 里存在；主 isolate 经 [EmbeddedTorrentCommand] 访问。
abstract interface class EmbeddedTorrentWorkerState {
  EmbeddedTorrentHost get host;

  /// 取客户端登记过的 backend 视图（见 [EmbeddedTorrentHostClient.backendView]）。
  EmbeddedTorrentBackend view(int viewId);

  /// 新建并登记一个 backend 视图。
  void openView(int viewId);

  /// 释放视图（短命适配器 close 时调用；不关 session）。
  void closeView(int viewId);

  /// 关宿主（强制存 resume + 关 session），幂等。关闭命令与工作 isolate 退出
  /// 前的兜底都走这里，同一个 session 只关一次。
  void disposeHost({Set<String>? keepIds});
}

class _EmbeddedTorrentWorkerState implements EmbeddedTorrentWorkerState {
  _EmbeddedTorrentWorkerState(this.host);

  @override
  final EmbeddedTorrentHost host;

  final Map<int, EmbeddedTorrentBackend> _views =
      <int, EmbeddedTorrentBackend>{};

  @override
  EmbeddedTorrentBackend view(int viewId) {
    final EmbeddedTorrentBackend? view = _views[viewId];
    if (view == null) {
      throw StateError('embedded torrent backend view $viewId is not open');
    }
    return view;
  }

  @override
  void openView(int viewId) {
    // 订阅 tracker 由主 isolate 的代理在 add 之后补（拉订阅要用 app 装配的
    // 代理感知 http client，带不过 isolate 边界）；这里的视图只认宿主级附加
    // tracker。
    _views[viewId] = host.backendView();
  }

  @override
  void closeView(int viewId) {
    _views.remove(viewId)?.close();
  }

  bool _hostDisposed = false;

  @override
  void disposeHost({Set<String>? keepIds}) {
    if (_hostDisposed) return;
    _hostDisposed = true;
    host.dispose(keepIds: keepIds);
  }
}

/// 关闭请求：工作 isolate 回完应答后退出事件循环。
class _Shutdown {
  const _Shutdown(this.id);

  final int id;
}

/// 发往工作 isolate 的一条请求。
class _Request {
  const _Request(this.id, this.command);

  final int id;
  final EmbeddedTorrentCommand<Object?> command;
}

/// 工作 isolate 回给主 isolate 的一条应答。
class _Response {
  const _Response(this.id, this.value, this.error, this.stack);

  final int id;
  final Object? value;
  final String? error;
  final String? stack;
}

/// 工作 isolate 的日志转发（`fushiDebugPrint` / `engineLog` 的装配点带不过
/// isolate 边界，不转发的话 `[torrent]` 诊断日志进不了用户上传的日志文件）。
sealed class _LogRecord {
  const _LogRecord();
}

class _DebugPrintRecord extends _LogRecord {
  const _DebugPrintRecord(this.message);

  final String? message;
}

class _EngineLogRecord extends _LogRecord {
  const _EngineLogRecord(this.level, this.source, this.message, this.stack);

  /// 0 = log，1 = diagnostic，2 = fatal。
  final int level;
  final String source;
  final String message;
  final String? stack;
}

class _ForwardingEngineLogSink implements EngineLogSink {
  const _ForwardingEngineLogSink(this._port);

  final SendPort _port;

  @override
  void log(String source, Object error, [StackTrace? stack]) =>
      _port.send(_EngineLogRecord(0, source, '$error', stack?.toString()));

  @override
  void logDiagnostic(String source, Object info) =>
      _port.send(_EngineLogRecord(1, source, '$info', null));

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) =>
      _port.send(_EngineLogRecord(2, source, '$error', stack?.toString()));
}

/// 工作 isolate 的启动参数。
class _WorkerBoot {
  const _WorkerBoot({
    required this.handshakePort,
    required this.logPort,
    required this.factory,
    required this.args,
  });

  final SendPort handshakePort;
  final SendPort logPort;
  final EmbeddedTorrentHostFactory factory;
  final EmbeddedTorrentHostOpenArgs args;
}

/// 握手应答：宿主打不开时 [requestPort] 为 null。
class _Handshake {
  const _Handshake(this.requestPort, this.capabilities, this.hasRestored);

  final SendPort? requestPort;
  final EmbeddedTorrentHostCapabilities? capabilities;
  final bool hasRestored;
}

void _workerMain(_WorkerBoot boot) {
  final SendPort logPort = boot.logPort;
  fushiDebugPrint = (String? message, {int? wrapWidth}) =>
      logPort.send(_DebugPrintRecord(message));
  engineLog = _ForwardingEngineLogSink(logPort);

  final ReceivePort requests = ReceivePort('embedded-torrent-worker');
  // 未捕获的错误不许直接打死本 isolate：默认 errorsAreFatal 下 isolate 当场
  // 终止，[_serveWorker] 的 finally 根本不跑，原生 session 留在进程里（监听
  // 端口、DHT、磁盘句柄都还占着），主 isolate 再起一个也绑不上同一端口。
  // 这里记一笔后关请求端口：命令循环随之结束，finally 关 session，isolate
  // 再自然退出（主 isolate 由 onExit 得知）。
  runZonedGuarded<void>(() => unawaited(_serveWorker(boot, requests)), (
    Object error,
    StackTrace stack,
  ) {
    engineLog.log('EmbeddedTorrentWorker.uncaught', error, stack);
    requests.close();
  });
}

Future<void> _serveWorker(_WorkerBoot boot, ReceivePort requests) async {
  final EmbeddedTorrentHost? host;
  try {
    host = boot.factory(boot.args);
  } on Object catch (e, s) {
    engineLog.log('EmbeddedTorrentWorker.open', e, s);
    requests.close();
    boot.handshakePort.send(const _Handshake(null, null, false));
    return;
  }
  if (host == null) {
    requests.close();
    boot.handshakePort.send(const _Handshake(null, null, false));
    return;
  }
  final _EmbeddedTorrentWorkerState state = _EmbeddedTorrentWorkerState(host);
  boot.handshakePort.send(
    _Handshake(requests.sendPort, host.capabilities, host.hasRestored),
  );

  // 命令**逐条**执行：上一条（含其中的 await）完全结束才取下一条。原生桥
  // 无锁、依赖调用方串行；backend 的 add 路径里还有 begin/endNetworkWake
  // 包住同步 add 的不变量，交错执行会让并发 add 提前收回发现协议。
  SendPort? replyPort;
  int? shutdownId;
  try {
    await for (final Object? message in requests) {
      if (message is SendPort) {
        replyPort = message;
        continue;
      }
      if (message is _Shutdown) {
        shutdownId = message.id;
        break;
      }
      if (message is! _Request) continue;
      Object? value;
      String? error;
      String? stack;
      try {
        value = await message.command(state);
      } on Object catch (e, s) {
        error = '$e';
        stack = '$s';
      }
      // 结果不可发送时这里同步抛出：落到外层 finally（关 session），错误本身
      // 交给 [_workerMain] 的守护 zone 记录。
      replyPort?.send(_Response(message.id, value, error, stack));
    }
  } finally {
    requests.close();
    // 无论怎么离开循环（正常关闭 / 命令处理之外的未捕获错误 / 请求端口被守护
    // zone 关掉），session 都在本 isolate 退出前关掉。正常关闭路径上关闭前的
    // 最后一条命令已经 dispose 过，这里是幂等的 no-op。
    try {
      state.disposeHost();
    } on Object catch (e, s) {
      engineLog.log('EmbeddedTorrentWorker.dispose', e, s);
    }
    // 关闭应答排在 session 真正关掉之后：主 isolate 拿到它时端口已经释放。
    if (shutdownId != null) {
      replyPort?.send(_Response(shutdownId, null, null, null));
    }
  }
}

/// 工作 isolate 里命令抛出的错误（原错误只剩文本——异常对象不一定可发送）。
class EmbeddedTorrentWorkerError extends Error {
  EmbeddedTorrentWorkerError(this.message, this.remoteStack);

  final String message;
  final String? remoteStack;

  @override
  String toString() => 'EmbeddedTorrentWorkerError: $message';
}

/// 工作 isolate 已经退出（关闭后再调用 / isolate 意外死亡）。
class EmbeddedTorrentWorkerClosed extends Error {
  @override
  String toString() => 'EmbeddedTorrentWorkerClosed';
}

/// 工作 isolate 的传输层：起 isolate、握手、请求/应答配对、日志回放、关闭。
///
/// 只关心「把命令送过去、把结果带回来」；宿主 API 的异步镜像在
/// [EmbeddedTorrentHostClient]。
class EmbeddedTorrentWorker {
  EmbeddedTorrentWorker._({
    required Isolate isolate,
    required SendPort requestPort,
    required ReceivePort responses,
    required ReceivePort logs,
    required ReceivePort exits,
    required this.capabilities,
    required this.hasRestoredAtOpen,
  }) : _isolate = isolate,
       _requestPort = requestPort,
       _responses = responses,
       _logs = logs,
       _exits = exits;

  final Isolate _isolate;
  final SendPort _requestPort;
  final ReceivePort _responses;
  final ReceivePort _logs;
  final ReceivePort _exits;

  final EmbeddedTorrentHostCapabilities capabilities;

  /// open 内首次恢复是否已用真实计划集合跑过（见 [EmbeddedTorrentHost.hasRestored]）。
  final bool hasRestoredAtOpen;

  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 0;
  bool _closed = false;
  bool _exitedUnexpectedly = false;
  final Completer<void> _closedSignal = Completer<void>();

  bool get isClosed => _closed;

  /// 本端收尾完成时完成（[close] 主动关闭，或工作 isolate 意外退出）。从不以
  /// 错误完成。持有方据此把已经失效的客户端摘下来，下次需要时重建。
  Future<void> get closed => _closedSignal.future;

  /// 工作 isolate 是否在没有经过 [close] 的情况下退出了。
  bool get exitedUnexpectedly => _exitedUnexpectedly;

  /// 起工作 isolate 并在其中用 [factory] 打开宿主。宿主打不开（DLL 缺失 /
  /// session 创建失败）返回 null，isolate 随之退出。
  ///
  /// [factory] 必须是顶层或静态函数（要发送进工作 isolate）。
  static Future<EmbeddedTorrentWorker?> spawn(
    EmbeddedTorrentHostOpenArgs args, {
    EmbeddedTorrentHostFactory factory = openEmbeddedTorrentHost,
  }) async {
    final ReceivePort handshake = ReceivePort('embedded-torrent-handshake');
    final ReceivePort logs = ReceivePort('embedded-torrent-log');
    final ReceivePort exits = ReceivePort('embedded-torrent-exit');
    logs.listen(_replayLog);
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn<_WorkerBoot>(
        _workerMain,
        _WorkerBoot(
          handshakePort: handshake.sendPort,
          logPort: logs.sendPort,
          factory: factory,
          args: args,
        ),
        debugName: 'embedded-torrent',
        onExit: exits.sendPort,
      );
    } on Object catch (e, s) {
      engineLog.log('EmbeddedTorrentWorker.spawn', e, s);
      handshake.close();
      logs.close();
      exits.close();
      return null;
    }
    // ReceivePort 只能订阅一次：退出端口全程一个订阅，握手前通知握手失败
    // （工作 isolate 在握手前就死掉时 onExit 先到），握手后交给 worker。
    final Completer<_Handshake?> shake = Completer<_Handshake?>();
    EmbeddedTorrentWorker? opened;
    exits.listen((_) {
      final EmbeddedTorrentWorker? worker = opened;
      if (worker != null) {
        worker._onExit();
      } else if (!shake.isCompleted) {
        shake.complete(null);
      }
    });
    handshake.listen((Object? message) {
      if (!shake.isCompleted && message is _Handshake) shake.complete(message);
    });
    final _Handshake? reply = await shake.future;
    handshake.close();
    final SendPort? requestPort = reply?.requestPort;
    if (reply == null || requestPort == null) {
      logs.close();
      exits.close();
      return null;
    }
    final ReceivePort responses = ReceivePort('embedded-torrent-response');
    requestPort.send(responses.sendPort);
    final EmbeddedTorrentWorker worker = opened = EmbeddedTorrentWorker._(
      isolate: isolate,
      requestPort: requestPort,
      responses: responses,
      logs: logs,
      exits: exits,
      capabilities: reply.capabilities!,
      hasRestoredAtOpen: reply.hasRestored,
    );
    responses.listen(worker._onResponse);
    return worker;
  }

  /// 在工作 isolate 里执行 [command]，返回其结果。命令按发送顺序逐条执行。
  Future<R> run<R>(EmbeddedTorrentCommand<R> command) {
    if (_closed) return Future<R>.error(EmbeddedTorrentWorkerClosed());
    final int id = _nextId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    _requestPort.send(_Request(id, command));
    return completer.future.then((Object? value) => value as R);
  }

  Future<void> _requestShutdown() {
    final int id = _nextId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    _requestPort.send(_Shutdown(id));
    return completer.future;
  }

  /// 执行 [finalCommand]（如退出前存 resume + 关 session）后关闭工作 isolate。
  /// 幂等；之后的 [run] 一律以 [EmbeddedTorrentWorkerClosed] 失败。
  Future<void> close([EmbeddedTorrentCommand<Object?>? finalCommand]) async {
    if (_closed) return;
    try {
      if (finalCommand != null) await run<Object?>(finalCommand);
    } on Object catch (e, s) {
      engineLog.log('EmbeddedTorrentWorker.close', e, s);
    }
    if (_closed) return;
    try {
      await _requestShutdown();
    } on Object {
      // isolate 已退出：下面照样收尾。
    }
    _shutDownLocally();
  }

  void _onResponse(Object? message) {
    if (message is! _Response) return;
    final Completer<Object?>? completer = _pending.remove(message.id);
    if (completer == null) return;
    final String? error = message.error;
    if (error != null) {
      completer.completeError(
        EmbeddedTorrentWorkerError(error, message.stack),
        message.stack == null ? null : StackTrace.fromString(message.stack!),
      );
    } else {
      completer.complete(message.value);
    }
  }

  void _onExit() {
    if (_closed) return;
    _exitedUnexpectedly = true;
    engineLog.log(
      'EmbeddedTorrentWorker',
      StateError('embedded torrent isolate exited unexpectedly'),
    );
    _shutDownLocally();
  }

  void _shutDownLocally() {
    if (_closed) return;
    _closed = true;
    final List<Completer<Object?>> pending = _pending.values.toList();
    _pending.clear();
    for (final Completer<Object?> completer in pending) {
      completer.completeError(EmbeddedTorrentWorkerClosed());
    }
    _responses.close();
    _logs.close();
    _exits.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _closedSignal.complete();
  }

  static void _replayLog(Object? message) {
    switch (message) {
      case _DebugPrintRecord(:final String? message):
        fushiDebugPrint(message);
      case _EngineLogRecord(
        :final int level,
        :final String source,
        :final String message,
        :final String? stack,
      ):
        final StackTrace? trace = stack == null
            ? null
            : StackTrace.fromString(stack);
        switch (level) {
          case 1:
            engineLog.logDiagnostic(source, message);
          case 2:
            engineLog.logFatal(source, message, trace);
          default:
            engineLog.log(source, message, trace);
        }
    }
  }
}
