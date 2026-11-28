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

/// 一个资源在它所属的 [DatabaseSession] 上什么时候收尾。
enum ReleasePhase {
  /// 模型侧的资源（仓库、服务、订阅、单例 attach）：整代关闭（[DatabaseSession.close]）和
  /// 持有者自身销毁（[DatabaseSession.detach]）时都收。
  withSession,

  /// 只属于「连接真的要关」这件事的资源（与主库并排的存储、关库前要等的写手）：只在
  /// [DatabaseSession.close] 里收，排在全部 [withSession] 资源之后、本库名下的后台工作退出
  /// 之后、关连接之前。[DatabaseSession.detach] 不动它们——连接和它名下的后台工作还活着，
  /// 留给连接的持有方。
  withConnection,
}

/// 一个登记项：资源 + 它的收尾动作，保证至多执行一次。
final class _Entry {
  _Entry(this.label, this._close);

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
/// **先登记后构造**：[own] 收的是工厂而不是对象——先查封栈，没封才调工厂、把结果连同收尾
/// 动作压栈，这三步之间没有 await。于是「对象已经建好、已经启动，登记却被拒」这种状态
/// 写不出来：封栈之后工厂根本不会被调用。工厂自己抛错时什么都没登记。
final class _ResourceStack {
  _ResourceStack(this.owner, this.onError);

  final String owner;
  final ResourceErrorSink onError;
  final List<_Entry> _entries = <_Entry>[];
  bool _sealed = false;

  T own<T>(
    T Function() create,
    ResourceClose<T> close,
    String label, {
    void Function(T resource, _Entry entry)? onOwned,
  }) {
    if (_sealed) {
      throw DatabaseSessionClosedException(owner, 'own($label)');
    }
    final T resource = create();
    final _Entry entry = _Entry(label, () => close(resource));
    _entries.add(entry);
    onOwned?.call(resource, entry);
    return resource;
  }

  Future<void> release(_Entry entry) async {
    if (!_entries.remove(entry)) return;
    await entry.run(onError, owner);
  }

  void seal() => _sealed = true;

  Future<void> closeAll() async {
    _sealed = true;
    while (_entries.isNotEmpty) {
      await _entries.removeLast().run(onError, owner);
    }
  }

  List<String> get labels => <String>[for (final _Entry e in _entries) e.label];
}

/// 能登记资源的生命周期（[DatabaseSession] / [ProcessLifetime]）。
sealed class ResourceScope {
  /// 日志与异常里的名字。
  String get label;

  _ResourceStack _stackFor(ReleasePhase phase, String resourceLabel);
}

/// 一个随生命周期存亡的槽位：缓存住「绑在某一代上的对象」的字段一律用它，不用裸的
/// 可空字段。
///
/// 槽位的写入、登记、清空是同一步（审计 db-bound-lifecycle-manual-teardown 的根因是这三件事
/// 各写各的）：
/// - 值只能经 [obtain] 写进来，[obtain] 就是登记——不存在「写了槽位却没登记」或「登记了
///   却忘了写槽位」；
/// - 所属的那一代收尾它（或本代内 [release]）时，槽位在收尾动作的第一步同步清空——下一代
///   的 [obtain] 一定重建，不会把上一代的对象带过去；
/// - 那一代开始关闭之后 [obtain] 直接抛 [DatabaseSessionClosedException]，工厂不会被调用。
final class OwnedSlot<T extends Object> {
  OwnedSlot(
    this.label,
    ResourceClose<T> close, {
    this.phase = ReleasePhase.withSession,
  }) : _close = close;

  /// 写进收尾失败的日志与 [DatabaseSession.debugOwnedLabels]。
  final String label;

  /// 见 [ReleasePhase]。
  final ReleasePhase phase;

  final ResourceClose<T> _close;
  T? _value;
  _Entry? _entry;
  _ResourceStack? _stack;

  /// 当前值；没建过、或所属的那一代已经把它收掉时为 null。
  T? get valueOrNull => _value;

  /// 取当前值；没有就在 [scope] 上用 [create] 建一个并登记。[scope] 已开始关闭时抛
  /// [DatabaseSessionClosedException]（[create] 不会被调用）。
  T obtain(ResourceScope scope, T Function() create) {
    final T? existing = _value;
    if (existing != null) return existing;
    return scope
        ._stackFor(phase, label)
        .own<T>(
          create,
          (T resource) {
            if (identical(_value, resource)) {
              _value = null;
              _entry = null;
              _stack = null;
            }
            return _close(resource);
          },
          label,
          onOwned: (T resource, _Entry entry) {
            _value = resource;
            _entry = entry;
            _stack = scope._stackFor(phase, label);
          },
        );
  }

