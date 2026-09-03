import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart' show platformPathKey;

/// 释放原生媒体文件句柄的回调（TODO-1212）。返回的 Future 完成即视为该来源的底层
/// 播放器（media_kit / libmpv 等）已放掉它持有的媒体文件句柄。
typedef MediaHandleReleaseCallback = Future<void> Function();

/// 活跃原生媒体播放器的文件句柄释放注册表（TODO-1212 / 收尾 TODO-935）。
///
/// 背景：桌面「数据存储位置」迁移要 rename/搬移整个数据根子树。若此时仍有播放器
/// （media_kit / libmpv）持有数据根内的媒体文件句柄（视频字幕/封面、离屏缩略图
/// 取帧 Player），Windows 上同盘 rename 会撞「文件被占用」硬失败。
///
/// 有声书会话是进程级、由 [AudiobookSession.stop] 直接 `await disposeAndRelease()`
/// 释放，不走本注册表。视频侧的 [VideoPlayerController] / 离屏缩略图取帧 Player 是
/// 页面级、没有进程级持有者，迁移路径够不到（TODO-935 明写的残余）——本注册表补上
/// 这条触达：leaf 播放器 owner 在建 Player 时 [register]、dispose 时 [unregister]，
/// 迁移前的资源关闭遍历 [releaseAll] 逐个 `await`，确保底层文件句柄真释放后再搬文件。
class MediaHandleRegistry {
  MediaHandleRegistry._();

  /// 进程级单例：leaf 播放器 owner 随处注册，迁移路径统一消费。
  static final MediaHandleRegistry instance = MediaHandleRegistry._();

  /// 用对象身份保存，避免同一回调被重复登记。值是「这个 owner 此刻握着哪个媒体
  /// 文件」的取值器（可为 null = 身份未知，只能被 [releaseAll] 触达）。**每次现算**
  /// 而不是登记时快照：同一个播放器换集后握的是另一个文件。
  final Map<MediaHandleReleaseCallback, String? Function()?> _callbacks =
      <MediaHandleReleaseCallback, String? Function()?>{};

  /// 单个来源释放的硬上限：任何来源卡住都不得无限拖住迁移前的资源关闭。
  static const Duration perCallbackTimeout = Duration(seconds: 5);

  @visibleForTesting
  int get callbackCount => _callbacks.length;

  /// 登记一个句柄释放回调（幂等）。返回传入的回调本身，便于持有以注销。
  ///
  /// [mediaPath] 是「这个 owner 此刻握着哪个媒体文件」的取值器。给了它，
  /// [releaseHolding] 才能只放掉握着某个文件的那个 owner，而不必像 [releaseAll]
  /// 那样把进程里所有播放器一起停掉——删一条视频不该顺手中断别人的播放。
  MediaHandleReleaseCallback register(
    MediaHandleReleaseCallback callback, {
    String? Function()? mediaPath,
  }) {
    _callbacks[callback] = mediaPath;
    return callback;
  }

  /// 注销一个句柄释放回调（幂等）。
  void unregister(MediaHandleReleaseCallback callback) {
    _callbacks.remove(callback);
  }

  @visibleForTesting
  void clear() {
    _callbacks.clear();
  }

  /// 迁移前调用：并发 `await` 所有已登记的释放回调，把底层媒体文件句柄放掉。每个有
  /// [perCallbackTimeout] 上限（卡住的来源被放行，不无限阻塞迁移）；任一回调抛异常
  /// 也不影响其余（best-effort，debugPrint 记一笔）——释放失败不该阻止迁移继续
  /// （迁移引擎自身还有锁重试 + 跨盘降级兜底）。
  ///
  /// 先快照再清空：回调内部触发的 [unregister]（如 owner dispose）不破坏迭代。
  Future<void> releaseAll() async {
    final List<MediaHandleReleaseCallback> snapshot = _callbacks.keys.toList(
      growable: false,
    );
    _callbacks.clear();
    await Future.wait<void>(<Future<void>>[
      for (final MediaHandleReleaseCallback callback in snapshot)
        _runGuarded(callback),
    ]);
  }

  /// 删除本机原始视频文件**之前**调用：只放掉此刻正握着 [paths] 里某个文件的
  /// owner，其它播放器不受影响。
  ///
  /// 这是「先停止引用，再销毁实体」的落地：Windows 上 libmpv 还开着这个文件时
  /// `File.delete()` 直接 errno 32，用户会看到「删除成功」而盘上一个文件没少。
  /// 没登记 `mediaPath` 的 owner（身份未知）不会被这里触达——宁可漏放一个句柄
  /// 让删除报失败，也不要把不相干的播放器一起停掉。
  Future<void> releaseHolding(Iterable<String> paths) async {
    final Set<String> keys = <String>{
      for (final String path in paths)
        if (path.trim().isNotEmpty) platformPathKey(path),
    };
    if (keys.isEmpty) return;
    final List<MediaHandleReleaseCallback> matched =
        <MediaHandleReleaseCallback>[
      for (final MapEntry<MediaHandleReleaseCallback, String? Function()?> e
          in _callbacks.entries.toList(growable: false))
        if (_holdsAny(e.value, keys)) e.key,
    ];
    for (final MediaHandleReleaseCallback callback in matched) {
      _callbacks.remove(callback);
    }
    await Future.wait<void>(<Future<void>>[
      for (final MediaHandleReleaseCallback callback in matched)
        _runGuarded(callback),
    ]);
  }

  static bool _holdsAny(String? Function()? mediaPath, Set<String> keys) {
    if (mediaPath == null) return false;
    final String? path;
    try {
      path = mediaPath();
    } catch (_) {
      // owner 已经在拆自己了：拿不到身份就不匹配，交给它自己的 dispose。
      return false;
    }
    if (path == null || path.trim().isEmpty) return false;
    return keys.contains(platformPathKey(path));
  }

  Future<void> _runGuarded(MediaHandleReleaseCallback callback) async {
    try {
      await callback().timeout(perCallbackTimeout);
    } on TimeoutException {
      debugPrint('[Fushi] media handle release timed out; continuing');
    } catch (e) {
      debugPrint('[Fushi] media handle release failed: $e');
    }
  }
}
