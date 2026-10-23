/// build 路径用的「文件在不在」异步记忆表（BUG-3663）。
///
/// # 为什么需要
///
/// 封面 / 海报 / 附加图的回退链（合集自有封面 → 刮削海报 → 成员借用 …）要先知道
/// 哪一张文件真的在，才能决定画哪张。旧实现在 build 里逐个 `existsSync`——这些
/// 路径常落在网络盘（rclone / SMB / WinFsp 挂载）上，挂载端目录缓存过期时一次同步
/// stat 要逐级重列目录、单次 0.15–4.4 s，整条 UI isolate（连同跑在同一 isolate 上
/// 的互联 host 端点）随之冻结。
///
/// 本表让 build 只读缓存：[lookup] 命中直接回答；没见过的路径回 null（「还不知道」）
/// 并在后台用 async `File.exists()` 探测（在 IO 线程池里等，不阻塞 isolate），一批
/// 探测落定后调一次 [onChanged]（调用方在里面 setState 重建）。
///
/// 调用方对 null 的约定：回退链上**更靠前**的候选还不知道时，整条链按「还没解析好」
/// 停下，而不是先跳到后面的候选——否则封面会先闪成成员借图再跳回自有封面。返回
/// `ImageProvider?` 的回退链（`a ?? b ?? c`）用 [kPendingCoverImage] 表示「还在探测」：
/// 它非 null，`??` 链停在这里；画出来是一张永远在加载中的空图，探测落定后重建换成
/// 真图源。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 同时在途的探测上限：网络盘上几十条封面一起 stat 会把挂载端的串行 PROPFIND 排满，
/// 与互联 host 的 listVideos 预取同一口径（8 路）。
const int kAsyncFileExistenceMaxConcurrent = 8;

/// 按路径记忆「文件是否存在」的异步缓存。见库注释。
class AsyncFileExistenceCache {
  AsyncFileExistenceCache({
    required void Function() onChanged,
    int maxConcurrent = kAsyncFileExistenceMaxConcurrent,
  }) : _onChanged = onChanged,
       _maxConcurrent = maxConcurrent;

  final void Function() _onChanged;
  final int _maxConcurrent;

  final Map<String, bool> _known = <String, bool>{};
  final Set<String> _queued = <String>{};
  final Queue<String> _queue = Queue<String>();
  int _running = 0;
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// [path] 是否存在：true / false = 已知；null = 还不知道（已排进后台探测，落定后
  /// 经 onChanged 通知）。零同步 IO，可在 build 里调。
  bool? lookup(String path) {
    final bool? known = _known[path];
    if (known != null) return known;
    _enqueue(path);
    return null;
  }

  /// 三态封装：null / 空串 → false（没有候选），其余同 [lookup]。
  bool? lookupOptional(String? path) {
    if (path == null || path.isEmpty) return false;
    return lookup(path);
  }

  /// 重新探测已知「不存在」的路径（库数据刷新后调用：刮削 / 抽帧可能刚把文件写到
  /// 原先探过的路径上）。不清表——旧答案继续用到新答案回来，不会每次刷新都闪一轮
  /// 占位；有答案变了才通知。已知存在的路径不重探：文件后来没了由渲染层的
  /// errorBuilder 兜底，不必每次刷新都对整库封面再 stat 一轮。
  void revalidateMissing() {
    for (final MapEntry<String, bool> e in _known.entries.toList()) {
      if (!e.value) _enqueue(e.key);
    }
  }

  /// 丢弃全部记忆（数据源整体换了，例如远端清单重取）。
  void clear() {
    _known.clear();
  }

  /// State.dispose 时调用：之后的探测结果不再通知。
  void dispose() {
    _disposed = true;
    _queue.clear();
    _queued.clear();
  }

  void _enqueue(String path) {
    if (_disposed || !_queued.add(path)) return;
    _queue.add(path);
    _pump();
  }

  void _pump() {
    while (!_disposed && _running < _maxConcurrent && _queue.isNotEmpty) {
      final String path = _queue.removeFirst();
      _running++;
      unawaited(_probe(path));
    }
  }

  Future<void> _probe(String path) async {
    bool exists;
    try {
      exists = await File(path).exists();
    } finally {
      _running--;
      _queued.remove(path);
    }
    if (_disposed) return;
    final bool? before = _known[path];
    _known[path] = exists;
    if (before != exists) _scheduleNotify();
    _pump();
  }

  /// 同一轮事件里落定的多条探测合并成一次通知（一次重建）。
  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) _onChanged();
    });
  }
}

/// 「封面还在异步探测」的图源（见 [AsyncFileExistenceCache] 库注释）：非 null 让
/// `??` 回退链停下；交给 Image 时永远处于加载中（不报错、不画破图），探测落定后
/// 调用方重建换成真正的图源。
const PendingCoverImage kPendingCoverImage = PendingCoverImage._();

/// [kPendingCoverImage] 的类型；只有那一个实例。
@immutable
class PendingCoverImage extends ImageProvider<PendingCoverImage> {
  const PendingCoverImage._();

  @override
  Future<PendingCoverImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<PendingCoverImage>(this);

  @override
  ImageStreamCompleter loadImage(
    PendingCoverImage key,
    ImageDecoderCallback decode,
  ) => _PendingImageStreamCompleter();

  @override
  bool operator ==(Object other) => other is PendingCoverImage;

  @override
  int get hashCode => (PendingCoverImage).hashCode;

  @override
  String toString() => 'PendingCoverImage()';
}

/// 永不出帧的图流：Image 停在加载态。
class _PendingImageStreamCompleter extends ImageStreamCompleter {}
