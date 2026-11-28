import 'dart:async';

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

/// 资源收尾时抛出的错误交给谁记（生产接 `ErrorLogService`，测试可截获）。
typedef ResourceErrorSink =
    void Function(String scope, Object error, StackTrace stack);

/// 某个资源的收尾动作。
typedef ResourceClose<T> = FutureOr<void> Function(T resource);

/// 经已关闭（或正在关闭）的生命周期取连接 / 登记资源时抛出。
///
/// 类型化的意义：漏挂在旧连接上的调用方拿到的是「这一代已经结束」的明确信号，而不是
/// drift 的「connection was closed」——后者常被下游的 try 吞成 debugPrint，于是表现成
/// 静默退化（BUG-1569 / BUG-1647 那一类）。
final class DatabaseSessionClosedException implements Exception {
  const DatabaseSessionClosedException(this.owner, this.operation);

  /// 哪一个生命周期（[DatabaseSession.label] / [ProcessLifetime.label]）。
  final String owner;

  /// 被拒绝的操作（`database` / `own(<label>)` …）。
  final String operation;

  @override
  String toString() =>
      'DatabaseSessionClosedException: $owner is closed, rejected $operation';
}

/// 一个登记项：资源 + 它的收尾动作，保证至多执行一次。
final class _Entry {
  _Entry(this.resource, this.label, this._close);

  final Object? resource;
  final String label;
  final FutureOr<void> Function() _close;
  bool _done = false;

  Future<void> run(ResourceErrorSink onError, String owner) async {
    if (_done) return;
    _done = true;
    try {
      await _close();
    } catch (e, stack) {
      onError('$owner.close($label)', e, stack);
    }
  }
}

/// 逆序关闭的资源栈：[DatabaseSession] 与 [ProcessLifetime] 共用的机制。
///
/// 每个资源在**创建处**登记一次（[own]），关闭时按登记的逆序逐个收尾，每个恰好一次；
/// 一个收尾抛错只记日志，不挡后面的。关闭后再登记直接抛 [DatabaseSessionClosedException]，
/// 不允许「关完之后又挂上一个没人收的」。
final class _ResourceStack {
  _ResourceStack(this.owner, this.onError);

  final String owner;
  final ResourceErrorSink onError;
  final List<_Entry> _entries = <_Entry>[];
  bool _sealed = false;

  T own<T>(T resource, ResourceClose<T> close, String label) {
    if (_sealed) {
      throw DatabaseSessionClosedException(owner, 'own($label)');
    }
    _entries.add(_Entry(resource, label, () => close(resource)));
    return resource;
  }

  Future<void> release(Object resource) async {
    final int index = _entries.lastIndexWhere(
      (_Entry e) => identical(e.resource, resource),
    );
    if (index < 0) return;
    final _Entry entry = _entries.removeAt(index);
    await entry.run(onError, owner);
  }

  bool owns(Object resource) =>
      _entries.any((_Entry e) => identical(e.resource, resource));

  Future<void> closeAll() async {
    _sealed = true;
    while (_entries.isNotEmpty) {
      await _entries.removeLast().run(onError, owner);
    }
  }
}

/// 一次「打开的主库连接」的生命周期（架构重构 F6，审计 db-bound-lifecycle-manual-teardown）。
///
/// 绑在这个连接上的一切——仓库、观察者 / 表订阅、绑库定时器、全局单例的 attach、SRS 存储、
/// 词典写入队列、后台写库的服务——都在创建处经 [own] 登记到这里。换库（重试开库、关库、
/// 弹窗进程关库、无界面复习写入引擎交库、AppModel.dispose）只有一个动作：[close]。
///
/// [close] 的顺序：
/// 1. [onClosing] 登记的「停止进料」回调同步跑完（关库信号、撤表订阅与防抖定时器——
///    它们不再接新活）；
/// 2. 取消本库名下的后台工作（[FushiDatabase.quiesceBackgroundWork]），与下一步并行；
/// 3. 按登记逆序收尾每个资源，每个恰好一次；
/// 4. 等后台工作退出，最后关连接。
///
/// 关闭完成后经 [database] 取连接抛 [DatabaseSessionClosedException]；关闭开始后不再
/// 接受新登记。不跟库走的进程级常驻服务不放这里，放 [ProcessLifetime]（重试换库时不能误杀它们）。
final class DatabaseSession {
  DatabaseSession(
    FushiDatabase database, {
    required this.label,
    required ResourceErrorSink onError,
  }) : _database = database,
       _onError = onError,
       _stack = _ResourceStack(label, onError);

