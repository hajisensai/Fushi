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

/// 长轮询循环。[wait] 返回 host 的当前令牌（老 host 不支持返回 null）；[ready] 为假时（互联没开 / 没配对 /
/// app 在后台 / 复习模块关着）不发请求，隔一会儿再看。
class SrsInterconnectWatcher {
  SrsInterconnectWatcher({
    required Future<int?> Function(int? after) wait,
    required Future<bool> Function() ready,
    required Future<void> Function() onChange,
    void Function()? onReachable,
    this.idleRecheck = const Duration(seconds: 20),
    this.unsupportedRecheck = const Duration(minutes: 10),
    this.maxBackoff = const Duration(minutes: 2),
  }) : _wait = wait,
       _ready = ready,
       _onChange = onChange,
       _onReachable = onReachable;

  final Future<int?> Function(int? after) _wait;

  /// 长轮询成功回了一次（host 此刻可达）：app 据此清掉本机推送的失败退避（[SrsLocalPush.resetBackoff]）。
  final void Function()? _onReachable;
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
        token = null;
        await _sleep(idleRecheck);
        continue;
      }
      try {
        final int? t = await _wait(token);
        if (!_running) break;
        failures = 0;
        _onReachable?.call();
        if (t == null) {
          await _sleep(unsupportedRecheck);
          continue;
        }
        // 第一次只是拿基线；之后令牌变了才同步。
        final bool changed = token != null && t != token;
        token = t;
        if (changed) await _onChange();
      } on Object {
        // 断网 / host 重启 / 换路：退避后重来，令牌作废（重新拿基线，重连后先补一轮）。
        failures++;
        final bool hadToken = token != null;
        token = null;
        await _sleep(
          Duration(
            milliseconds: min(
              maxBackoff.inMilliseconds,
              1000 * pow(2, min(failures, 7)).toInt(),
            ),
          ),
        );
        if (hadToken && _running) {
          try {
            await _onChange();
          } on Object {
            // 补的这一轮失败就等下一次唤醒。
          }
        }
      }
    }
  }
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
    if (ok) {
      _failures = 0;
      _blockedUntil = null;
    } else {
      _failures++;
      final int ms = min(
        maxBackoff.inMilliseconds,
        backoffBase.inMilliseconds * pow(2, min(_failures - 1, 20)).toInt(),
      );
      _blockedUntil = _clock().add(Duration(milliseconds: ms));
    }
    if (_again && !_disposed) {
      _again = false;
      final bool now = _againNow;
      _againNow = false;
      _schedule(now: now);
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