  /// 本代内提前收掉当前值（设置变更后要重建的服务）：槽位同步清空，收尾动作恰好跑一次，
  /// 所属的那一代关闭时不会再收第二次。空槽位是空操作。
  Future<void> release() {
    final _Entry? entry = _entry;
    final _ResourceStack? stack = _stack;
    if (entry == null || stack == null) return Future<void>.value();
    return stack.release(entry);
  }

  /// 换一个值：先 [release] 旧的（不等它收尾完——槽位已同步清空），再 [obtain] 新的。
  T replace(ResourceScope scope, T Function() create) {
    unawaited(release());
    return obtain(scope, create);
  }
}

/// 一次「打开的主库连接」的生命周期（架构重构 F6，审计 db-bound-lifecycle-manual-teardown）。
///
/// 绑在这个连接上的一切——仓库、观察者 / 表订阅、绑库定时器、全局单例的 attach、SRS 存储、
/// 词典写入队列、后台写库的服务——都在创建处登记到这里（缓存字段用 [OwnedSlot]，没有字段的
/// 订阅 / attach 用 [own]）。换库（重试开库、关库、弹窗进程关库、无界面复习写入引擎交库）
/// 只有一个动作：[close]；持有者对象自身销毁用 [detach]。
///
/// [close] 的顺序：
/// 1. [onConnectionClosing] 与 [onClosing] 登记的回调同步跑完（关库信号、撤表订阅与防抖
///    定时器——它们不再接新活）；
/// 2. 取消本库名下的后台工作（[FushiDatabase.quiesceBackgroundWork]），与下一步并行；
/// 3. 按登记逆序收尾每个 [ReleasePhase.withSession] 资源，每个恰好一次；
/// 4. 等后台工作退出；
/// 5. 按登记逆序收尾每个 [ReleasePhase.withConnection] 资源；
/// 6. 关连接。
///
/// 从 [close] / [detach] 被调用的那一刻起 [isOpen] 为 false、不再接受新登记（[own] /
/// [OwnedSlot.obtain] 抛 [DatabaseSessionClosedException]）；[database] 在关闭途中仍可取
/// （收尾动作自己要读写这一代的库），关完之后抛。不跟库走的进程级常驻服务不放这里，放
/// [ProcessLifetime]（重试换库时不能误杀它们）。
final class DatabaseSession implements ResourceScope {
  DatabaseSession(
    FushiDatabase database, {
    required this.label,
    required ResourceErrorSink onError,
  }) : _database = database,
       _onError = onError,
       _withSession = _ResourceStack(label, onError),
       _withConnection = _ResourceStack(label, onError);

  /// 日志与异常里的名字（如 `main` / `popup` / `srsWriteHost`）。
  @override
  final String label;

  final FushiDatabase _database;
  final ResourceErrorSink _onError;
  final _ResourceStack _withSession;
  final _ResourceStack _withConnection;
  final List<_Entry> _closing = <_Entry>[];
  final List<_Entry> _connectionClosing = <_Entry>[];
  Future<void>? _closeFuture;
  bool _closeStarted = false;
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

  /// 还没开始关：可以登记资源、可以开新活。**对外的「库可用」门闩只认这个**——它与
  /// 「[own] 会不会抛」是同一个条件，不存在门闩开着、登记却被拒的窗口。
  bool get isOpen => !_closeStarted;

  /// 已经关完（[close]：连接已关；[detach]：本代资源已收完、连接已交还持有方）。
  bool get isClosed => _closed;

  /// 本次关闭调用方给的「后台写手排空」上限（只在 [close] 期间有意义；null = 等到真收尾）。
  /// 收尾动作现读它，见 `VideoDownloadPipelineService.stop` 的注释。
  Duration? get drainTimeout => _drainTimeout;

  @override
  _ResourceStack _stackFor(ReleasePhase phase, String resourceLabel) =>
      switch (phase) {
        ReleasePhase.withSession => _withSession,
        ReleasePhase.withConnection => _withConnection,
      };

  /// 在创建处登记一个绑在本连接上、但没有缓存字段的资源（订阅、全局单例的 attach）：先查
  /// 是否已开始关闭，没有才调 [create]（订阅 / attach 的副作用写在 [create] 里），再把它和
  /// [close] 一起登记。关闭开始后调用抛 [DatabaseSessionClosedException]，[create] 不会执行。
  /// 有缓存字段的资源用 [OwnedSlot.obtain]。
  T own<T>(
    T Function() create,
    ResourceClose<T> close, {
    required String label,
    ReleasePhase phase = ReleasePhase.withSession,
  }) => _stackFor(phase, label).own<T>(create, close, label);

