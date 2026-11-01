/// 内核命令的常驻后台 isolate 池（同步 v2 / 排队 / 预览 / 血统 / 优化器与 RWKV 直读）。
///
/// 以前每条命令 `Isolate.run` 新起一个 isolate：起 isolate、重新 dlopen、解析二十几个符号
/// （`SrsCoreBindings`），一次评分要来回几次。现在 worker 常驻、复用：每个 worker 只在第一次用到某个句柄时
/// 包一次 [SrsCore]（符号解析一次），之后只发命令。
///
/// - 并发：命令可能很慢（收段一片、状态摘要、全量回放），一个 worker 会把快命令（复习时的预览 / 排队）挡在
///   后面，所以是个小池子：有空闲的就用，都忙且没到上限就再起一个，到上限排队。与 `Isolate.run` 一样，
///   同时在途的命令各在自己的 isolate 上调进内核，库内部的读 / 写连接锁照旧决定谁等谁。
/// - 分道（[SrsCoreLane]，集成审查【中】）：以前一个 FIFO 池（上限 4），而不进写锁的媒体文件命令（`seal_file` /
///   `open_file` / `media_hash`，同步时按 `kSrsSync2Concurrency` = 6 并发）一来就占满全部 worker，复习页的
///   作答 / 排队 / 预览排在几 MB 文件的加解密后面。现在三条道各有自己的 worker 与队列：复习页的交互命令
///   （[SrsCoreLane.interactive]）、其余内核命令（[SrsCoreLane.bulk]）、媒体文件加解密 / 哈希
///   （[SrsCoreLane.file]，专用 isolate）。一条道满了只排它自己的队，不挡别的道。
/// - 发送：命令是一个只捕获可发送数据（句柄地址、请求、字节块）的闭包——写成顶层函数造闭包，不捕获
///   `SrsDbStore`（它带着 Drift 连接与 Future，不可发送）。
/// - worker 意外退出（原生崩溃以外的致命错误）：在途命令报错，那个 worker 丢弃，之后按需再起。起 worker 失败：
///   那条命令报错，排着的下一条接着去起（全都起不来时排队的命令逐条报错，不会永远挂着）。
/// - 句柄关闭（[SrsStorage.close] 调 [SrsCoreWorkers.forget]）：各 worker 丢掉为它包的 [SrsCore]，换 profile /
///   覆盖恢复反复开关库时不再越攒越多。
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
import 'package:meta/meta.dart' show visibleForTesting;

/// 在 worker 里对内核句柄执行的一条命令。
typedef SrsCoreJob<T> = T Function(SrsCore core);

/// 命令走哪条道（见库注释）。
enum SrsCoreLane {
  /// 复习页的交互命令（作答、排队、预览）：短、用户在等。
  interactive,

  /// 其余内核命令（同步、缓存刷新、统计、浏览、优化器……）。
  bulk,

  /// 媒体文件的流式加解密与哈希（不进写锁，同步时成批并发）。
  file,

  /// Drift 事务外的查询（srs_database_executor.dart 的读查询那一路）：内核只读连接池上并发执行，不进写锁、
  /// 不排在 Drift 写连接的队列里，也不与上面几条道的长命令互相排队。
  query,
}

final class SrsCoreWorkers {
  SrsCoreWorkers._(
    this.libraryPath, {
    Duration queryIdleTtl = kSrsQueryWorkerIdleTtl,
  }) {
    for (final SrsCoreLane lane in SrsCoreLane.values) {
      _lanes[lane] = _Lane(
        libraryPath,
        maxWorkersOf(lane),
        () => debugFailSpawns,
        idleTtl: lane == SrsCoreLane.query ? queryIdleTtl : null,
      );
    }
  }

  /// 一个不登记进 [of] 的新池（测试：起 worker 失败、句柄缓存、查询道空闲回收）。
  @visibleForTesting
  factory SrsCoreWorkers.debugFresh(
    String? libraryPath, {
    Duration queryIdleTtl = kSrsQueryWorkerIdleTtl,
  }) => SrsCoreWorkers._(libraryPath, queryIdleTtl: queryIdleTtl);

  static final Map<String?, SrsCoreWorkers> _pools =
      <String?, SrsCoreWorkers>{};

  /// 按库路径一个池（null = 默认定位规则加载的库）。
  static SrsCoreWorkers of(String? libraryPath) =>
      _pools.putIfAbsent(libraryPath, () => SrsCoreWorkers._(libraryPath));

