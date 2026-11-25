/// 同步的按资源加锁（BUG-1569③ / 反馈 kM-Gb_Xnu-）。
///
/// 此前所有同步入口共用一把全局互斥 `_autoSyncMutex`（HBK-AUDIT-049）：全量 sweep
/// 一跑几分钟，期间退出一本书，这本书的进度同步只能排在整轮后面。那把锁真正要护的
/// 是三样东西，这里把它们拆成各自的资源：
///
/// - **整轮**（[kSyncRoundResource]）：全量 sweep / 手动同步 / 资产传输 / 合集轻量
///   同步 / 对比弹窗 / 复习（SRS）同步彼此仍然串行。SRS 原生侧同一时刻只能有一个
///   ingest session，host 端的同步状态折叠也假定同一 client 不会两轮交错，这些约束
///   都由「整轮」继续兜住。
/// - **通道后端**（[syncChannelResource]）：云后端是带可变状态（令牌、folder-id
///   缓存）的进程级单例，没有自己的锁，任何一次使用都要独占这条通道。互联后端的
///   WebDAV 文件箱与 folder 缓存同理；它的 live HTTP 端点（书进度 GET / PUT）则和
///   书架、视频页这些常驻消费方一样本来就是并发使用的，不需要这把锁。
/// - **单本书**（[syncBookResource]）：同一本书的进度判定 + 落地（读本地 → 判定 →
///   写 host / 写本地 → 记基线）必须原子，否则两条路径会拿各自读到的旧值互相覆盖。
///
/// 加锁顺序固定为「整轮 → 通道 → 书」：只有持有整轮 / 通道的一方会在持锁时再去
/// 等书锁，持有书锁的一方从不再等别的资源。[SyncResourceLocks.withResources] 一次
/// 拿齐一组资源（拿不齐就什么都不占、排队），所以不存在「占着一半等另一半」的环。
library;

import 'dart:async';
import 'dart:collection';

import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:meta/meta.dart';

/// 整轮同步（全库级操作）的资源键。
const String kSyncRoundResource = 'round';

/// 一条同步通道后端的资源键。
String syncChannelResource(SyncChannelScope scope) => 'channel:${scope.id}';

/// 一本书的资源键（按 bookKey）。
String syncBookResource(String bookKey) => 'book:$bookKey';

class _Waiter {
  _Waiter(this.keys, this.owner);
  final Set<String> keys;
  final Object? owner;
  final Completer<void> granted = Completer<void>();
}

/// 一组命名资源的锁表。单线程（Dart isolate）语义：授予在同一段同步代码里完成，
/// 检查与占用之间没有被插队的窗口。
/// zone 里记「当前在哪个 owner 的锁里」的键：持锁方 [body] 里发出的嵌套请求（sweep
/// 的书进度阶段要书锁、对比弹窗的应用要书锁）不必一路传 owner，自动沿用。
final Object _ownerZoneKey = Object();

class SyncResourceLocks {
  /// 资源键 → 当前持有者（[withResources] 的 owner）。
  final Map<String, Object?> _held = <String, Object?>{};
  final Queue<_Waiter> _waiters = Queue<_Waiter>();

  /// 资源键 → 被释放过的次数。见 [generationOf]。
  final Map<String, int> _releases = <String, int>{};

  /// [key] 被（任何人）持有并释放过的次数。全量 sweep 用它判断「我批量读到 host
  /// 进度之后，这本书有没有被别的路径同步过」——有就重读，不拿旧快照去落地。
  int generationOf(String key) => _releases[key] ?? 0;

  /// 此刻持有 [keys] 中任一资源的持有者（去重、按资源顺序）；空 = 没人挡路。
  List<Object?> holdersOf(Set<String> keys) {
    final List<Object?> out = <Object?>[];
    for (final String key in keys) {
      if (!_held.containsKey(key)) continue;
      final Object? holder = _held[key];
      if (!out.contains(holder)) out.add(holder);
    }
    return out;
  }

  bool _free(Set<String> keys) => !keys.any(_held.containsKey);

  /// [owner] 此刻是否已持有资源（它的新请求是嵌套请求）。
  bool _holdsAny(Object? owner) =>
      owner != null && _held.values.any((Object? h) => identical(h, owner));