  /// 日志与异常里的名字（如 `main` / `popup` / `srsWriteHost`）。
  final String label;

  final FushiDatabase _database;
  final ResourceErrorSink _onError;
  final _ResourceStack _stack;
  final List<_Entry> _closing = <_Entry>[];
  Future<void>? _closeFuture;
  bool _closed = false;
  Duration? _drainTimeout;

  /// 这一代的连接。关闭完成后抛 [DatabaseSessionClosedException]（关闭途中仍可取：
  /// 收尾动作自己可能要读写这一代的库，例如把词典写入队列排空）。
  FushiDatabase get database {
    if (_closed) {
      throw DatabaseSessionClosedException(label, 'database');
    }
    return _database;
  }

  /// 还没开始关。
  bool get isOpen => _closeFuture == null;

  /// 已经关完（连接已关）。
  bool get isClosed => _closed;

  /// 本次关闭调用方给的「后台写手排空」上限（只在 [close] 期间有意义；null = 等到真收尾）。
  /// 收尾动作现读它，见 `VideoDownloadPipelineService.stop` 的注释。
  Duration? get drainTimeout => _drainTimeout;

  /// 在创建处登记一个绑在本连接上的资源，返回原对象（便于 `x ??= session.own(...)`）。
  /// [label] 写进收尾失败的日志。关闭开始后调用抛 [DatabaseSessionClosedException]。
  T own<T>(T resource, ResourceClose<T> close, {required String label}) =>
      _stack.own<T>(resource, close, label);

  /// 登记一个「停止进料」回调：[close] 一开始、任何资源收尾之前同步调用，恰好一次。
  /// 只放撤订阅 / 发关库信号这类不需要等的动作。
  void onClosing(void Function() stopIntake, {required String label}) {
    if (!isOpen) {
      throw DatabaseSessionClosedException(this.label, 'onClosing($label)');
    }
    _closing.add(_Entry(null, label, stopIntake));
  }

  /// 本代内提前收掉一个已登记的资源（例如设置变更后重建的服务）：立刻跑它的收尾动作并
  /// 从栈里摘掉，[close] 时不会再收第二次。没登记过的对象是空操作。
  Future<void> release(Object resource) => _stack.release(resource);

  /// [resource] 是否还在本代的栈里。
  bool owns(Object resource) => _stack.owns(resource);

  /// 关闭这一代（幂等：并发 / 重复调用拿到同一个 Future）。连接本身关闭失败时原样抛出，
  /// 其余收尾失败只记日志。
  Future<void> close({Duration? drainTimeout}) =>
      _closeFuture ??= _close(drainTimeout);

  Future<void> _close(Duration? drainTimeout) async {
    _drainTimeout = drainTimeout;
    for (final _Entry entry in _closing) {
      // 同步回调：run 的第一步在本轮事件循环里执行完。
      unawaited(entry.run(_onError, label));
    }
    _closing.clear();
    final Future<void> backgroundWorkStopped = _database
        .quiesceBackgroundWork();
    await _stack.closeAll();
    try {
      await backgroundWorkStopped;
    } catch (e, stack) {
      _onError('$label.close(background work)', e, stack);
    }
    _closed = true;
    await _database.close();
  }
}

/// 进程级常驻服务的生命周期：不随换库重建（互联 host、ctl API server、Texthooker WS 客户端……），
/// 只在 AppModel 销毁时逆序收尾一次。判断一个资源放这里还是 [DatabaseSession] 的依据：
/// 它握着的是不是**某一代连接**——握着就进 session，否则进这里。
final class ProcessLifetime {
  ProcessLifetime({required this.label, required ResourceErrorSink onError})
    : _stack = _ResourceStack(label, onError);

  final String label;
  final _ResourceStack _stack;
  Future<void>? _closeFuture;

  /// 已开始收尾。
  bool get isClosed => _closeFuture != null;

  /// 见 [DatabaseSession.own]。
  T own<T>(T resource, ResourceClose<T> close, {required String label}) =>
      _stack.own<T>(resource, close, label);

  /// 见 [DatabaseSession.release]。
  Future<void> release(Object resource) => _stack.release(resource);

  /// 逆序收尾全部登记项（幂等）。
  Future<void> close() => _closeFuture ??= _stack.closeAll();
}
