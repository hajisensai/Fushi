import 'dart:async';

import 'package:flutter/foundation.dart';

/// 退出前需要执行的「落库 flush」回调。返回的 Future 完成即视为该来源的 pending
/// 写已提交（或已尽力提交）。
typedef ExitFlushCallback = Future<void> Function();

/// 进程退出前的 flush 注册表（TODO-086 / BUG-191）。
///
/// 背景：桌面端点 X 走 `setPreventClose(true)` → `onWindowClose`，过去在那里
/// `await windowManager.destroy()` 同步逐插件拆引擎（WebView2 / WGC / libmpv），
/// 几秒~十几秒卡死 UI 线程。改成 `exit(0)` 快杀可瞬间结束，但进程一死，活跃页面
/// 里**尚未落库的阅读位置 / 阅读统计 / 视频观看时长**（debounce 计时器 + 周期累积，
/// 经后台 isolate 异步写 Drift）就会丢。
///
/// 关键事实：在 `setPreventClose(true)` 拦截下，点 X **不会**触发页面 widget 的
/// `dispose()`，也不保证派发 `paused`/`inactive` 生命周期——所以页面自己的 flush
/// 钩子在退出时根本不可靠。本注册表让活跃页面把「退出 flush」显式登记到一处，由
/// 退出路径统一 `await`，再 close database（WAL checkpoint），最后才 `exit(0)`。
///
/// 退出 flush 回调**不得依赖 WebView/原生播放器查询当前状态**（那些资源退出期正在
/// 拆除，eval 会挂）。回调只能用页面已缓存的最近位置/统计字段直接落库——慢于最后
/// 一次 debounce（≤500ms）的滚动至多丢这一窗，远好于过去整段统计随退出丢失。
class ExitFlushRegistry {
  ExitFlushRegistry._();

  /// 进程级单例：页面随处可注册，退出路径在 main.dart 统一消费。
  static final ExitFlushRegistry instance = ExitFlushRegistry._();

  /// 用对象身份（identity）保存，避免同一回调闭包被多次登记。
  final Set<ExitFlushCallback> _callbacks = <ExitFlushCallback>{};

  /// 单个来源 flush 的硬上限：任何来源卡住都不得拖住整个退出。
  static const Duration perCallbackTimeout = Duration(seconds: 2);

  @visibleForTesting
  int get callbackCount => _callbacks.length;

  /// 登记一个退出 flush 回调（幂等）。页面 `initState` 调用，`dispose` 时
  /// [unregister]。返回传入的回调本身，便于持有以注销。
  ExitFlushCallback register(ExitFlushCallback callback) {
    _callbacks.add(callback);
    return callback;
  }

  /// 注销一个退出 flush 回调（幂等）。
  void unregister(ExitFlushCallback callback) {
    _callbacks.remove(callback);
  }

  /// 一次性延迟写：页面 `dispose()` 结算出来的最后一笔（阅读位置 / 学习段）**没有
  /// 任何人能 await**——dispose 是同步的，在那里直接发起就是一笔无人持有 future 的
  /// 事务，与随后的 `db.close()` 互等（widget 测试的 FakeAsync 下必挂，生产退出是
  /// 同一形状的竞态）。改为登记到这里，与其余 flush 一起被退出路径 await 一次，
  /// 跑完即丢。
  ///
  /// 与 [register] 的差别只有生命周期：[register] 的回调属于**活着的**页面、可反复
  /// 跑、由页面注销；这里的属于**已经销毁的**页面、只跑一次、跑完自动清。
  void defer(ExitFlushCallback write) {
    _deferred.add(write);
  }

  /// 见 [defer]。用 List 而非 Set：同一页面可能先后交多笔（位置 + 学习段），顺序即
  /// 提交顺序，且它们是不同闭包，没有去重需求。
  final List<ExitFlushCallback> _deferred = <ExitFlushCallback>[];

  @visibleForTesting
  int get deferredCount => _deferred.length;

  @visibleForTesting
  void clear() {
    _callbacks.clear();
    _deferred.clear();
  }

  /// 退出路径调用：并发跑完所有登记的 flush 回调，每个有 [perCallbackTimeout]
  /// 上限（卡住的来源被放行，不阻塞退出）。任一回调抛异常也不影响其余——退出清理
  /// 失败不该阻止退出，但也不静默吞掉（debugPrint 记一笔）。
  ///
  /// 先快照再清空：回调内部触发的 [unregister]（如页面销毁）不会破坏迭代。
  ///
  /// Android 退后台不是进程退出：此时也要把活跃 reader/video 的进度写穿，但页面
  /// 可能随后恢复并继续持有同一回调。因此 [clearCallbacks] 可设为 false，用同一组
  /// 回调做“保留式 flush”，真正退出时再清空。
  /// [defer] 的一次性写无论 [clearCallbacks] 与否都跑完即清：它们属于已销毁的页面，
  /// 不存在「页面随后恢复继续持有」这回事（Android 退后台再回前台也不该重跑）。
  Future<void> flushAll({bool clearCallbacks = true}) async {
    final List<ExitFlushCallback> snapshot = _callbacks.toList(growable: false);
    if (clearCallbacks) {
      _callbacks.clear();
    }
    final List<ExitFlushCallback> deferred = _deferred.toList(growable: false);
    _deferred.clear();
    await Future.wait(<Future<void>>[
      for (final ExitFlushCallback callback in snapshot) _runGuarded(callback),
      for (final ExitFlushCallback write in deferred) _runGuarded(write),
    ]);
  }

  Future<void> _runGuarded(ExitFlushCallback callback) async {
    try {
      await callback().timeout(perCallbackTimeout);
    } on TimeoutException {
      debugPrint('[Fushi] exit flush callback timed out; continuing');
    } catch (e) {
      debugPrint('[Fushi] exit flush callback failed: $e');
    }
  }
}
