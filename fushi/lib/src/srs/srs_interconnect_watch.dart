/// 复习同步的互联快速通道（客户端侧，docs/specs/2026-10-25-srs-sync-v2-design.md §6.3）。
///
/// 网盘只能定时轮询；连着互联 host 时可以更快：
/// - **拉**：长轮询 host 的 `GET /api/srs/changes`（[InterconnectSyncBackend.waitSrsChanges]）。别的设备往 host 写了
///   head、或 host 自己发布了新数据，令牌就变，这边立刻跑一轮同步。
/// - **推**：本机复习数据有变动后去抖几秒跑一轮（[SrsLocalPush]），对端经上面的长轮询几秒内看到。
///
/// 协议、去重、合并与网盘路径完全同一套（同一个 [SrsSyncScheduler] 的一轮），这里只决定「什么时候跑」。
library;

import 'dart:async';
import 'dart:math';

import 'package:fushi_engine/sync/srs_change_feed.dart' show SrsChangePoll;

/// 长轮询循环。[wait] 返回 host 的当前令牌（老 host 不支持返回 null）；[ready] 为假时（互联没开 / 没配对 /
/// app 在后台 / 复习模块关着）不发请求，隔一会儿再看。
///
/// **断线 / 没准备好期间令牌不作废**：重连（或回到前台）后带着断开前的令牌接着长轮询。host 在这期间有了新数据（或 host
/// 重启过：[SrsChangeFeed] 的令牌以启动时刻起步，必然不同）时这次请求立刻回新令牌、跑一轮；没变就照常挂住，什么也不跑。
/// 以前断线一律在退避后补跑一整轮复习同步——iOS 每次退后台都会掐断长轮询，回来就对 host 空跑一轮（反馈：iPhone
/// 「一直在同步」、电脑 host 跟着卡）。
///
/// 令牌的推进全是本机自己写 head 引起的（[SrsChangePoll.ownOnly]，BUG-4382）就只记下新令牌、不跑一轮：本机刚发
/// 出去的东西不用再收回来，以前每次「立即同步」/ 推送写完 head 都经 host 把自己叫醒再空跑一轮，同步状态行在
/// 「已同步」之后又从「准备」走一遍。
class SrsInterconnectWatcher {
  SrsInterconnectWatcher({
    required Future<SrsChangePoll?> Function(int? after) wait,
    required Future<bool> Function() ready,
    required Future<void> Function() onChange,
    void Function()? onReachable,
    void Function()? onGap,
    this.idleRecheck = const Duration(seconds: 20),
    this.unsupportedRecheck = const Duration(minutes: 10),
    this.maxBackoff = const Duration(minutes: 2),
  }) : _wait = wait,
       _ready = ready,
       _onChange = onChange,
       _onReachable = onReachable,
       _onGap = onGap;

  final Future<SrsChangePoll?> Function(int? after) _wait;

  /// 长轮询成功回了一次（host 此刻可达）：app 据此清掉本机推送的失败退避（[SrsLocalPush.resetBackoff]）。
  final void Function()? _onReachable;

  /// 这一刻起，长轮询不能保证 host 上的新数据都会叫醒本机（app 据此记一个缺口，进复习 tab 时补跑经 host 的那一路，
  /// `SrsSyncScheduler.markHostLaneGap`，BUG-5603）：
  /// - 长轮询失败（断网 / 5xx / 代理切断长连接）：失败期间 host 上的写入由重连后的令牌比对发现，但若一直连不上就一直
  ///   发现不了；
  /// - host 不支持（老 host 返回 null）：根本没有变更通知；
  /// - 第一次拿到基线令牌：拿基线之前 host 上写入的数据，令牌比对看不出来（这一次唤醒之前开跑的轮次因此不记成补上）。
  final void Function()? _onGap;
  final Future<bool> Function() _ready;
  final Future<void> Function() _onChange;
  final Duration idleRecheck;
  final Duration unsupportedRecheck;
  final Duration maxBackoff;

  bool _running = false;
  Completer<void>? _sleeping;
  Timer? _sleepTimer;

