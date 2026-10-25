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
    this.idleRecheck = const Duration(seconds: 20),
    this.unsupportedRecheck = const Duration(minutes: 10),
    this.maxBackoff = const Duration(minutes: 2),
  }) : _wait = wait,
       _ready = ready,
       _onChange = onChange;

  final Future<int?> Function(int? after) _wait;
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

/// 本机变动后的去抖推送：[trigger] 每次本机复习数据变动调一次，静默 [debounce] 后跑 [push] 一次。
class SrsLocalPush {
  SrsLocalPush({
    required Future<void> Function() push,
    this.debounce = const Duration(seconds: 5),
  }) : _push = push;

  final Future<void> Function() _push;
  final Duration debounce;
  Timer? _timer;
  bool _disposed = false;

  void trigger() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(_push().catchError((Object _) {}));
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
