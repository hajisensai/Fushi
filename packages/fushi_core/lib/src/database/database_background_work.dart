import 'dart:async';

import 'package:drift/drift.dart';

import '../utils/fushi_debug_print.dart';

/// 后台写库工作被「换库 / 关库」取消（BUG：反馈 hfLuOcL7n0 备份恢复期间媒体库后台任务
/// 仍在写）。
///
/// 这不是错误：库要关了（备份恢复、合并导入、迁移导入、数据根迁移、退出），在跑的后台
/// 工作（扫描、刮削、整文件哈希升级、封面回填、响度测量……）到下一条 SQL 就停下。调用方
/// 只需把它当「这轮没做完」处理，不记错误日志。
final class DatabaseWorkCancelledException implements Exception {
  const DatabaseWorkCancelledException(this.label);

  /// 被取消的那份工作的标签（[DatabaseBackgroundWork.run] 的 `label`）。
  final String label;

  @override
  String toString() =>
      'DatabaseWorkCancelledException($label): database is closing';
}

/// 一份后台写库工作的取消令牌。
///
/// 令牌属于开它的那个库（[DatabaseBackgroundWork]）：那个库一开始关，它名下**所有**令牌
/// （在跑的、已经跑完但留下回调的）一律视为已取消。令牌经 Zone 跟着工作走，所以工作里
/// 任何地方发出的 SQL（哪怕发给另一个库实例）都会被 [databaseWorkInterceptor] 拦下——
/// 旧库读出来的行身份写不进新库。
final class DatabaseWorkToken {
  DatabaseWorkToken._(this._owner, this.label);

  final DatabaseBackgroundWork _owner;

  /// 工作标签，诊断用。
  final String label;

  /// 当前 Zone 里的工作令牌；不在任何后台工作里时为 null。
  static DatabaseWorkToken? get current =>
      Zone.current[_databaseWorkZoneKey] as DatabaseWorkToken?;

  /// 开这份工作的库是否已开始关闭。
  bool get isCancelled => _owner.isClosing;

  Completer<void>? _cancelled;
  void Function()? _unlinkCancelled;
  bool _ended = false;

  /// 库开始关闭时完成的信号（已取消就是已完成的 future）。这份工作结束
  /// （[DatabaseBackgroundWork.run] 返回）时自动注销，不在库上留回调；工作结束后才第一次
  /// 取的信号永不完成。
  ///
  /// 只适合「一份工作里挂一两次」的等待。一份工作里会反复挂上去的东西（逐个请求的
  /// `http` 中止触发器、逐个子进程）不要挂在它上面：挂上的回调要等工作结束才随信号一起
  /// 释放，长工作里会无界累积——那种场合用 [onCancelled] 按次登记、操作结束即注销
  /// （`createAppHttpIoClient` 就是这么做的）。
  Future<void> get cancelled {
    final Completer<void>? existing = _cancelled;
    if (existing != null) return existing.future;
    final Completer<void> created = _cancelled = Completer<void>();
    if (isCancelled) {
      created.complete();
    } else if (!_ended) {
      _unlinkCancelled = onCancelled(() {
        if (!created.isCompleted) created.complete();
      });
    }
    return created.future;
  }

  void _end() {
    _ended = true;
    _unlinkCancelled?.call();
    _unlinkCancelled = null;
  }

  /// 把一个**不经数据库、能被中途杀掉**的外部操作（FFmpeg 子进程、FFmpegKit 会话……）
  /// 绑到当前 Zone 的后台工作上：库开始关时调 [abort]（已在关就当场调）。返回注销函数，
  /// 操作结束后必须调用。当前不在任何后台工作里时什么也不做（返回空操作）。
  ///
  /// 这是「换库要等的东西必须能被打断」的统一入口：数据根迁移 / 备份恢复关库时，已登记
  /// 工作里在跑的子进程被杀掉、文件句柄随之释放，关库不必等它自然跑完。
  static void Function() abortOnCancel(void Function() abort) {
    final DatabaseWorkToken? token = current;
    if (token == null) return _noopUnlink;
    return token.onCancelled(abort);
  }

  static void _noopUnlink() {}

  /// 库开始关闭时调 [callback]（库已在关闭就当场调）。返回注销函数。
  ///
  /// 等的东西一结束就必须注销：库实例活一整个会话，逐文件 / 逐曲目 / 逐次刮削登记
  /// 却不注销的回调会一直挂在库上（连同它捕获的对象），无界增长到关库为止。
  void Function() onCancelled(void Function() callback) =>
      _owner._addCancelListener(callback);