  /// 已经在跑就什么也不做。
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    _wake();
  }

  /// 提前结束当前的等待（app 回到前台、刚开了互联）。
  void nudge() => _wake();

  void _wake() {
    _sleepTimer?.cancel();
    final Completer<void>? c = _sleeping;
    _sleeping = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _sleep(Duration d) {
    final Completer<void> c = Completer<void>();
    _sleeping = c;
    _sleepTimer = Timer(d, _wake);
    return c.future;
  }

  Future<void> _loop() async {
    int? token;
    int failures = 0;
    while (_running) {
      bool ready;
      try {
        ready = await _ready();
      } on Object {
        ready = false;
      }
      if (!_running) break;
      if (!ready) {
        // 令牌留着：准备好之后与 host 当前令牌一比就知道这期间有没有新数据（见类注释）。
        await _sleep(idleRecheck);
        continue;
      }
      try {
        final SrsChangePoll? poll = await _wait(token);
        if (!_running) break;
        failures = 0;
        _onReachable?.call();
        if (poll == null) {
          _onGap?.call();
          await _sleep(unsupportedRecheck);
          continue;
        }
        if (token == null) _onGap?.call();
        // 第一次只是拿基线；之后令牌变了、且不全是本机自己写的才同步。
        final bool changed =
            token != null && poll.token != token && !poll.ownOnly;
        token = poll.token;
        if (changed) await _onChange();
      } on Object {
        // 断网 / host 重启 / 换路：退避后带着原令牌重连（见类注释），不盲目补跑整轮；记一个缺口（见 [_onGap]）。
        failures++;
        _onGap?.call();
        await _sleep(_watchBackoff(failures, maxBackoff));
      }
    }
  }
}

/// 长轮询第 [failures] 次连续失败后的退避：2 s 起每次翻倍，封顶 [maxBackoff]。
Duration _watchBackoff(int failures, Duration maxBackoff) => Duration(
  milliseconds: min(
    maxBackoff.inMilliseconds,
    1000 * pow(2, min(failures, 7)).toInt(),
  ),
);

/// 跑一轮覆盖 [pushes] 全部通道的同步 [fullSync]（「立即同步」，BUG-4382）：先撤掉此刻排着的推送并清掉退避
/// （用户明说「现在就同步」），由这一轮一并带上；这一轮没同步成功（[synced] 为假或抛错）就把撤掉的推送排回去。
Future<T> srsSyncSupersedingPushes<T>(
  List<SrsLocalPush> pushes,
  Future<T> Function() fullSync, {
  required bool Function(T result) synced,
}) async {
  final List<SrsLocalPush> taken = <SrsLocalPush>[
    for (final SrsLocalPush p in pushes)
      if (p.takePending()) p,
  ];
  for (final SrsLocalPush p in pushes) {
    p.resetBackoff();
  }
  void restore() {
    for (final SrsLocalPush p in taken) {
      p.trigger();
    }
  }

  final T result;
  try {
    result = await fullSync();
  } catch (_) {
    restore();
    rethrow;
  }
  if (!synced(result)) restore();
  return result;
}

/// 进复习 tab 这一次做了什么（[srsSyncOnTabEntry]）。
enum SrsTabEntrySync {
  /// 自动同步关着 / 首次同步还没确认：照旧节流跑全部通道（此时没有推送与长轮询，进 tab 是唯一的自动同步）。
  throttled,

  /// 经互联 host 那一路有已知缺口：补跑这一路（带上排着的互联推送），云盘 / 文件夹照常节流拉。
  gapRound,

  /// 经互联 host 那一路有缺口，但此刻在退避 / 节流期内：不打 host，只推排着的（推送自己也守退避）、节流拉云盘 / 文件夹。
  gapHeldOff,

  /// 没有缺口：只把排着的推送立即推掉、节流拉一遍不经互联 host 的位置。
  pushAndPull,
}

