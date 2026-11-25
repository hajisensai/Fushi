import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/video/media_server/media_server_route_failover.dart';
import 'package:fushi/src/media/video/media_server/media_server_user_data_changes.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_library_source.dart';

/// 远端库列表（互联对端 / 云盘）的统一读取入口：TTL 缓存 + in-flight 去重 + 显式失效。
///
/// **为什么需要它（BUG-1180）**——远端条目列表此前在每个消费方裸调 `client.listX()`：
/// 书架（`reader_history/remote.part.dart`）、漫画书架（同一 State 类的另一实例）、
/// 视频页（`home_video_page.dart`）、首页 dashboard（`home_dashboard_page.dart`）各一份。
/// 而书架/视频页为了让对端新增内容可见（BUG-992/994）各注册了「切回本 tab 就重拉」的
/// 监听器。净效果是：顶层 tab 保活（BUG-750）省下的重建，被这两个监听器原样加成了
/// 「每切一次页面 = 一整轮完整网络往返」。列表本身此前**没有任何**缓存层——只有封面图
/// 有磁盘缓存（`remote_cover_cache.dart`），条目列表每次都是裸 GET + jsonDecode。
///
/// **为什么是通用 slot 而不是每域一份字段**——互联每加一个媒体域（书 / 视频 / 有声书 /
/// 活动 / 词典，将来还有游戏、漫画）都要复制一遍「缓存 + 去重 + 失效」三件套，这正是
/// 「每次加新东西都要重构互联」的一角。这里只有一张 `key -> slot` 表：新增一个域 =
/// 传一个新 key 加一个取数闭包，缓存代码零增量，没有新分支。
///
/// **缓存的是网络层，不是组装结果**——[read] 只包住 `client.listRemoteX()` 这一层，
/// 本地 DB 查询与去重（`dedupeRemoteBooks` 等）仍每次照跑。所以本地新增/删除条目立即
/// 反映在混排网格里，只有「问对端要清单」这一步被 TTL 挡住，BUG-992/994 的用户可见
/// 语义（切回 tab 远端卡在场）不受影响。
///
/// **槽由 (来源身份, 域) 联合定位（BUG-1202）**——只按域分槽会让互联对端与云盘备份
/// 后端共用同一个 `videos` / `books` 槽，于是「互联拉过的清单」被云盘那次读原样命中，
/// 用户在云盘视图里看到互联对端的条目且不报错。来源身份由来源自己申报
/// （[RemoteLibrarySource.remoteLibrarySourceId]），是 [read] 的必填参数——新增任何
/// 一种远端源，编译器当场要求它给出身份，「忘了分槽」这个失败模式不存在。
///
/// **失效有两条路**：① 用户显式下拉刷新 → [read] 传 `forceRefresh: true`；
/// ② 对端身份变了 → [remoteLibraryCacheProvider] 订阅
/// `InterconnectSyncBackend.sessionIdentityRevision` 自动 [invalidateAll]。
/// 缓存类自身不试图从 client 身份推断对端是否换人（那种推断在多地址候选 + 单例
/// backend 的现实下必然出错），判据由 backend 给，本类只负责照做。
///
/// 注意这两条路都**只覆盖互联**（下拉刷新是用户手动的，revision 只在互联内部自增），
/// 所以「换云盘后端 / 翻互联开关」不能指望它们——那正是要靠上面的按源分槽在结构上
/// 消灭掉，而不是再补第三个失效信号。
class RemoteLibraryCache {
  RemoteLibraryCache({
    this.defaultTtl = const Duration(seconds: 60),
    this.inFlightTtl = const Duration(seconds: 60),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 未显式指定 `ttl` 时的新鲜期。60s 的取舍：切页面/切 tab 是秒级操作，必须命中缓存；
  /// 而「对端刚加了一本书」的可见延迟上限一分钟，仍在用户可接受范围，且下拉刷新随时
  /// 可以强制穿透。
  final Duration defaultTtl;

  /// 在途请求的最大信任时长（BUG-1567 防御纵深）。取数闭包正常都带整体超时
  /// （[InterconnectSyncBackend.requestTimeout]，15s），future 必然落定并释放槽；
  /// 但任何一条**漏了超时**的取数路径一旦永久悬挂，同槽的所有后续 [read] 都会
  /// 复用这个死 future——远端库页从此永远转圈、永不自愈。超过本时长的在途请求
  /// 视为挂死：不再复用，直接发起新取数（generation 自增使死 future 迟到的写回
  /// 被丢弃）。取值必须显著大于最慢的合法小型请求（15s），60s 留足余量。
  final Duration inFlightTtl;

  final int Function() _nowMs;
  final Map<String, _CacheSlot> _slots = <String, _CacheSlot>{};

  /// 按 id 单查回来的条目（[readByIds]），与整份清单槽同一个联合定位符、分表存放：
  /// 它们只是「清单里的几条」，**不**冒充整份清单——[peek] / [wouldReadImmediately]
  /// / [read] 从不读这里，库页不会因为详情页查过三集就以为远端只有三集。
  final Map<String, _ItemSlot> _itemSlots = <String, _ItemSlot>{};

  /// 读 [sourceId] 这个来源的 [key] 域列表：命中未过期缓存直接返回；有同槽请求在途
  /// 则复用它（in-flight 去重，解决书架/漫画/首页同帧并发问一样东西）；否则调 [fetch]
  /// 取数。
  ///
  /// [sourceId] 取自 [RemoteLibrarySource.remoteLibrarySourceId]——**必填**，因为
  /// 「同一个域、不同来源」的清单毫无关系，共用一个槽就是 BUG-1202 的串味。调用方
  /// 不该自己编字面量，从手里那个 client/source 上读。
  ///
  /// [forceRefresh] 为 true 时无条件重新取数（下拉刷新语义），并让任何在途的旧请求
  /// 作废——靠 slot 的 generation 计数拦截，避免旧请求后到把新结果覆盖回去。
  ///
  /// [fetch] 抛出时**不缓存失败**，也不清掉已有的旧值：异常原样上抛给调用方按既有的
  /// 「拉取失败 → 占位卡不出现」降级处理，而旧值保留让离线时仍能显示上一次已知列表。
  /// 由于失败不刷新 `fetchedAt`，下一次读必然重试。
  Future<T> read<T>({
    required String sourceId,
    required String key,
    required Future<T> Function() fetch,
    Duration? ttl,
    bool forceRefresh = false,
  }) {
    final _CacheSlot slot = _slots.putIfAbsent(
      _slotKey(sourceId, key),
      () => _CacheSlot(),
    );

    if (!forceRefresh) {
      final Future<Object?>? inFlight = _trustedInFlight(slot);
      if (inFlight != null) {
        return inFlight.then((Object? value) => value as T);
      }
      if (_hasFreshValue(slot, ttl)) {
        return Future<T>.value(slot.value as T);
      }
    }

    final int generation = ++slot.generation;
    final Future<T> future = fetch();

    // 供同 key 并发调用复用的句柄。它失败时，错误会分发给每个真实复用者（各自
    // 按「拉取失败 → 占位卡不出现」降级）；但没有第二个调用者时这条链就没有监听者，
    // Dart 会把它当成「无人处理的异步错误」抛进 Zone。额外挂一个吞错监听消掉该状态，
    // 不影响其它监听者照常收到错误。
    final Future<Object?> shared = future.then<Object?>((T value) => value);
    unawaited(shared.catchError((Object _) => null));
    slot.inFlight = shared;
    slot.inFlightStartedAtMs = _nowMs();

    return future.then<T>(
      (T value) {
        // 期间发生过 forceRefresh / invalidate → 本次结果已过时，丢弃写入但仍返回给
        // 自己的调用方（它要的就是这次取数的结果）。
        if (slot.generation == generation) {
          slot.value = value;
          slot.hasValue = true;
          slot.fetchedAtMs = _nowMs();
          slot.inFlight = null;
          // 整份清单到手即是这一域的唯一真相：此前按 id 单查的条目作废，之后
          // [readByIds] 在清单新鲜期内只从清单里取，不会出现两份口径。
          _itemSlots[_slotKey(sourceId, key)]?.clear();
        }
        return value;
      },
      onError: (Object error, StackTrace stack) {
        if (slot.generation == generation) slot.inFlight = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  /// stale-while-revalidate 版的 [read]：槽里有**过期**的值时把它作为
  /// [RemoteLibraryRead.stale] 立即交出，同时照 [read] 的规则取新值
  /// （[RemoteLibraryRead.fresh]：复用在途请求 / 发起取数）。槽里的值新鲜、或
  /// 根本没有值、或 [forceRefresh]（用户手动刷新要的就是新清单）时 `stale` 为
  /// null，调用方等 `fresh`。
  ///
  /// 给「清单大、取一次要几十秒」的来源用（媒体服务器整库枚举）：库页先用上一份
  /// 清单（含冷启动时从磁盘灌进来的，见 [seed]）把卡片画出来，新清单到手再换上。
  /// `fresh` 失败不会变成无人处理的异步错误（见 [RemoteLibraryRead]）。
  RemoteLibraryRead<T> readOrRevalidate<T extends Object>({
    required String sourceId,
    required String key,
    required Future<T> Function() fetch,
    Duration? ttl,
    bool forceRefresh = false,
  }) {
    final _CacheSlot? slot = _slots[_slotKey(sourceId, key)];
    final T? stale =
        !forceRefresh &&
            slot != null &&
            slot.hasValue &&
            !_hasFreshValue(slot, ttl)
        ? slot.value as T
        : null;
    final Future<T> fresh = read<T>(
      sourceId: sourceId,
      key: key,
      fetch: fetch,
      ttl: ttl,
      forceRefresh: forceRefresh,
    );
    return RemoteLibraryRead<T>(stale: stale, fresh: fresh);
  }

  /// 往**空**槽里放一份已知是旧的值（磁盘上持久化的上一份清单），不发任何请求。
  ///
  /// 放进来的值**一律算过期**（取得时刻记为 0）：它只是「上一次已知」的清单，
  /// 下一次 [readOrRevalidate] / [read] 照样去取新值，[peek] 不带 `maxAge` 时能
  /// 读到它（BUG-1891 关掉自动列出时仍显示上一份）。槽里已有值（哪怕过期）时
  /// 不覆盖——内存里的那份不会比磁盘上的旧。
  void seed<T extends Object>({
    required String sourceId,
    required String key,
    required T value,
  }) {
    final _CacheSlot slot = _slots.putIfAbsent(
      _slotKey(sourceId, key),
      () => _CacheSlot(),
    );
    if (slot.hasValue) return;
    slot.value = value;
    slot.hasValue = true;
    slot.fetchedAtMs = 0;
  }

  /// 只读 [sourceId] 的 [key] 域清单里 id 在 [ids] 中的**这几条**，不枚举整库。
  ///
  /// 合集详情页只需要它自己的成员；媒体服务器大库的整库枚举要几十秒，打开一个合集
  /// 不该等它、也不该和它抢（[fetch] 是来源的按 id 批量查询，如
  /// `RemoteVideoLookup.remoteVideosByIds`）。
  ///
  /// 取数顺序：
  ///  1. 整份清单槽新鲜 → 直接从清单里挑（整份清单是这一域的真相，清单里没有的
  ///     id 就是没有，不再单查）；**不等**在途的整库请求。
  ///  2. 否则按条目查单查记录：新鲜的直接用；同一 id 已有在途单查则复用它；其余
  ///     合成**一次** [fetch]。查回来的条目（含「服务器上没有」）按 id 记下，同样
  ///     受 [ttl] 与失效约束（[invalidate] / [invalidateSource] / [invalidateAll]
  ///     一并清掉；整份清单写入时清空，见 [read]）。
  ///
  /// 返回按 [ids] 的顺序、去掉服务器上不存在的 id。[fetch] 抛出时不缓存失败，异常
  /// 原样上抛（与 [read] 同一降级语义）。单查记录不改变整份清单槽的任何状态。
  Future<List<T>> readByIds<T extends Object>({
    required String sourceId,
    required String key,
    required List<String> ids,
    required String Function(T item) idOf,
    required Future<List<T>> Function(List<String> ids) fetch,
    Duration? ttl,
  }) async {
    if (ids.isEmpty) return <T>[];
    final String slotKey = _slotKey(sourceId, key);
    final _CacheSlot? listSlot = _slots[slotKey];
    if (listSlot != null && _hasFreshValue(listSlot, ttl)) {
      final Map<String, T> byId = <String, T>{
        for (final T item in listSlot.value! as List<T>) idOf(item): item,
      };
      return <T>[
        for (final String id in ids)
          if (byId[id] case final T item) item,
      ];
    }

    final _ItemSlot slot = _itemSlots.putIfAbsent(slotKey, () => _ItemSlot());
    final int now = _nowMs();
    final int ttlMs = (ttl ?? defaultTtl).inMilliseconds;
    // 本次调用自己的结果表：先装进调用时刻新鲜的记录，再并入在途 / 新发的批次。
    // 不在结束时回读 [slot]——期间被失效清掉也照样把这次查到的交给调用方（与
    // [read]「作废的结果不写回、但仍交给自己的调用方」同一口径）。
    final Map<String, T?> resolved = <String, T?>{};
    final List<Future<Map<String, Object?>>> joined =
        <Future<Map<String, Object?>>>[];
    final List<String> missing = <String>[];
    for (final String id in ids.toSet()) {
      final _ItemEntry? entry = slot.entries[id];
      if (entry != null && now - entry.fetchedAtMs < ttlMs) {
        resolved[id] = entry.value as T?;
        continue;
      }
      final _ItemBatch? batch = slot.inFlight[id];
      if (batch != null &&
          now - batch.startedAtMs < inFlightTtl.inMilliseconds) {
        if (!joined.contains(batch.future)) joined.add(batch.future);
        continue;
      }
      missing.add(id);
    }

    if (missing.isNotEmpty) {
      final int generation = slot.generation;
      final Future<Map<String, Object?>> future = fetch(missing).then((
        List<T> found,
      ) {
        final Map<String, Object?> byId = <String, Object?>{
          for (final String id in missing) id: null,
          for (final T item in found) idOf(item): item,
        };
        if (slot.generation == generation) {
          final int at = _nowMs();
          for (final String id in missing) {
            slot.entries[id] = _ItemEntry(byId[id], at);
          }
        }
        return byId;
      });
      final _ItemBatch batch = _ItemBatch(future, now);
      for (final String id in missing) {
        slot.inFlight[id] = batch;
      }
      // 只有本调用在等时，失败不能变成「无人处理的异步错误」；复用者照常收到错误。
      unawaited(future.then<void>((_) {}, onError: (Object _) {}));
      void release() {
        for (final String id in missing) {
          if (identical(slot.inFlight[id], batch)) slot.inFlight.remove(id);
        }
      }

      try {
        final Map<String, Object?> mine = await future;
        mine.forEach((String id, Object? value) => resolved[id] = value as T?);
      } finally {
        release();
      }
    }
    for (final Future<Map<String, Object?>> other in joined) {
      final Map<String, Object?> theirs = await other;
      for (final String id in ids) {
        if (theirs.containsKey(id)) resolved[id] = theirs[id] as T?;
      }
    }
    return <T>[
      for (final String id in ids)
        if (resolved[id] case final T item) item,
    ];
  }

  /// BUG-1567：只复用「还在信任期内」的在途请求；超过 [inFlightTtl] 的视为挂死，
  /// 返回 null 让 [read] 重新取数（自愈），死 future 的迟到写回被 generation 比对丢弃。
  Future<Object?>? _trustedInFlight(_CacheSlot slot) {
    final Future<Object?>? inFlight = slot.inFlight;
    if (inFlight == null) return null;
    return _nowMs() - slot.inFlightStartedAtMs < inFlightTtl.inMilliseconds
        ? inFlight
        : null;
  }

  bool _hasFreshValue(_CacheSlot slot, Duration? ttl) =>
      slot.hasValue &&
      _nowMs() - slot.fetchedAtMs < (ttl ?? defaultTtl).inMilliseconds;

  /// 同参数（不带 forceRefresh）的 [read] 此刻是否**直接交出新鲜缓存值、不等任何网络**。
  ///
  /// 与 [read] 共用同一套判据：信任期内有在途请求时 [read] 会去等它，这里就是 false
  /// ——哪怕槽里同时还有新鲜值（[peek] 只看值，口径不同，不能拿来模拟 [read]）。
  /// 调用方据此决定等待期间要不要挂进度反馈（BUG-4724）。
  bool wouldReadImmediately({
    required String sourceId,
    required String key,
    Duration? ttl,
  }) {
    final _CacheSlot? slot = _slots[_slotKey(sourceId, key)];
    if (slot == null) return false;
    if (_trustedInFlight(slot) != null) return false;
    return _hasFreshValue(slot, ttl);
  }

  /// 槽的联合定位符。竖线做分隔符：来源身份（[kInterconnectRemoteLibrarySourceId] /
  /// [cloudRemoteLibrarySourceId]）与域名（[RemoteLibraryCacheKeys]）都是本仓写死的标识符，
  /// 两侧都不含竖线，所以拼不出歧义槽名。
  static String _slotKey(String sourceId, String key) => '$sourceId|$key';

  /// 作废 [sourceId] 的 [key] 槽（含在途请求的写回）。下次 [read] 必然重新取数。
  void invalidate(String sourceId, String key) {
    _invalidateSlot(_slotKey(sourceId, key));
  }

  /// 作废 [sourceId] 的**全部**域槽（books/videos/audiobooks/activity:* …）。
  ///
  /// 「我刚对这个来源做了写操作（删远端条目等），它的远端库整体可能已变」的
  /// 正确失效粒度：逐域点名必然漏（BUG-1693 批审计实证——远端删除只强刷了
  /// 自己那个域，activity 槽在 TTL 内继续给首页时间轴喂已删条目的活动），且
  /// activity 按 limit 分槽，调用方根本枚举不全。
  void invalidateSource(String sourceId) {
    final String prefix = '$sourceId|';
    for (final String slotKey in <String>{..._slots.keys, ..._itemSlots.keys}) {
      if (slotKey.startsWith(prefix)) _invalidateSlot(slotKey);
    }
  }

  void _invalidateSlot(String slotKey) {
    // 按 id 单查的条目与整份清单同生共死：清单作废的信号（下拉刷新、换线路、
    // 已播放变更……）对单查记录同样成立。
    _itemSlots[slotKey]?.clear();
    final _CacheSlot? slot = _slots[slotKey];
    if (slot == null) return;
    slot.generation++;
    slot.inFlight = null;
    slot.hasValue = false;
    slot.value = null;
    slot.fetchedAtMs = 0;
  }

  /// 作废全部槽（所有来源、所有域）。用于对端换人 / 配对变更 / 同步跑完这类
  /// 「远端库整体可能已变」的信号。
  void invalidateAll() {
    for (final String slotKey in <String>{..._slots.keys, ..._itemSlots.keys}) {
      _invalidateSlot(slotKey);
    }
  }

  /// 只读取已缓存的值，**绝不触发取数**（BUG-1891）。
  ///
  /// 「关掉自动列出条目」的语义就是这个：进页面不发请求，但上一次手动刷新拿到的
  /// 清单还得留在屏幕上——否则切一次 tab 回来卡片就全没了，用户只能反复手动刷新，
  /// 比自动枚举还糟。
  ///
  /// [maxAge] 为 null = 不看新鲜度，返回槽里最后一次成功的值（[invalidate] /
  /// [invalidateSource] / [invalidateAll] 之后为 null）。命中在途请求不算——
  /// 本方法是纯读，不复用 future。
  T? peek<T>({
    required String sourceId,
    required String key,
    Duration? maxAge,
  }) {
    final _CacheSlot? slot = _slots[_slotKey(sourceId, key)];
    if (slot == null || !slot.hasValue) return null;
    if (maxAge != null &&
        _nowMs() - slot.fetchedAtMs >= maxAge.inMilliseconds) {
      return null;
    }
    return slot.value as T?;
  }

  /// 仅供测试与诊断：[sourceId] 的 [key] 槽当前是否持有未过期的缓存值。
  bool isFresh(String sourceId, String key, {Duration? ttl}) {
    final _CacheSlot? slot = _slots[_slotKey(sourceId, key)];
    if (slot == null || !slot.hasValue) return false;
    return _nowMs() - slot.fetchedAtMs < (ttl ?? defaultTtl).inMilliseconds;
  }
}

/// [RemoteLibraryCache.readOrRevalidate] 的结果：可以先画的旧值 + 新值。
///
/// 构造时就给 [fresh] 挂上一个吞错监听：交出 [stale] 时调用方可能根本不等
/// [fresh]，等的调用方也要隔一个异步间隙才挂上 `await`——没有这个监听，取数失败
/// 会先被当成「无人处理的异步错误」抛进 Zone。真正等它的调用方照常收到错误。
@immutable
class RemoteLibraryRead<T extends Object> {
  RemoteLibraryRead({required this.stale, required this.fresh}) {
    unawaited(fresh.then<void>((_) {}, onError: (Object _) {}));
  }

  /// 已经到手的值（不再有新值要等）。
  RemoteLibraryRead.settled(T value)
    : stale = null,
      fresh = Future<T>.value(value);

  /// 过期但可以先显示的值；null = 没有可先显示的，等 [fresh]。
  final T? stale;

  /// 新值（复用在途请求或新发起的取数）；[stale] 非空时它在后台完成。
  final Future<T> fresh;
}

class _CacheSlot {
  Object? value;
  bool hasValue = false;
  int fetchedAtMs = 0;

  /// 每次取数自增；写回时比对，拦截「旧请求后到覆盖新结果」。
  int generation = 0;
  Future<Object?>? inFlight;

  /// 当前在途请求的发起时刻（BUG-1567）：超过 [RemoteLibraryCache.inFlightTtl]
  /// 的在途请求视为挂死，不再被后续 [RemoteLibraryCache.read] 复用。
  int inFlightStartedAtMs = 0;
}

/// [RemoteLibraryCache.readByIds] 的单查记录：一个 (来源, 域) 一份。
class _ItemSlot {
  /// 已查过的 id → 条目（null = 服务器上没有）与查得时刻。
  final Map<String, _ItemEntry> entries = <String, _ItemEntry>{};

  /// 在途单查：id → 它所在的那一批（一批多个 id 共用一个 future）。
  final Map<String, _ItemBatch> inFlight = <String, _ItemBatch>{};

  /// 每次清空自增；在途批次写回时比对，拦截「失效之前发出的查询后到写回」。
  int generation = 0;

  void clear() {
    generation++;
    entries.clear();
    inFlight.clear();
  }
}

class _ItemEntry {
  const _ItemEntry(this.value, this.fetchedAtMs);

  final Object? value;
  final int fetchedAtMs;
}

class _ItemBatch {
  const _ItemBatch(this.future, this.startedAtMs);

  /// 这一批的结果：本批每个 id → 条目或 null（服务器上没有）。
  final Future<Map<String, Object?>> future;
  final int startedAtMs;
}

/// app 级单例 provider：书架 / 漫画书架 / 视频页 / 首页 dashboard 共享同一份缓存，
/// 所以「首页已经拉过书列表、切到书架」不会再问对端要一次。
///
/// 用 provider 而不是全局单例，是为了测试隔离——每个 `ProviderScope` 一份新缓存，
/// widget 测试之间不会互相看到对方的远端列表。
///
/// **换对端自动失效（BUG-1180）**：订阅
/// [InterconnectSyncBackend.sessionIdentityRevision]——它在对端身份（地址集合 /
/// 钉扎指纹 / 令牌）真变时自增。改对端的入口有四处（设置页改地址、改令牌、局域网
/// 配对的两处 token 落库），靠每处记得手动 `invalidateAll()` 必然漏（本 bug 的
/// 前一版就漏光了，唯一那处还挂在改不了对端的「源库」对话框上）。订阅唯一的身份
/// 判据 = 所有入口自动覆盖。
final remoteLibraryCacheProvider = Provider<RemoteLibraryCache>((ref) {
  final RemoteLibraryCache cache = RemoteLibraryCache();
  final ValueNotifier<int> revision =
      InterconnectSyncBackend.instance.sessionIdentityRevision;
  void onIdentityChanged() => cache.invalidateAll();
  revision.addListener(onIdentityChanged);
  ref.onDispose(() => revision.removeListener(onIdentityChanged));
  // 本端删掉了 host 上的条目（同步推送删除墓碑 / UI 直删）：互联来源的清单整体作废。
  // 同步监听——删除返回时缓存已空，之后推进的推送基线不会配上删除前的旧清单。
  final ValueNotifier<int> mutation =
      InterconnectSyncBackend.instance.remoteLibraryMutationRevision;
  void onHostLibraryMutated() =>
      cache.invalidateSource(kInterconnectRemoteLibrarySourceId);
  mutation.addListener(onHostLibraryMutated);
  ref.onDispose(() => mutation.removeListener(onHostLibraryMutated));
  // 媒体服务器请求漏斗自动换了线路（拍板台 design-media-server-failover-transport）：
  // 这台的清单槽里封面 / 流 URL 烤着旧线路的 host，整槽作废（与手动「切换线路」同口径）。
  final StreamSubscription<String> reroutes = MediaServerRouteFailover
      .reroutedSources
      .listen(cache.invalidateSource);
  ref.onDispose(reroutes.cancel);
  // 媒体服务器上的已播放 / 断点变了（标记已看 / 未看、播放页退回）：这台的清单
  // 槽（卡片角标、「已看 x/N」）作废，下次读拿到服务器的新状态。
  final StreamSubscription<String> userData = MediaServerUserDataChanges.stream
      .listen(cache.invalidateSource);
  ref.onDispose(userData.cancel);
  return cache;
});

/// 远端列表的缓存**域** key。集中在一处而不是散在各页面字符串字面量里——新增媒体域时
/// 这里加一个常量/函数，编译器就能在所有消费点保证拼写一致。
///
/// 这里只有「哪一类东西」，没有「问谁要的」——后者是 [RemoteLibraryCache.read] 的
/// `sourceId` 参数（BUG-1202）。两个维度分开，才不会出现「videos 是共用的、
/// cloud_videos 是云盘专用的」这种一半按域、一半按源的混合命名。
class RemoteLibraryCacheKeys {
  const RemoteLibraryCacheKeys._();

  static const String books = 'books';

  /// 远端视频清单（`List<RemoteVideoInfo>`）。
  ///
  /// 互联 host live 库与云盘目录用**同一个域** key，但落在**各自的槽**里（槽 =
  /// 来源身份 + 域）。TODO-2119 之前云盘返回的是 manifest entry，被迫拆出第二个
  /// `cloud_videos` 域常量；现在两种源都实现 `RemoteVideoSource`、清单都已在各自
  /// client 里统一成 `RemoteVideoInfo`，域名可以只留一个，来源隔离交给 `sourceId`。
  static const String videos = 'videos';
  static const String audiobooks = 'audiobooks';
  static const String dictionaries = 'dictionaries';

  /// 活动流按 limit 分槽——不同 limit 是不同的结果集，共用一个 slot 会让首页的
  /// limit:200 被别处的 limit:20 污染成截断列表。
  static String activity(int limit) => 'activity:$limit';
}