  /// [SrsCoreLane.bulk] 同时在途的命令数上限（超过排队）。
  static const int maxWorkers = 4;

  /// [SrsCoreLane.query] 的空闲 worker 保留时长：与内核只读连接池的空闲回收（Rust `read_pool::IDLE_TTL`）同长，
  /// 一阵并发查询（打开设置页、一轮同步）之后多起的 worker 一分钟内没再用就收掉（每个 isolate 几 MB 堆）；
  /// 至少留一个，下一条查询不付起 isolate + 解析符号的开销。
  static const Duration kSrsQueryWorkerIdleTtl = Duration(seconds: 60);

  /// 各道同时在途的命令数上限：交互命令短、一次评分最多两三条并发；文件道给同步的成批加解密留两个并行。
  static int maxWorkersOf(SrsCoreLane lane) => switch (lane) {
    SrsCoreLane.interactive => 2,
    SrsCoreLane.bulk => maxWorkers,
    SrsCoreLane.file => 2,
    // 真正的上限由 [setQueryConcurrency] 从打开的库上读（内核只读连接池的上限）；读到之前只放一个。
    SrsCoreLane.query => 1,
  };

  /// 设 [SrsCoreLane.query] 的 worker 上限为 [n]（`SrsCore.readConcurrency`：内核只读连接池的上限，按核数算，
  /// 只在 Rust 里算一次）。worker 数不超过池上限，查询不会在内核里等连接。调高时排着的查询立即去起 worker。
  void setQueryConcurrency(int n) => _lanes[SrsCoreLane.query]!.setMax(n);

  /// [lane] 当前活着（空闲 + 在途）的 worker 数（测试看空闲回收）。
  @visibleForTesting
  int debugLive(SrsCoreLane lane) => _lanes[lane]!.live;

  /// [lane] 的 worker 上限（测试）。
  @visibleForTesting
  int debugMax(SrsCoreLane lane) => _lanes[lane]!.max;

  final String? libraryPath;
  final Map<SrsCoreLane, _Lane> _lanes = <SrsCoreLane, _Lane>{};

  /// 已起的 worker 数（测试看复用）。
  int get debugSpawned => <int>[
    for (final _Lane l in _lanes.values) l.spawnedTotal,
  ].fold(0, (int a, int b) => a + b);

  /// 测试：之后起 worker 一律失败（模拟 `Isolate.spawn` 抛错）。
  @visibleForTesting
  bool debugFailSpawns = false;

  /// 在 worker 里对 [address] 的句柄执行 [job]，走 [lane] 那条道。
  Future<T> run<T>(
    int address,
    SrsCoreJob<T> job, {
    SrsCoreLane lane = SrsCoreLane.bulk,
  }) {
    final Completer<T> done = Completer<T>();
    _lanes[lane]!.submit(
      _Job<Object?>(
        address,
        job,
        (Object? value) => done.complete(value as T),
        done.completeError,
      ),
    );
    return done.future;
  }

  /// 句柄 [address] 已关闭：各道全部 worker 丢掉为它包的 [SrsCore]（在途的命令跑完后处理，按发送顺序）。
  void forget(int address) {
    for (final _Lane l in _lanes.values) {
      l.forget(address);
    }
  }
}

/// 一条道：自己的 worker、空闲表与等待队列。
final class _Lane {
  _Lane(this.libraryPath, this.max, this._failSpawns, {this.idleTtl});

  final String? libraryPath;
  int max;

  /// 空闲 worker 的保留时长；null = 常驻不回收。回收时至少留一个。
  final Duration? idleTtl;

  /// 各空闲 worker 变空闲的时刻（[_clock] 的读数）。
  final Map<_Worker, Duration> _idleSince = <_Worker, Duration>{};
  Timer? _retireTimer;
  static final Stopwatch _clock = Stopwatch()..start();
  final bool Function() _failSpawns;
  final List<_Worker> _idle = <_Worker>[];
  final Set<_Worker> _all = <_Worker>{};
  final Queue<_Job<Object?>> _waiting = Queue<_Job<Object?>>();
  int _live = 0;
  int spawnedTotal = 0;

  int get live => _live;

  void setMax(int n) {
    max = n < 1 ? 1 : n;
    while (_waiting.isNotEmpty && _live < max) {
      _spawnFor(_waiting.removeFirst());
    }
  }