/// 进复习 tab 时的同步（反馈：iPhone「切个模块就在同步」、电脑 host 跟着卡，BUG-5603）。以前每次进 tab 都按 60 s
/// 节流对全部通道跑整轮，互联 host 上是一串 PROPFIND / GET / PUT，还占着整轮同步锁。现在按两路分开：
/// - [throttledOnly] 为真（自动同步关着 / 首次同步没确认）：[throttledRound]，同旧行为；
/// - **经互联 host 那一路**：有缺口（[hasHostGap]：上次成功补上之后这一路没同步成 / 长轮询断过；或 [hostPush] 推送失败
///   过）时，经 [SrsLocalPush.runInstead] 跑 [hostGapRound]（只补这一路，带上排着的互联推送，失败照推送记退避）——但
///   [hostHeldOff]（互联选路退避 / 缺口轮的节流）或 [hostPush] 自己的推送退避期内不跑：host 离线是常态，缺口会一直在，
///   不能每次进 tab 都去探一遍。没缺口（或在退避）时只把排着的互联推送 [SrsLocalPush.flush]（退避期内照旧等）；host 上的
///   新数据由长轮询即时同步。
/// - **不经 host 的位置**（云盘 / 文件夹，没有变更通知）：排着的云盘推送立即推，[pullDirect] 按自己的节流拉一遍。与
///   host 那一路的缺口无关：host 离线不会让每次进 tab 都把云盘整轮跑一遍。
Future<SrsTabEntrySync> srsSyncOnTabEntry({
  required Future<bool> Function() throttledOnly,
  required Future<void> Function() throttledRound,
  required bool Function() hasHostGap,
  required bool Function() hostHeldOff,
  required Future<bool> Function() hostGapRound,
  required Future<void> Function() pullDirect,
  required SrsLocalPush hostPush,
  required SrsLocalPush directPush,
}) async {
  if (await throttledOnly()) {
    await throttledRound();
    return SrsTabEntrySync.throttled;
  }
  final SrsTabEntrySync outcome;
  if (hasHostGap() || hostPush.failures > 0) {
    if (hostPush.backedOff || hostHeldOff()) {
      hostPush.flush();
      outcome = SrsTabEntrySync.gapHeldOff;
    } else {
      await hostPush.runInstead(hostGapRound);
      outcome = SrsTabEntrySync.gapRound;
    }
  } else {
    hostPush.flush();
    outcome = SrsTabEntrySync.pushAndPull;
  }
  directPush.flush();
  await pullDirect();
  return outcome;
}

/// 不在复习页时本机变动后的去抖（设计 §6.2：防抖 10 s）。
const Duration kSrsLocalPushDebounce = Duration(seconds: 10);

/// 复习中本机推送的最长等待（审查 S-8）：复习页开着时不按「静默多久」去抖（几乎每答一张卡就跑一轮：新开一个
/// 1 条操作的小段、写 head、唤醒对端、对端 ack 变了又写 head 回唤醒），而是第一次变动起最多等这么久推一次，期间的
/// 变动并进这一次；离开复习页 / app 进后台立即推（[SrsLocalPush.flush]）。取 45 s：对端在复习时看到进度的延迟可接受，
/// 一组复习（常见 10~20 分钟）只推十几轮。只在这里定义。
const Duration kSrsLocalPushMaxWait = Duration(seconds: 45);

