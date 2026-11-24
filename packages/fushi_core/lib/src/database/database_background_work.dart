import 'dart:async';

import 'package:drift/drift.dart';

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

  /// 库开始关闭时完成。
  Future<void> get whenCancelled => _owner._closing.future;

  /// 已取消就抛 [DatabaseWorkCancelledException]。长循环每一步开头调一次。
  void throwIfCancelled() {
    if (isCancelled) throw DatabaseWorkCancelledException(label);
  }

  /// 等一个不经数据库的长操作（整文件哈希、FFmpeg、网络请求、等用户确认）——库开始关时
  /// 不再等它，直接抛 [DatabaseWorkCancelledException]。被放弃的 [operation] 自己跑完，
  /// 结果丢弃（它的错误也吞掉，避免成为未处理的异步错误）。
  Future<T> guard<T>(Future<T> operation) {
    throwIfCancelled();
    final Completer<T> out = Completer<T>();
    operation.then(
      (T value) {
        if (!out.isCompleted) out.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!out.isCompleted) out.completeError(error, stack);
      },
    );
    whenCancelled.then((_) {
      if (!out.isCompleted) {
        out.completeError(DatabaseWorkCancelledException(label));
      }
    });
    return out.future;
  }
}

const Symbol _databaseWorkZoneKey = #fushiDatabaseWorkToken;

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
  final Completer<void> _closing = Completer<void>();
  final Map<Future<void>, String> _inFlight = <Future<void>, String>{};

  /// 库是否已开始关闭（关闭后不可逆：一个库实例只关一次）。
  bool get isClosing => _closing.isCompleted;

  /// 在跑的工作标签（诊断 / 测试用）。
  List<String> get inFlightLabels => _inFlight.values.toList(growable: false);

  /// 在一个带取消令牌的 Zone 里跑 [body]，登记到关库要等的集合里。
  ///
  /// 库已开始关闭 → 抛 [DatabaseWorkCancelledException]，[body] 不执行。
  /// [body] 自己抛的异常原样传给调用方（含取消）。
  Future<T> run<T>(
    String label,
    Future<T> Function(DatabaseWorkToken token) body,
  ) {
    if (isClosing) {
      return Future<T>.error(DatabaseWorkCancelledException(label));
    }
    final DatabaseWorkToken token = DatabaseWorkToken._(this, label);
    final Future<T> result = runZoned<Future<T>>(
      () => Future<T>.sync(() => body(token)),
      zoneValues: <Object?, Object?>{_databaseWorkZoneKey: token},
    );
    final Future<void> settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _inFlight[settled] = label;
    settled.whenComplete(() => _inFlight.remove(settled));
    return result;
  }

  /// 取消本库名下全部工作并等它们退出。幂等；可与 [run] 并发调用。
  ///
  /// [onSlow]：等了 [slowAfter] 还有工作没退出时回调一次（带仍在跑的标签），只用于
  /// 留诊断——照样继续等，不放行（放行就是让它打在已关闭 / 已换掉的库上）。
  Future<void> quiesce({
    Duration slowAfter = const Duration(seconds: 10),
    void Function(List<String> stillRunning)? onSlow,
  }) async {
    if (!_closing.isCompleted) _closing.complete();
    if (_inFlight.isEmpty) return;
    Timer? slow;
    if (onSlow != null) {
      slow = Timer(slowAfter, () {
        if (_inFlight.isNotEmpty) onSlow(inFlightLabels);
      });
    }
    try {
      while (_inFlight.isNotEmpty) {
        await Future.wait(_inFlight.keys.toList(growable: false));
      }
    } finally {
      slow?.cancel();
    }
  }
}

/// 拦截器：当前 Zone 属于一份已取消的后台工作时，SQL 不发出去，直接抛
/// [DatabaseWorkCancelledException]。事务里第一条被拦下的语句会让 drift 回滚整个事务，
/// 所以半截写入不会落库。
final class DatabaseWorkInterceptor extends QueryInterceptor {
  DatabaseWorkInterceptor();

  static void _check() => DatabaseWorkToken.current?.throwIfCancelled();

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

/// 全部 [FushiDatabase] 构造路径共用的拦截器实例（无状态）。
final DatabaseWorkInterceptor databaseWorkInterceptor =
    DatabaseWorkInterceptor();
