import 'dart:async';

import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/remote_video_list_store.dart';

/// 媒体服务器清单的内存新鲜期（[RemoteLibraryCache] 的 `ttl`）。
///
/// 默认 60s 是给「再问一次 = 一个请求」的互联 / 云盘定的。媒体服务器这边过期之后
/// 不再是整库重枚举：先用上一份清单把卡片画出来，后台只发几个 `Limit=1` 的变更戳
/// 查询（每个媒体库 5 个），确认变了才整库拉。所以 TTL 不再决定用户等多久，只决定
/// 「别处的改动（另一台设备看了一集、服务器入库了新片）最迟多久被发现」与「切 tab
/// 时多常去问服务器」之间的取舍。5 分钟：切页面 / 切 tab 的秒级往返全部命中内存；
/// 本机的改动（标记已看、播放退出、换线路、改库勾选）各有失效信号立即作废，不受
/// TTL 约束；手动刷新随时整库重拉。
const Duration kPersistedRemoteVideoListTtl = Duration(minutes: 5);

/// [source] 的远端视频清单用多长的内存新鲜期（null = 缓存默认值）。库页取整份清单
/// 与按 id 从清单里挑成员必须用同一个值，所以只在这里判一次。
Duration? remoteVideoListTtlOf(RemoteVideoSource source) =>
    source is PersistableRemoteVideoSource
    ? kPersistedRemoteVideoListTtl
    : null;

/// 媒体服务器远端视频清单在内存缓存这一侧的读法（stale-while-revalidate）。
///
///  1. 内存槽空时先从磁盘灌一份进去（[RemoteVideoListStore.load] →
///     [RemoteLibraryCache.seed]，一律算过期）；
///  2. 槽里的值过期 → 立即交出它（[RemoteLibraryRead.stale]），同时后台重验
///     （[RemoteLibraryCache.readOrRevalidate]）；
///  3. 重验 = [RemoteVideoListStore.fetchList]：服务器说没变就交回同一个清单对象，
///     变了 / 没有戳 / 手动刷新才整库枚举并落盘。
class PersistedRemoteVideoList {
  PersistedRemoteVideoList._();

  /// 同一来源的磁盘灌入只跑一份（库页与合集详情同帧来读）。
  static final Map<String, Future<void>> _hydrating = <String, Future<void>>{};

  /// 库页取整份清单（「自动列出条目」放行时）：见类注释。
  static Future<RemoteLibraryRead<List<RemoteVideoInfo>>> read({
    required RemoteLibraryCache cache,
    required PersistableRemoteVideoSource source,
    required bool forceRefresh,
  }) async {
    await hydrate(cache: cache, source: source);
    final String sourceId = source.remoteLibrarySourceId;
    return cache.readOrRevalidate<List<RemoteVideoInfo>>(
      sourceId: sourceId,
      key: RemoteLibraryCacheKeys.videos,
      ttl: kPersistedRemoteVideoListTtl,
      forceRefresh: forceRefresh,
      fetch: () => RemoteVideoListStore.fetchList(
        source: source,
        forceRefresh: forceRefresh,
        current: cache.peek<List<RemoteVideoInfo>>(
          sourceId: sourceId,
          key: RemoteLibraryCacheKeys.videos,
        ),
      ),
    );
  }

  /// 只读、不取数（BUG-1891 关掉自动列出）：内存里没有就先从磁盘灌，再
  /// [RemoteLibraryCache.peek]。上一次手动刷新拿到的清单跨重启仍在。
  static Future<List<RemoteVideoInfo>?> peek({
    required RemoteLibraryCache cache,
    required PersistableRemoteVideoSource source,
  }) async {
    await hydrate(cache: cache, source: source);
    return cache.peek<List<RemoteVideoInfo>>(
      sourceId: source.remoteLibrarySourceId,
      key: RemoteLibraryCacheKeys.videos,
    );
  }

  /// 内存槽空时把磁盘上的上一份清单灌进去（一律算过期）；槽里已有值则什么都不做。
  static Future<void> hydrate({
    required RemoteLibraryCache cache,
    required PersistableRemoteVideoSource source,
  }) {
    final String sourceId = source.remoteLibrarySourceId;
    if (cache.peek<List<RemoteVideoInfo>>(
          sourceId: sourceId,
          key: RemoteLibraryCacheKeys.videos,
        ) !=
        null) {
      return Future<void>.value();
    }
    final Future<void>? running = _hydrating[sourceId];
    if (running != null) return running;
    final Future<void> task = () async {
      final List<RemoteVideoInfo>? videos = await RemoteVideoListStore.load(
        source,
      );
      if (videos != null) {
        cache.seed<List<RemoteVideoInfo>>(
          sourceId: sourceId,
          key: RemoteLibraryCacheKeys.videos,
          value: videos,
        );
      }
    }();
    _hydrating[sourceId] = task;
    return task.whenComplete(() {
      if (identical(_hydrating[sourceId], task)) _hydrating.remove(sourceId);
    });
  }
}