  /// 已取消就抛 [DatabaseWorkCancelledException]。长循环每一步开头调一次。
  void throwIfCancelled() {
    if (isCancelled) throw DatabaseWorkCancelledException(label);
  }

  /// 等一个不经数据库的长操作（整文件哈希、FFmpeg、网络请求、等用户确认）——库开始关时
  /// 不再等它，直接抛 [DatabaseWorkCancelledException]。被放弃的 [operation] 自己跑完，
  /// 结果丢弃（它的错误也吞掉，避免成为未处理的异步错误）。[operation] 结束即注销取消
  /// 回调，不在库上留东西。
  Future<T> guard<T>(Future<T> operation) {
    throwIfCancelled();
    final Completer<T> out = Completer<T>();
    final void Function() unregister = onCancelled(() {
      if (!out.isCompleted) {
        out.completeError(DatabaseWorkCancelledException(label));
      }
    });
    operation.then(
      (T value) {
        unregister();
        if (!out.isCompleted) out.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        unregister();
        if (!out.isCompleted) out.completeError(error, stack);
      },
    );
    return out.future;
  }
}

/// 一条取消回调的登记（按身份区分：同一个闭包登记两次是两条）。
final class _CancelListener {
  _CancelListener(this.callback);

  final void Function() callback;
}

const Symbol _databaseWorkZoneKey = #fushiDatabaseWorkToken;

/// 一份在跑的后台工作：标签、令牌、它的续体排在哪个 Zone 里。
final class _InFlightWork {
  _InFlightWork(this.label, this.token, this.zone);

  final String label;
  final DatabaseWorkToken token;

  /// 工作体所在的 Zone（[DatabaseBackgroundWork.run] 为它开的那个）。工作里每个异步
  /// 续体都经它（及其父 Zone）排进微任务队列。
  final Zone zone;
}

/// 一个库实例上的后台写库工作登记表：「换库」的生命周期边界。
///
/// - [run]：后台工作（扫描、刮削、哈希升级、封面回填、响度测量……）一律经它跑。库已在
///   关闭时直接抛 [DatabaseWorkCancelledException]，不再开新工作。
/// - [quiesce]：关库前调用。先把本库名下所有令牌置为已取消（工作到下一条 SQL / 下一个
///   [DatabaseWorkToken.guard] 就停），再**等所有在跑的工作真正退出**，库才关。
///   `FushiDatabase.close()` 自动调用它，所以任何关库路径（备份恢复、合并导入、迁移
///   导入、数据根迁移、退出）都不会让后台工作打在已关闭的连接上，也不会让旧库读出的
///   行身份在换上新库后写进去。
final class DatabaseBackgroundWork {
  /// 测试装配点（生产恒为 false）：关库等后台工作前，先放掉「续体排在一个不再推进的
  /// Zone 里」的工作，不再等它。
  ///
  /// 组件测试（`testWidgets`）的用例体跑在 FakeAsync Zone 里：用例体里开的后台工作，
  /// 真实 I/O 完成后的续体排进那个 Zone 的假微任务队列，用例体一结束就再没人推——工作
  /// 永远不会退出，tearDown 里的 `db.close()` 就永远等下去。这和「工作慢」是两回事：
  /// 那份工作已经不可能再跑任何一行，等它没有意义；它也不可能再发 SQL（就算将来被推，
  /// 库已封口，一样被拦成取消）。
  ///
  /// 判据是确定性的、不靠计时：给每份在跑工作的 Zone 排一个探针微任务，再在关库方
  /// 自己的 Zone 里排一个；能推进的 Zone 与关库方同在根微任务队列（或同一个假队列）里，
  /// 按 FIFO 探针一定先跑；关库方的微任务跑到时探针还没跑的，就是排在一个没人推的队列
  /// 里。生产里所有 Zone 都把微任务交给根队列，这条判据永远不会命中——但它只服务测试
  /// 宿主，所以仍由开关把守，生产语义（关库等每一份登记工作真正退出）不变。
  ///
  /// app 测试套件在 `test/flutter_test_config.dart` 里统一打开，一次覆盖所有登记写手，
  /// 不必给每个写手各配一个「测试里别起」的开关。
  static bool debugReleaseWorkInStalledZones = false;

  bool _closing = false;
  bool _sealed = false;
  bool _reportedUnregisteredWriter = false;
  final Map<Future<void>, _InFlightWork> _inFlight =
      <Future<void>, _InFlightWork>{};
  final Set<_CancelListener> _cancelListeners = <_CancelListener>{};

