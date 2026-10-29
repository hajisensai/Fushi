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
/// - 调度不经调用方的 zone：取 worker、发命令、收回执、归还 worker、把下一条排队命令发出去，全在回执端口
///   （根 zone）与池子自己的回调里做，调用方只拿到一个在它自己 zone 里完成的 Future。调用方的 zone 可能再也
///   不跑微任务（widget 测试结束后的 FakeAsync、没人 await 的发后不理命令，如页面 dispose 时关掉原生会话）：
///   若在调用方的 `await` 之后才归还 / 发命令，那个 worker 就永远「在途」，池子耗尽后所有命令都挂住。
///   也不能把整条链挪进 `Zone.root.run`：错误不能跨 error zone 传给调用方的监听（会变成根 zone 的未捕获错误）。
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
  final Queue<_Job<Object?>> _waiting = Queue<_Job<Object?>>();
  int _live = 0;

  /// 已起的 worker 数（测试看复用）。
  int get debugSpawned => _spawnedTotal;
  int _spawnedTotal = 0;

  /// 在 worker 里对 [address] 的句柄执行 [job]。
  Future<T> run<T>(int address, SrsCoreJob<T> job) {
    final Completer<T> done = Completer<T>();
    _submit(
      _Job<Object?>(
        address,
        job,
        (Object? value) => done.complete(value as T),
        done.completeError,
      ),
    );
    return done.future;
  }

  void _submit(_Job<Object?> j) {
    if (_idle.isNotEmpty) {
      _dispatch(_idle.removeLast(), j);
    } else if (_live < maxWorkers) {
      _spawnFor(j);
    } else {
      _waiting.add(j);
    }
  }

  /// 起一个新 worker 跑 [j]。起 isolate 的回调挂在根 zone 上（见库注释）。
  void _spawnFor(_Job<Object?> j) {
    _live++;
    _spawnedTotal++;
    Zone.root.run(
      () => _Worker.spawn(libraryPath).then(
        (_Worker w) => _dispatch(w, j),
        onError: (Object e, StackTrace s) {
          _live--;
          j.fail(e, s);
        },
      ),
    );
  }

  void _dispatch(_Worker w, _Job<Object?> j) {
    w.send(j.address, j.job, (
      bool healthy,
      Object? value,
      Object? error,
      StackTrace? stack,
    ) {
      // 先归还（并发出下一条排队命令），再把结果交给调用方。
      _release(w, healthy: healthy);
      if (error == null) {
        j.ok(value);
      } else {
        j.fail(error, stack ?? StackTrace.empty);
      }
    });
  }

  void _release(_Worker w, {required bool healthy}) {
    if (!healthy) {
      _live--;
      w.kill();
      // 让一条排队的命令去起新的 worker。
      if (_waiting.isNotEmpty) _spawnFor(_waiting.removeFirst());
      return;
    }
    if (_waiting.isNotEmpty) {
      _dispatch(w, _waiting.removeFirst());
    } else {
      _idle.add(w);
    }
  }
}

/// 一条排队 / 在途的命令：结果经 [ok] / [fail] 交回调用方的 Completer。
final class _Job<T> {
  _Job(this.address, this.job, this.ok, this.fail);

  final int address;
  final SrsCoreJob<T> job;
  final void Function(Object? value) ok;
  final void Function(Object error, StackTrace stack) fail;
}

final class _WorkerDied implements Exception {
  const _WorkerDied();

  @override
  String toString() => 'SrsCoreWorkers: worker isolate exited mid-command';
}

/// 一条在途命令的回执标记（worker 退出时的 onExit 消息）。
const String _kExited = 'srs-core-worker-exited';

/// [_Worker.send] 的回执：worker 是否还健康、结果或错误。
typedef _Reply =
    void Function(
      bool healthy,
      Object? value,
      Object? error,
      StackTrace? stack,
    );

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

  /// 发一条命令；回执到了在根 zone 里调 [onReply]（RawReceivePort 的处理函数在根 zone 跑）。
  void send(int address, Object? job, _Reply onReply) {
    final RawReceivePort reply = RawReceivePort();
    reply.handler = (Object? m) {
      reply.close();
      _isolate.removeOnExitListener(reply.sendPort);
      if (m == _kExited) {
        onReply(false, null, const _WorkerDied(), null);
        return;
      }
      final (bool ok, Object? value, String? stack) =
          m! as (bool, Object?, String?);
      if (ok) {
        onReply(true, value, null, null);
      } else {
        onReply(
          true,
          null,
          value!,
          stack == null ? StackTrace.empty : StackTrace.fromString(stack),
        );
      }
    };
    _isolate.addOnExitListener(reply.sendPort, response: _kExited);
    // 原样发 [job]（调用方在顶层函数里造的闭包）：在这里另包一层会把 worker 自己带进闭包上下文。
    _inbox.send((address, job, reply.sendPort));
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