  /// [ahead] 里（排在前面、还在等）是否有**别的 owner** 的请求和 [keys] 抢同一样
  /// 东西。同一 owner 的并行请求是同一件事的几部分（退出书同时排云通道与互联通道），
  /// 不互相让位：否则「云那份在等 sweep 放掉云后端」会把只要书锁的互联那份一起拖住。
  bool _contendedAhead(
    Set<String> keys,
    Iterable<_Waiter> ahead,
    Object? owner,
  ) => ahead.any(
    (_Waiter w) => !identical(w.owner, owner) && w.keys.any(keys.contains),
  );

  /// 拿齐 [keys] 后跑 [body]，结束（含抛错）时全部释放。
  ///
  /// [owner] 标识请求方：排队方据此知道自己在等谁（同步任务面板显示「等待…」），
  /// 同一 [owner] 持锁时再发的请求被视为嵌套请求（见 [_grantWaiters]）。省略时沿用
  /// 外层锁的 owner（[body] 跑在记着 owner 的 zone 里）；连外层都没有就是一个新的
  /// 匿名 owner。嵌套请求只能按「整轮 → 通道 → 书」往下拿，且不能再要自己已持有
  /// 的资源（不可重入）。
  /// [onWait] 在需要排队时**同步**调用一次，参数是此刻挡路的持有者。
  Future<T> withResources<T>(
    Set<String> keys,
    Future<T> Function() body, {
    Object? owner,
    void Function(List<Object?> holders)? onWait,
  }) async {
    final Set<String> wanted = Set<String>.unmodifiable(keys);
    final Object who = owner ?? Zone.current[_ownerZoneKey] ?? Object();
    final bool nested = _holdsAny(who);
    if (_free(wanted) && (nested || !_contendedAhead(wanted, _waiters, who))) {
      _take(wanted, who);
    } else {
      final _Waiter waiter = _Waiter(wanted, who);
      _waiters.add(waiter);
      onWait?.call(holdersOf(wanted));
      await waiter.granted.future;
    }
    try {
      return await runZoned(
        body,
        zoneValues: <Object?, Object?>{_ownerZoneKey: who},
      );
    } finally {
      _release(wanted);
    }
  }

  void _take(Set<String> keys, Object? owner) {
    for (final String key in keys) {
      _held[key] = owner;
    }
  }

  void _release(Set<String> keys) {
    for (final String key in keys) {
      _held.remove(key);
      _releases[key] = (_releases[key] ?? 0) + 1;
    }
    _grantWaiters();
  }

  /// 按排队顺序授予：一个等待者能拿齐、且不和排在它前面仍在等的请求抢同一样东西
  /// 时才授予——大请求（整轮 + 全部通道）不会被源源不断的小请求饿死。
  ///
  /// 例外是**嵌套请求**（请求方已持有别的资源，例如 sweep 持着通道再要一本书）：
  /// 它只看资源是否空闲，不让位给前面的等待者。否则「sweep 等前面的人、前面的人
  /// 等 sweep 释放通道」就成了环。嵌套请求一律在加锁顺序的更下层，前面那个等待者
  /// 若要的也是这本书，它本来就还拿不齐（通道还在 sweep 手里）。
  void _grantWaiters() {
    final List<_Waiter> stillWaiting = <_Waiter>[];
    final List<_Waiter> toGrant = <_Waiter>[];
    for (final _Waiter w in _waiters) {
      final bool grantable =
          _free(w.keys) &&
          (_holdsAny(w.owner) ||
              !_contendedAhead(w.keys, stillWaiting, w.owner));
      if (grantable) {
        _take(w.keys, w.owner);
        toGrant.add(w);
      } else {
        stillWaiting.add(w);
      }
    }
    _waiters
      ..clear()
      ..addAll(stillWaiting);
    for (final _Waiter w in toGrant) {
      w.granted.complete();
    }
  }

  /// 此刻是否有人持有 [key]（测试观察点）。
  @visibleForTesting
  bool isHeld(String key) => _held.containsKey(key);

  /// 排队中的请求数（测试观察点）。
  @visibleForTesting
  int get waiterCount => _waiters.length;
}

/// 全部同步入口共用的那一张锁表。
final SyncResourceLocks syncResourceLocks = SyncResourceLocks();
