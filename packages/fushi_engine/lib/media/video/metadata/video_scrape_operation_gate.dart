/// 视频扫描、刮削、封面写入与破坏性维护动作的进程内排他边界。
library;

import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

/// 普通动作可以并行；maintenance 只在没有普通动作时进入，并阻止新动作启动。
///
/// 所有入口必须在第一次 `await` 前同步取 lease。SQLite cleanup marker 继续负责
/// 进程外写入串行化；本门负责覆盖尚未创建 run 行的扫描、封面写入等阶段。
abstract final class VideoScrapeOperationGate {
  static int _activeOperations = 0;
  static bool _maintenanceActive = false;

  static VideoScrapeOperationLease? tryEnterOperation() {
    if (_maintenanceActive) return null;
    _activeOperations++;
    return VideoScrapeOperationLease._(maintenance: false);
  }

  static VideoScrapeOperationLease? tryEnterMaintenance() {
    if (_maintenanceActive || _activeOperations != 0) return null;
    _maintenanceActive = true;
    return VideoScrapeOperationLease._(maintenance: true);
  }

  static void _release(bool maintenance) {
    if (maintenance) {
      _maintenanceActive = false;
      return;
    }
    assert(_activeOperations > 0);
    if (_activeOperations > 0) _activeOperations--;
  }
}

class VideoScrapeOperationLease {
  VideoScrapeOperationLease._({required bool maintenance})
    : _maintenance = maintenance;

  final bool _maintenance;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    VideoScrapeOperationGate._release(_maintenance);
  }
}

/// 普通 operation 之间仍可并行，但同名封面的“来源准入 → 文件替换 → DB 指针 →
/// provenance 提交”必须串行。使用全局队列而非短促文件锁，避免手选封面恰好落在
/// 自动抽帧的准入与 rename 之间而被覆盖，也避免 GC 在 rename 与指针提交间收走新图。
abstract final class VideoCoverMutationGate {
  /// 是否有人持锁。等待队列里每个等待者持有**自己创建的** Completer。
  ///
  /// 为什么不是「把 future 串成链」（本类原来的写法）：future 的监听器由**创建它
  /// 的 Zone** 调度。串成链就等于让后来者去前一位的 Zone 里排微任务，而那个 Zone
  /// 随时可能不再被抽干——`tester.runAsync` 从 fake-async 切到真实 async zone、
  /// widget 测试换用例、`runZonedGuarded` 区域退出，都会让链条**永久停住**，且
  /// 此后全进程的封面写入一起死掉。实测：远端下载三条用例在链式实现下整文件挂死，
  /// 换成本实现后 1 秒跑完。
  ///
  /// 现在的等待是 Zone 无关的：等待者在**自己的** Zone 建 Completer，上一位释放时
  /// 直接 `complete()` 把锁**移交**给它（不经过「先置空闲再抢」的窗口，因此不会被
  /// 插队），回调自然排在等待者自己活着的 Zone 里。
  static bool _busy = false;
  static final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  static final Object _zoneKey = Object();

  /// 把锁与等待队列清回「空闲」。**仅供测试**。
  ///
  /// 锁是进程级静态量，而 `flutter test` 里每条用例各有自己的 Zone：上一条用例
  /// 结束时若还有 action 在飞，它的 Zone 不再推进，`finally` 永远不跑，`_busy`
  /// 就永久停在 true。后续用例于是排进一条**永远不会被移交**的队列——不挂死
  /// （没有帧被调度，`pumpAndSettle` 照常返回），只是那次封面写入/删除静默不执行，
  /// 表现为「断言说没删掉」这种看不出因果的失败。
  ///
  /// 真实进程只有一个长期存活的 Zone，持锁者总会跑完并释放，所以这不是产品缺陷。
  /// 但凡在 widget 测试里碰封面写入或视频删除的用例，都在 `setUp` 里调本方法。
  @visibleForTesting
  static void debugResetForTesting() {
    _busy = false;
    _waiters.clear();
  }

  static Future<T> runExclusive<T>(Future<T> Function() action) async {
    final Object? inheritedContext = Zone.current[_zoneKey];
    if (inheritedContext is _VideoCoverMutationContext &&
        inheritedContext.owner.active) {
      return inheritedContext.runChild(action);
    }
    // 判 + 占必须在第一次 await 之前同步完成，否则两个同步进入者会同时看到空闲。
    if (_busy) {
      final Completer<void> waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future; // 醒来即持锁：由上一位直接移交，无需再置 _busy。
    } else {
      _busy = true;
    }
    final _VideoCoverMutationOwner owner = _VideoCoverMutationOwner();
    final _VideoCoverMutationContext root = _VideoCoverMutationContext(owner);
    try {
      return await runZoned<Future<T>>(
        action,
        zoneValues: <Object, Object>{_zoneKey: root},
      );
    } finally {
      // Timer/unawaited descendant 会继承 Zone；outer 完成后先让 owner 失效，随后这些
      // 后代再进 gate 必须排队，不能借旧 Zone 永久绕过新的持锁者。
      owner.active = false;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _busy = false;
      }
    }
  }
}

class _VideoCoverMutationOwner {
  bool active = true;
}

/// 同一持锁 action 内允许 await 式重入，但同一层级并发启动的 sibling 必须串行。
/// 每个 child 使用自己的 context，因此更深层重入不会排在父 child 后造成死锁。
class _VideoCoverMutationContext {
  _VideoCoverMutationContext(this.owner);

  final _VideoCoverMutationOwner owner;

  /// 同一层级的 sibling 串行队列。与外层同理**不串 future 链**：child 也可能落在
  /// `tester.runAsync` 之类的另一个 Zone 里，链式排队会永久停住。
  bool _childBusy = false;
  final Queue<Completer<void>> _childWaiters = Queue<Completer<void>>();

  Future<T> runChild<T>(Future<T> Function() action) async {
    if (_childBusy) {
      final Completer<void> waiter = Completer<void>();
      _childWaiters.add(waiter);
      await waiter.future;
    } else {
      _childBusy = true;
    }
    try {
      // 未等待的 child 可能排队到 outer 已释放之后；此时重新进入全局队列，
      // 不能继续借失效 owner 绕过新的持锁者。
      if (!owner.active) {
        return await VideoCoverMutationGate.runExclusive<T>(action);
      }
      final _VideoCoverMutationContext child =
          _VideoCoverMutationContext(owner);
      return await runZoned<Future<T>>(
        action,
        zoneValues: <Object, Object>{
          VideoCoverMutationGate._zoneKey: child,
        },
      );
    } finally {
      if (_childWaiters.isNotEmpty) {
        _childWaiters.removeFirst().complete();
      } else {
        _childBusy = false;
      }
    }
  }
}
