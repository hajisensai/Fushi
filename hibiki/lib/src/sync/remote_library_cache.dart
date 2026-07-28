import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/sync/interconnect_sync_backend.dart';
import 'package:hibiki/src/sync/remote_library_source.dart';

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
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? _wallClockMs;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 未显式指定 `ttl` 时的新鲜期。60s 的取舍：切页面/切 tab 是秒级操作，必须命中缓存；
  /// 而「对端刚加了一本书」的可见延迟上限一分钟，仍在用户可接受范围，且下拉刷新随时
  /// 可以强制穿透。
  final Duration defaultTtl;

  final int Function() _nowMs;
  final Map<String, _CacheSlot> _slots = <String, _CacheSlot>{};

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
    final _CacheSlot slot =
        _slots.putIfAbsent(_slotKey(sourceId, key), () => _CacheSlot());

    if (!forceRefresh) {
      final Future<Object?>? inFlight = slot.inFlight;
      if (inFlight != null) {
        return inFlight.then((Object? value) => value as T);
      }
      if (slot.hasValue &&
          _nowMs() - slot.fetchedAtMs < (ttl ?? defaultTtl).inMilliseconds) {
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

    return future.then<T>((T value) {
      // 期间发生过 forceRefresh / invalidate → 本次结果已过时，丢弃写入但仍返回给
      // 自己的调用方（它要的就是这次取数的结果）。
      if (slot.generation == generation) {
        slot.value = value;
        slot.hasValue = true;
        slot.fetchedAtMs = _nowMs();
        slot.inFlight = null;
      }
      return value;
    }, onError: (Object error, StackTrace stack) {
      if (slot.generation == generation) slot.inFlight = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  /// 槽的联合定位符。竖线做分隔符：来源身份（[kInterconnectRemoteLibrarySourceId] /
  /// [cloudRemoteLibrarySourceId]）与域名（[RemoteLibraryCacheKeys]）都是本仓写死的标识符，
  /// 两侧都不含竖线，所以拼不出歧义槽名。
  static String _slotKey(String sourceId, String key) => '$sourceId|$key';

  /// 作废 [sourceId] 的 [key] 槽（含在途请求的写回）。下次 [read] 必然重新取数。
  void invalidate(String sourceId, String key) {
    _invalidateSlot(_slotKey(sourceId, key));
  }

  void _invalidateSlot(String slotKey) {
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
    for (final String slotKey in _slots.keys.toList()) {
      _invalidateSlot(slotKey);
    }
  }

  /// 仅供测试与诊断：[sourceId] 的 [key] 槽当前是否持有未过期的缓存值。
  bool isFresh(String sourceId, String key, {Duration? ttl}) {
    final _CacheSlot? slot = _slots[_slotKey(sourceId, key)];
    if (slot == null || !slot.hasValue) return false;
    return _nowMs() - slot.fetchedAtMs < (ttl ?? defaultTtl).inMilliseconds;
  }
}

class _CacheSlot {
  Object? value;
  bool hasValue = false;
  int fetchedAtMs = 0;

  /// 每次取数自增；写回时比对，拦截「旧请求后到覆盖新结果」。
  int generation = 0;
  Future<Object?>? inFlight;
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
