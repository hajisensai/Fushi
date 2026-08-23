/// 视频扫描、刮削、封面写入与破坏性维护动作的进程内排他边界。
library;

import 'dart:async';

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
  static Future<void> _tail = Future<void>.value();
  static final Object _zoneKey = Object();

  static Future<T> runExclusive<T>(Future<T> Function() action) {
    final Object? inheritedContext = Zone.current[_zoneKey];
    if (inheritedContext is _VideoCoverMutationContext &&
        inheritedContext.owner.active) {
      return inheritedContext.runChild(action);
    }
    final Completer<void> released = Completer<void>();
    final Future<void> previous = _tail;
    final _VideoCoverMutationOwner owner = _VideoCoverMutationOwner();
    final _VideoCoverMutationContext root = _VideoCoverMutationContext(owner);
    _tail = released.future;
    return previous
        .then(
          (_) => runZoned<Future<T>>(
            action,
            zoneValues: <Object, Object>{_zoneKey: root},
          ),
        )
        .whenComplete(() {
      // Timer/unawaited descendant 会继承 Zone；outer 完成后先让 owner 失效，随后这些
      // 后代再进 gate 必须排队，不能借旧 Zone 永久绕过新的持锁者。
      owner.active = false;
      if (!released.isCompleted) released.complete();
    });
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
  Future<void> _childTail = Future<void>.value();

  Future<T> runChild<T>(Future<T> Function() action) {
    final Future<void> previous = _childTail;
    final Completer<void> released = Completer<void>();
    _childTail = released.future;
    return previous
        .then((_) {
          // 未等待的 child 可能排队到 outer 已释放之后；此时重新进入全局队列，
          // 不能继续借失效 owner 绕过新的持锁者。
          if (!owner.active) {
            return VideoCoverMutationGate.runExclusive<T>(action);
          }
          final _VideoCoverMutationContext child =
              _VideoCoverMutationContext(owner);
          return runZoned<Future<T>>(
            action,
            zoneValues: <Object, Object>{
              VideoCoverMutationGate._zoneKey: child,
            },
          );
        })
        .whenComplete(() {
          if (!released.isCompleted) released.complete();
        });
  }
}