  /// 登记一个「停止进料」回调：[close] / [detach] 一开始、任何资源收尾之前同步调用，恰好
  /// 一次。只放撤订阅这类不需要等的动作。
  void onClosing(void Function() stopIntake, {required String label}) {
    if (!isOpen) {
      throw DatabaseSessionClosedException(this.label, 'onClosing($label)');
    }
    _closing.add(_Entry(label, stopIntake));
  }

  /// 登记一个「连接要关了」的同步信号：只在 [close] 一开始调用（先于 [onClosing]），恰好
  /// 一次；[detach] 不调（连接没有要关）。
  void onConnectionClosing(void Function() signal, {required String label}) {
    if (!isOpen) {
      throw DatabaseSessionClosedException(
        this.label,
        'onConnectionClosing($label)',
      );
    }
    _connectionClosing.add(_Entry(label, signal));
  }

  /// 还在栈里的登记项的名字（按登记顺序，两个阶段分开）：给「某个资源确实登记在这一代上」
  /// 的测试用。
  ({List<String> withSession, List<String> withConnection})
  get debugOwnedLabels => (
    withSession: _withSession.labels,
    withConnection: _withConnection.labels,
  );

  /// 关闭这一代（幂等：并发 / 重复调用拿到同一个 Future，第一次调用的参数为准）。连接本身
  /// 关闭失败时原样抛出，其余收尾失败只记日志。
  Future<void> close({Duration? drainTimeout}) =>
      _closeFuture ??= _close(drainTimeout);

  /// 持有者对象自身销毁（`AppModel.dispose`）：只收 [ReleasePhase.withSession] 资源，连接、
  /// 它名下的后台工作和 [ReleasePhase.withConnection] 资源都留给连接的持有方（生产退出链
  /// 此前已经 [close] 过，这里是空操作；测试 seam 接进来的连接归测试）。不发
  /// [onConnectionClosing]、不让后台工作进入关闭态。幂等，与 [close] 共用同一个完成信号：
  /// 先 [detach] 之后再 [close] 不会回头关连接。
  Future<void> detach() => _closeFuture ??= _detach();

  void _stopIntake({required bool connectionClosing}) {
    // 封栈在任何回调之前：回调里再登记同样被拒。
    _closeStarted = true;
    _withSession.seal();
    _withConnection.seal();
    if (connectionClosing) {
      for (final _Entry entry in _connectionClosing) {
        // 同步回调：run 的第一步在本轮事件循环里执行完。
        unawaited(entry.run(_onError, label));
      }
    }
    _connectionClosing.clear();
    for (final _Entry entry in _closing) {
      unawaited(entry.run(_onError, label));
    }
    _closing.clear();
  }

  Future<void> _close(Duration? drainTimeout) async {
    _drainTimeout = drainTimeout;
    _stopIntake(connectionClosing: true);
    final Future<void> backgroundWorkStopped = _database
        .quiesceBackgroundWork();
    await _withSession.closeAll();
    try {
      await backgroundWorkStopped;
    } catch (e, stack) {
      _onError('$label.close(background work)', e, stack);
    }
    await _withConnection.closeAll();
    _closed = true;
    await _database.close();
  }

  Future<void> _detach() async {
    _stopIntake(connectionClosing: false);
    await _withSession.closeAll();
    _closed = true;
  }
}

/// 进程级常驻服务的生命周期：不随换库重建（互联 host、ctl API server、Texthooker WS 客户端……），
/// 只在 AppModel 销毁时逆序收尾一次。判断一个资源放这里还是 [DatabaseSession] 的依据：
/// 它握着的是不是**某一代连接**——握着就进 session，否则进这里。
final class ProcessLifetime implements ResourceScope {
  ProcessLifetime({required this.label, required ResourceErrorSink onError})
    : _stack = _ResourceStack(label, onError);

  @override
  final String label;
  final _ResourceStack _stack;
  Future<void>? _closeFuture;

  /// 已开始收尾。
  bool get isClosed => _closeFuture != null;

  @override
  _ResourceStack _stackFor(ReleasePhase phase, String resourceLabel) {
    if (phase != ReleasePhase.withSession) {
      throw ArgumentError.value(
        phase,
        'phase',
        '$resourceLabel: only a DatabaseSession has a connection to outlive',
      );
    }
    return _stack;
  }

  /// 见 [DatabaseSession.own]。
  T own<T>(
    T Function() create,
    ResourceClose<T> close, {
    required String label,
  }) => _stack.own<T>(create, close, label);

  /// 逆序收尾全部登记项（幂等）。
  Future<void> close() => _closeFuture ??= _stack.closeAll();
}