  /// [w] 进空闲表：记时刻，按需排一次回收（一次性定时器，挂根 zone；不轮询）。
  void _park(_Worker w) {
    _idle.add(w);
    final Duration? ttl = idleTtl;
    if (ttl == null) return;
    _idleSince[w] = _clock.elapsed;
    _retireTimer ??= Zone.root.createTimer(ttl, _retireIdle);
  }

  /// 收掉空闲满 [idleTtl] 的 worker（至少留一个活着的）；还有会到期的就再排一次。
  void _retireIdle() {
    _retireTimer = null;
    final Duration ttl = idleTtl!;
    final Duration now = _clock.elapsed;
    // 空闲表里先放回的在前（派发取表尾）。
    for (final _Worker w in List<_Worker>.of(_idle)) {
      if (_live <= 1) break;
      final Duration since = _idleSince[w]!;
      if (now - since < ttl) continue;
      _idle.remove(w);
      _idleSince.remove(w);
      _all.remove(w);
      _live--;
      w.kill();
    }
    if (_live > 1 && _idle.isNotEmpty) {
      final Duration earliest = _idle
          .map((_Worker w) => _idleSince[w]!)
          .reduce((Duration a, Duration b) => a < b ? a : b);
      Duration wait = earliest + ttl - now;
      if (wait < Duration.zero) wait = Duration.zero;
      _retireTimer = Zone.root.createTimer(wait, _retireIdle);
    }
  }

  void submit(_Job<Object?> j) {
    if (_idle.isNotEmpty) {
      final _Worker w = _idle.removeLast();
      _idleSince.remove(w);
      _dispatch(w, j);
    } else if (_live < max) {
      _spawnFor(j);
    } else {
      _waiting.add(j);
    }
  }

  void forget(int address) {
    for (final _Worker w in _all) {
      w.forget(address);
    }
  }

  /// 起一个新 worker 跑 [j]。起 isolate 的回调挂在根 zone 上（见库注释）。起不来：[j] 报错，排着的下一条接着
  /// 去起（以前只 `_live--`，在途的全没了、排队的再也没人发，永远挂着）。
  void _spawnFor(_Job<Object?> j) {
    _live++;
    spawnedTotal++;
    Zone.root.run(
      () =>
          (_failSpawns()
                  ? Future<_Worker>.error(
                      StateError('SrsCoreWorkers: spawn failed (test)'),
                    )
                  : _Worker.spawn(libraryPath))
              .then(
                (_Worker w) {
                  _all.add(w);
                  _dispatch(w, j);
                },
                onError: (Object e, StackTrace s) {
                  _live--;
                  j.fail(e, s);
                  if (_waiting.isNotEmpty && _live < max) {
                    _spawnFor(_waiting.removeFirst());
                  }
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
      _all.remove(w);
      w.kill();
      // 让一条排队的命令去起新的 worker。
      if (_waiting.isNotEmpty) _spawnFor(_waiting.removeFirst());
      return;
    }
    if (_waiting.isNotEmpty) {
      _dispatch(w, _waiting.removeFirst());
    } else {
      _park(w);
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

  /// 让 worker 丢掉为 [address] 包的 [SrsCore]（没有回执）。
  void forget(int address) => _inbox.send((address, null, null));

  void kill() => _isolate.kill(priority: Isolate.immediate);
}

/// worker isolate 里为各句柄包的 [SrsCore]（每个 isolate 一份）。
final Map<int, SrsCore> _workerCores = <int, SrsCore>{};

/// 测试：在 worker 里调（作为命令），返回这个 worker 当前缓存着几个句柄的包装。
@visibleForTesting
int srsCoreWorkerCachedCores(SrsCore _) => _workerCores.length;

void _workerMain((SendPort, String?) init) {
  final (SendPort ready, String? libraryPath) = init;
  final ReceivePort inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((Object? m) {
    final (int address, Object? rawJob, SendPort? reply) =
        m! as (int, Object?, SendPort?);
    if (reply == null) {
      // [SrsCoreWorkers.forget]：句柄已关闭。
      _workerCores.remove(address);
      return;
    }
    final Object? Function(SrsCore) job = rawJob! as Object? Function(SrsCore);
    try {
      final SrsCore core = _workerCores[address] ??= SrsCore.fromAddress(
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