/// 本机变动后的推送：[trigger] 每次本机复习数据变动调一次。平时静默 [debounce] 后跑 [push] 一次；[batching] 为真
/// （在复习页）时改为第一次变动起最长等 [maxWait] 再推（之后的变动不顺延），[flush] 立即推掉待推的。
///
/// **失败退避**（反馈 XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL）：[push] 返回 false 或抛错 = 这次没推成（host 不可达
/// 等）。之后的触发至少等到退避期满才推：[backoffBase] 起每次失败翻倍、封顶 [maxBackoff]；期间的触发合并成到期
/// 时的一次。以前每答一张卡（去抖 5 s）就对死地址探测一轮、每轮数秒，跟着用户答卡无限重复。[push] 成功、网络
/// 恢复（长轮询重新连上）或用户手动同步时 [resetBackoff] 清零。退避期间本机改动不丢：数据在本机日志里，下一次
/// 推送 / 常规同步 / 长轮询恢复后的补同步都会带上。同一时刻只有一次 [push] 在跑，跑的时候又来的触发在它结束后
/// 再按规则排一次。
class SrsLocalPush {
  SrsLocalPush({
    required Future<bool> Function() push,
    this.debounce = kSrsLocalPushDebounce,
    this.maxWait = kSrsLocalPushMaxWait,
    bool Function()? batching,
    this.backoffBase = const Duration(seconds: 30),
    this.maxBackoff = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _push = push,
       _batching = batching,
       _clock = clock ?? DateTime.now;

  final Future<bool> Function() _push;
  final bool Function()? _batching;
  final Duration debounce;

  /// [batching] 为真时，第一次变动到推送的最长等待。
  final Duration maxWait;
  final Duration backoffBase;
  final Duration maxBackoff;
  final DateTime Function() _clock;
  Timer? _timer;
  bool _disposed = false;
  bool _running = false;
  bool _again = false;

  /// 跑的时候来了 [flush]：这一次结束后立即再推，不再等。
  bool _againNow = false;
  int _failures = 0;
  DateTime? _blockedUntil;

  /// 连续失败次数（测试 / 诊断读）。
  int get failures => _failures;

  /// 退避到期时刻；null = 没在退避。
  DateTime? get blockedUntil => _blockedUntil;

  /// 此刻在失败退避期内（[blockedUntil] 还没到）。
  bool get backedOff {
    final DateTime? until = _blockedUntil;
    return until != null && _clock().isBefore(until);
  }

  /// 有排着、还没推的变动。
  bool get pending => _timer != null || _again;

  void trigger() {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    if ((_batching?.call() ?? false) && _timer != null) return;
    _schedule();
  }

  /// 离开复习页 / app 进后台：有待推的就立即推（退避期内照旧等到期，不去敲刚失败过的地址）。
  void flush() {
    if (_disposed || !pending) return;
    if (_running) {
      _again = true;
      _againNow = true;
      return;
    }
    _schedule(now: true);
  }

  /// 一轮覆盖全部通道的同步（「立即同步」）马上就要跑（BUG-4382）：此刻排着的推送由它一并带上，撤掉不再单独推；
  /// 返回撤掉前有没有待推的。正在跑的那次推送照常跑完（它已经在同步队列里）；之后再来的触发照常排。那一轮没同步
  /// 成功时调用方把撤掉的待推 [trigger] 回来——推送本身也会失败退避，但本机改动不能因为被撤掉而等不到下一次推送。
  /// 以前「立即同步」报完「已同步」后，排着的推送在去抖到期时又各跑一轮（什么都不用推），同步状态行再走一遍。
  bool takePending() {
    final bool had = pending;
    _timer?.cancel();
    _timer = null;
    _again = false;
    _againNow = false;
    return had;
  }

  /// 用 [round]（覆盖这条推送那组通道的一轮，进复习 tab 补缺口，BUG-5603）代替此刻排着的推送：撤掉排着的、跑
  /// [round]，结局照推送本身记失败退避（成功清零、失败翻倍）——[srsSyncSupersedingPushes] 是用户明说「现在就同步」，
  /// 会清掉退避；自动补缺口不能，否则 host 一直报错时每次进 tab 都把退避清零重来。没跑成（假或抛错）且撤掉前有待推的，
  /// 按退避重新排上。
  Future<bool> runInstead(Future<bool> Function() round) async {
    final bool had = takePending();
    bool ok = false;
    try {
      ok = await round();
      return ok;
    } finally {
      _noteOutcome(ok);
      if (!ok && had) trigger();
    }
  }

  /// 网络恢复 / 用户手动同步：清掉退避；有待推的就按普通去抖重新排。
  void resetBackoff() {
    _failures = 0;
    _blockedUntil = null;
    if (_timer != null && !_disposed) _schedule();
  }

  void _schedule({bool now = false}) {
    _timer?.cancel();
    Duration delay = now
        ? Duration.zero
        : (_batching?.call() ?? false)
        ? maxWait
        : debounce;
    final DateTime? until = _blockedUntil;
    if (until != null) {
      final Duration left = until.difference(_clock());
      if (left > delay) delay = left;
    }
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    if (_disposed) return;
    _running = true;
    bool ok;
    try {
      ok = await _push();
    } on Object {
      ok = false;
    }
    _running = false;
    _noteOutcome(ok);
    if (_again && !_disposed) {
      _again = false;
      final bool now = _againNow;
      _againNow = false;
      _schedule(now: now);
    }
  }

  /// 一次推送（或代替它的一轮）的结局记进失败退避：成功清零，失败从 [backoffBase] 起翻倍、封顶 [maxBackoff]。
  void _noteOutcome(bool ok) {
    if (ok) {
      _failures = 0;
      _blockedUntil = null;
      return;
    }
    _failures++;
    final int ms = min(
      maxBackoff.inMilliseconds,
      backoffBase.inMilliseconds * pow(2, min(_failures - 1, 20)).toInt(),
    );
    _blockedUntil = _clock().add(Duration(milliseconds: ms));
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
