/// 内核命令的常驻后台 isolate 池（同步 v2 / 排队 / 预览 / 血统 / 优化器与 RWKV 直读）。
///
/// 以前每条命令 `Isolate.run` 新起一个 isolate：起 isolate、重新 dlopen、解析二十几个符号
/// （`SrsCoreBindings`），一次评分要来回几次。现在 worker 常驻、复用：每个 worker 只在第一次用到某个句柄时
/// 包一次 [SrsCore]（符号解析一次），之后只发命令。
///
/// - 并发：命令可能很慢（收段一片、状态摘要、全量回放），一个 worker 会把快命令（复习时的预览 / 排队）挡在
///   后面，所以是个小池子：有空闲的就用，都忙且没到上限就再起一个，到上限排队。与 `Isolate.run` 一样，
///   同时在途的命令各在自己的 isolate 上调进内核，库内部的读 / 写连接锁照旧决定谁等谁。
/// - 发送：命令是一个只捕获可发送数据（句柄地址、请求、字节块）的闭包——写成顶层函数造闭包，不捕获
///   `SrsDbStore`（它带着 Drift 连接与 Future，不可发送）。
/// - worker 意外退出（原生崩溃以外的致命错误）：在途命令报错，那个 worker 丢弃，之后按需再起。
/// - 归还 worker 不经调用方的 zone：回执在根 zone 里收、收到就先归还，再把结果交给调用方。调用方的 zone
///   可能再也不跑微任务（widget 测试结束后的 FakeAsync、已经没人 await 的发后不理命令，如页面 dispose
///   时关掉原生会话），若在调用方的 `finally` 里归还，那个 worker 就永远「在途」，池子耗尽后所有命令都挂住。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:fushi_srs/fushi_srs.dart' show SrsCore;

/// 在 worker 里对内核句柄执行的一条命令。
typedef SrsCoreJob<T> = T Function(SrsCore core);

final class SrsCoreWorkers {
  SrsCoreWorkers._(this.libraryPath);

  static final Map<String?, SrsCoreWorkers> _pools =
      <String?, SrsCoreWorkers>{};

  /// 按库路径一个池（null = 默认定位规则加载的库）。
  static SrsCoreWorkers of(String? libraryPath) =>
      _pools.putIfAbsent(libraryPath, () => SrsCoreWorkers._(libraryPath));

  /// 同时在途的命令数上限（超过排队）。
  static const int maxWorkers = 4;

  final String? libraryPath;
  final List<_Worker> _idle = <_Worker>[];
  final Queue<Completer<_Worker>> _waiting = Queue<Completer<_Worker>>();
  int _live = 0;

  /// 已起的 worker 数（测试看复用）。
  int get debugSpawned => _spawnedTotal;
  int _spawnedTotal = 0;

  /// 在 worker 里对 [address] 的句柄执行 [job]。取 worker、发命令、归还都在根 zone 里走（见库注释）；
  /// 调用方只在自己的 zone 里等结果。
  Future<T> run<T>(int address, SrsCoreJob<T> job) => Zone.root.run(() async {
    final _Worker w = await _acquire();
    return w.run<T>(
      address,
      job,
      onSettled: (bool healthy) => _release(w, healthy: healthy),
    );
  });

  Future<_Worker> _acquire() async {
    if (_idle.isNotEmpty) return _idle.removeLast();
    if (_live < maxWorkers) {
      _live++;
      try {
        _spawnedTotal++;
        return await _Worker.spawn(libraryPath);
      } catch (_) {
        _live--;
        rethrow;
      }
    }
    final Completer<_Worker> c = Completer<_Worker>();
    _waiting.add(c);
    return c.future;
  }

  void _release(_Worker w, {required bool healthy}) {
    if (!healthy) {
      _live--;
      w.kill();
      // 让一个排队的命令去起新的 worker。
      if (_waiting.isNotEmpty) {
        final Completer<_Worker> next = _waiting.removeFirst();
        _live++;
        _spawnedTotal++;
        _Worker.spawn(libraryPath).then(
          next.complete,
          onError: (Object e, StackTrace s) {
            _live--;
            next.completeError(e, s);
          },
        );
      }
      return;
    }
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(w);
    } else {
      _idle.add(w);
    }
  }
}

final class _WorkerDied implements Exception {
  const _WorkerDied();

  @override
  String toString() => 'SrsCoreWorkers: worker isolate exited mid-command';
}

/// 一条在途命令的回执标记（worker 退出时的 onExit 消息）。
const String _kExited = 'srs-core-worker-exited';

final class _Worker {
  _Worker._(this._isolate, this._inbox);

  final Isolate _isolate;
  final SendPort _inbox;

  static Future<_Worker> spawn(String? libraryPath) async {
    final ReceivePort ready = ReceivePort();
    final Isolate iso = await Isolate.spawn<(SendPort, String?)>(_workerMain, (
      ready.sendPort,
      libraryPath,
    ), debugName: 'srs-core-worker');
    final SendPort inbox = await ready.first as SendPort;
    return _Worker._(iso, inbox);
  }

  /// [onSettled] 在根 zone 里、回执一到就调（先于 [run] 返回的 Future 完成；`false` = worker 已退出）。
  Future<T> run<T>(
    int address,
    SrsCoreJob<T> job, {
    required void Function(bool healthy) onSettled,
  }) {
    final Completer<T> done = Completer<T>();
    // RawReceivePort 的处理函数在根 zone 跑：在这里归还，不受调用方 zone 是否还跑微任务的影响。
    final RawReceivePort reply = RawReceivePort();
    reply.handler = (Object? m) {
      reply.close();
      _isolate.removeOnExitListener(reply.sendPort);
      if (m == _kExited) {
        onSettled(false);
        done.completeError(const _WorkerDied());
        return;
      }
      onSettled(true);
      final (bool ok, Object? value, String? stack) =
          m! as (bool, Object?, String?);
      if (ok) {
        done.complete(value as T);
      } else {
        done.completeError(
          value!,
          stack == null ? StackTrace.empty : StackTrace.fromString(stack),
        );
      }
    };
    _isolate.addOnExitListener(reply.sendPort, response: _kExited);
    // 原样发 [job]（调用方在顶层函数里造的闭包）：在这里另包一层会把 worker 自己带进闭包上下文。
    _inbox.send((address, job, reply.sendPort));
    return done.future;
  }

  void kill() => _isolate.kill(priority: Isolate.immediate);
}

void _workerMain((SendPort, String?) init) {
  final (SendPort ready, String? libraryPath) = init;
  final ReceivePort inbox = ReceivePort();
  final Map<int, SrsCore> cores = <int, SrsCore>{};
  ready.send(inbox.sendPort);
  inbox.listen((Object? m) {
    final (int address, Object? Function(SrsCore) job, SendPort reply) =
        m! as (int, Object? Function(SrsCore), SendPort);
    try {
      final SrsCore core = cores[address] ??= SrsCore.fromAddress(
        address,
        libraryPath: libraryPath,
      );
      reply.send((true, job(core), null));
    } catch (e, st) {
      try {
        reply.send((false, e, st.toString()));
      } on ArgumentError {
        // 错误对象不可发送：交回它的文字。
        reply.send((false, StateError(e.toString()), st.toString()));
      }
    }
  });
}