  /// 库是否已开始关闭（关闭后不可逆：一个库实例只关一次）。
  bool get isClosing => _closing;

  /// 库是否已封口：封口后发给本库实例的**任何** SQL（登记过的工作、没登记的写手、关库后
  /// 才醒来的异步续体）都被 [DatabaseWorkInterceptor] 拦下，抛
  /// [DatabaseWorkCancelledException]。
  bool get isSealed => _sealed;

  /// 封口（`FushiDatabase.close()` 第一步调用；幂等，同时开始关闭）。
  ///
  /// 封口是「换库不撞已关连接」的结构保证，不靠逐个写手记得登记：没经 [run] 登记的写手
  /// 关库时不会被等，但它下一条 SQL 也发不进来——拿到的是可识别的取消，而不是 drift 的
  /// 「connection was closed」；事务里被拦下的那一条让整个事务回滚，不留半截写入。
  /// 关库方在封口前就该让「必须落库」的收尾（下载流水线 drain、词典写入 drain）写完。
  ///
  /// 和 [quiesce] 一样不能在本库自己的后台工作里调用（抛 [StateError]，库保持原状）。
  void seal() {
    _throwIfCalledFromOwnWork('seal');
    _sealed = true;
    _beginClosing();
  }

  void _throwIfCalledFromOwnWork(String operation) {
    final DatabaseWorkToken? caller = DatabaseWorkToken.current;
    if (caller != null && identical(caller._owner, this)) {
      throw StateError(
        '$operation() called from inside background work "${caller.label}" '
        'of the same database: it would wait for itself forever',
      );
    }
  }

  /// 封口后第一次被没登记的写手撞上时留一条诊断（带调用栈），便于把漏登记的写手找出来
  /// 接进 [run]；之后不再重复打印。
  void _noteUnregisteredWriterAfterSeal() {
    if (_reportedUnregisteredWriter) return;
    _reportedUnregisteredWriter = true;
    fushiDebugPrint(
      '[fushi-db] SQL from a writer not registered via runBackgroundWork '
      'reached a sealed (closing) database; rejected.\n'
      '${StackTrace.current}',
    );
  }

  /// 尚未触发、也未注销的取消回调数（诊断 / 测试用：正常运行时应随工作结束归零）。
  int get pendingCancelListenerCount => _cancelListeners.length;

  void Function() _addCancelListener(void Function() callback) {
    if (_closing) {
      callback();
      return _noop;
    }
    final _CancelListener listener = _CancelListener(callback);
    _cancelListeners.add(listener);
    return () => _cancelListeners.remove(listener);
  }

  static void _noop() {}

  void _beginClosing() {
    if (_closing) return;
    _closing = true;
    final List<_CancelListener> listeners = _cancelListeners.toList(
      growable: false,
    );
    _cancelListeners.clear();
    for (final _CancelListener listener in listeners) {
      listener.callback();
    }
  }

  /// 在跑的工作标签（诊断 / 测试用）。
  List<String> get inFlightLabels => <String>[
    for (final _InFlightWork work in _inFlight.values) work.label,
  ];

  /// 在一个带取消令牌的 Zone 里跑 [body]，登记到关库要等的集合里。
  ///
  /// 库已开始关闭 → 抛 [DatabaseWorkCancelledException]，[body] 不执行。
  /// [body] 自己抛的异常原样传给调用方（含取消）——**库开始关之后**才抛出的异常除外：
  /// 那时工作里被中断的网络请求（`RequestAbortedException`）、被杀的子进程留下的读写
  /// 错误等都是关库造成的，一律归一成 [DatabaseWorkCancelledException]。调用方只认这一
  /// 种取消就能分清「被换库打断」与「真失败」，不会把中断当失败记下（计划标 failed、
  /// 探针记「已检查」、批处理当单条失败接着跑）。
  Future<T> run<T>(
    String label,
    Future<T> Function(DatabaseWorkToken token) body,
  ) {
    if (isClosing) {
      return Future<T>.error(DatabaseWorkCancelledException(label));
    }
    final DatabaseWorkToken token = DatabaseWorkToken._(this, label);
    late final Zone workZone;
    final Future<T> result =
        runZoned<Future<T>>(() {
          workZone = Zone.current;
          return Future<T>.sync(() => body(token));
        }, zoneValues: <Object?, Object?>{_databaseWorkZoneKey: token}).then<T>(
          (T value) => value,
          onError: (Object error, StackTrace stack) {
            if (error is! DatabaseWorkCancelledException && token.isCancelled) {
              Error.throwWithStackTrace(
                DatabaseWorkCancelledException(label),
                stack,
              );
            }
            Error.throwWithStackTrace(error, stack);
          },
        );
    final Future<void> settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _inFlight[settled] = _InFlightWork(label, token, workZone);
    settled.whenComplete(() {
      _inFlight.remove(settled);
      token._end();
    });
    return result;
  }

  /// 取消本库名下全部工作并等它们退出。幂等；可与 [run] 并发调用。
  ///
  /// 不能在本库自己的后台工作里调用：那是在等自己退出，永远等不到——直接抛
  /// [StateError]，不让关库静默挂死。
  ///
  /// [onSlow]：等了 [slowAfter] 还有工作没退出时回调一次（带仍在跑的标签），只用于
  /// 留诊断——照样继续等，不放行（放行就是让它打在已关闭 / 已换掉的库上）。
  Future<void> quiesce({
    Duration slowAfter = const Duration(seconds: 10),
    void Function(List<String> stillRunning)? onSlow,
  }) async {
    _throwIfCalledFromOwnWork('quiesce');
    _beginClosing();
    if (_inFlight.isEmpty) return;
    Timer? slow;
    if (onSlow != null) {
      slow = Timer(slowAfter, () {
        if (_inFlight.isNotEmpty) onSlow(inFlightLabels);
      });
    }
    try {
      while (_inFlight.isNotEmpty) {
        if (debugReleaseWorkInStalledZones) {
          await _releaseWorkInStalledZones();
          if (_inFlight.isEmpty) break;
        }
        await Future.wait(_inFlight.keys.toList(growable: false));
      }
    } finally {
      slow?.cancel();
    }
  }
}

/// 见 [DatabaseBackgroundWork.debugReleaseWorkInStalledZones]。
extension on DatabaseBackgroundWork {
  Future<void> _releaseWorkInStalledZones() async {
    final List<MapEntry<Future<void>, _InFlightWork>> pending = _inFlight
        .entries
        .toList(growable: false);
    final Set<Future<void>> advanced = <Future<void>>{};
    for (final MapEntry<Future<void>, _InFlightWork> entry in pending) {
      entry.value.zone.scheduleMicrotask(() => advanced.add(entry.key));
    }
    final Completer<void> ownTurn = Completer<void>();
    scheduleMicrotask(ownTurn.complete);
    await ownTurn.future;
    for (final MapEntry<Future<void>, _InFlightWork> entry in pending) {
      if (advanced.contains(entry.key)) continue;
      if (_inFlight.remove(entry.key) == null) continue;
      entry.value.token._end();
      fushiDebugPrint(
        '[fushi-db] close: background work "${entry.value.label}" is parked '
        'in a zone that no longer runs (test FakeAsync); not waiting for it',
      );
    }
  }
}

/// 拦截器（每个库实例一个，绑在该实例的 [DatabaseBackgroundWork] 上）：
///
/// - 本库已封口（[DatabaseBackgroundWork.seal]）→ 任何 SQL 都不发出去；
/// - 当前 Zone 属于一份已取消的后台工作（哪怕那份工作属于另一个库实例）→ 不发出去。
///
/// 两种都直接抛 [DatabaseWorkCancelledException]。事务里第一条被拦下的语句会让 drift
/// 回滚整个事务，所以半截写入不会落库。
final class DatabaseWorkInterceptor extends QueryInterceptor {
  DatabaseWorkInterceptor(this._work);

  final DatabaseBackgroundWork _work;

  /// 封口后被拦下、又不在任何后台工作里的 SQL 用的标签。
  static const String unregisteredLabel = 'unregistered';

  void _check() {
    final DatabaseWorkToken? token = DatabaseWorkToken.current;
    if (_work.isSealed) {
      if (token == null) _work._noteUnregisteredWriterAfterSeal();
      throw DatabaseWorkCancelledException(token?.label ?? unregisteredLabel);
    }
    token?.throwIfCancelled();
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    _check();
    return super.ensureOpen(executor, user);
  }

  @override
  QueryExecutor beginExclusive(QueryExecutor parent) {
    _check();
    return super.beginExclusive(parent);
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    _check();
    return super.beginTransaction(parent);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    _check();
    return super.runBatched(executor, statements);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _check();
    return super.runSelect(executor, statement, args);
  }
}
