// 常驻装饰动画（主页背景漂移 / 旋转、吉祥物光晕这类永不停止的 repeat）的两件事：不算调度器
// 眼里的「忙」（BUG-4387），也不按屏幕刷新率逐帧重画（BUG-4961）。
//
// 1. 「空闲」的定义：Flutter 默认调度策略 [defaultSchedulingStrategy] 只要
//    [SchedulerBinding.transientCallbackCount] > 0（任何 ticker 挂着帧回调）就不放行低于
//    [Priority.animation] 的任务。常驻动画永远挂着帧回调，于是 [Priority.idle] 任务永远
//    等不到。常驻装饰动画用 [AmbientTickerProviderStateMixin] 建 ticker，登记进
//    [AmbientTickers]；计「忙」时把这些 ticker 挂着的帧回调减掉（[hasRealAnimations]），
//    「空闲」恢复原意——没有真实动画（入场 / 转场 / 交互动效）在跑。
// 2. 「怎么等」只有一套：生产 binding 混入的 [FramePacedTaskScheduler]——被推迟的任务按帧
//    节拍重查，不零延迟空转（BUG-4725）。本仓自己的等空闲（[waitForUiIdle]）也只是往这套
//    调度器里排一个 idle 任务；所有入口（主引擎与悬浮查词 / 弹窗 / 副屏引擎）都用带它的
//    binding（守卫 `test/build/ui_idle_wait_guard_test.dart`）。
// 3. 帧率：ambient ticker 两次 tick 之间至少隔 [FushiMotion.ambientFrameInterval]（约
//    30 fps）。常驻装饰动画慢到几十秒一个来回，按 144 Hz 逐帧重画只是让整个窗口每帧重新
//    合成（4K 144 Hz 下 raster 线程约 47%、GPU 约 20%）；动画值仍按真实经过时间算，只是
//    采样变稀，看起来一样。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 进程内所有存活的常驻装饰 ticker。
abstract final class AmbientTickers {
  static final Set<_AmbientTicker> _live = <_AmbientTicker>{};

  /// 当前挂着帧回调（计入 [SchedulerBinding.transientCallbackCount]）的装饰 ticker 数。
  static int get scheduledFrameCallbackCount {
    int n = 0;
    for (final _AmbientTicker t in _live) {
      if (t.holdsFrameCallback) n++;
    }
    return n;
  }

  @visibleForTesting
  static int get liveCount => _live.length;
}

/// 装进 [SchedulerBinding.schedulingStrategy] 的策略：与 [defaultSchedulingStrategy]
/// 相同，只是常驻装饰 ticker 的帧回调不算「有动画在跑」。
bool ambientAwareSchedulingStrategy({
  required int priority,
  required SchedulerBinding scheduler,
}) {
  if (hasRealAnimations(scheduler)) {
    return priority >= Priority.animation.value;
  }
  return true;
}

/// 有没有真实动画（常驻装饰 ticker 不算）挂着帧回调。
bool hasRealAnimations(SchedulerBinding scheduler) =>
    scheduler.transientCallbackCount -
        AmbientTickers.scheduledFrameCallbackCount >
    0;

/// 等到 UI 空闲（[hasRealAnimations] 为 false）再完成，供「首屏入场动效跑完再做」的
/// 启动期后台工作用。
///
/// 就是一个 [Priority.idle] 的空任务：什么时候算空闲由 [ambientAwareSchedulingStrategy]
/// 判，忙时怎么等由生产 binding 的 [FramePacedTaskScheduler] 管（每帧最多重查一次，等待
/// 期间事件循环是空的，输入照常处理）。不另写一套等待逻辑。
Future<void> waitForUiIdle() =>
    SchedulerBinding.instance.scheduleTask<void>(() {}, Priority.idle);

class _AmbientTicker extends Ticker {
  _AmbientTicker(super.onTick, this._creator, {super.debugLabel}) {
    AmbientTickers._live.add(this);
  }

  final AmbientTickerProviderStateMixin<StatefulWidget> _creator;

  /// 两次 tick 之间的节流定时器（见 [scheduleTick]）。
  Timer? _throttle;

  /// 真的挂着帧回调（计入 [SchedulerBinding.transientCallbackCount]）。节流等待期间
  /// 不算——那段时间没有帧回调，也不要帧。
  bool get holdsFrameCallback => super.scheduled;

  /// 节流等待也算「已排上」，免得 [Ticker] 在等待期间再排一次。
  @override
  bool get scheduled => super.scheduled || _throttle != null;

  /// 启动 / 取消静音（`rescheduling == false`）立刻排下一帧，动画即时起步；每一帧 tick
  /// 完续排时（`rescheduling == true`）先等 [FushiMotion.ambientFrameInterval] 再要帧。
  /// 等待期间不挂帧回调、不要帧：窗口里没有别的变化时引擎就不出帧。
  @override
  void scheduleTick({bool rescheduling = false}) {
    if (!rescheduling) {
      super.scheduleTick();
      return;
    }
    _throttle = Timer(FushiMotion.ambientFrameInterval, () {
      _throttle = null;
      // 续排发生在定时器里，不在帧回调里：按非续排要帧。
      if (shouldScheduleTick) super.scheduleTick();
    });
  }

  @override
  void unscheduleTick() {
    _throttle?.cancel();
    _throttle = null;
    super.unscheduleTick();
  }

  @override
  void dispose() {
    AmbientTickers._live.remove(this);
    _creator._tickers?.remove(this);
    super.dispose();
  }
}

/// 与 [TickerProviderStateMixin] 行为一致（跟随 [TickerMode] 静音 / forceFrames），
/// 但建出的 ticker 被视为常驻装饰动画，不阻塞 [Priority.idle] 等低优先级任务。
/// 两次 tick 之间至少隔 [FushiMotion.ambientFrameInterval]（约 30 fps，BUG-4961）。
///
/// 只给「永远循环、纯装饰、停了也不影响功能」的动画用；有终点的入场 / 交互动效
/// 必须用普通 [TickerProviderStateMixin]，否则 idle 任务会插进它们的帧间。
mixin AmbientTickerProviderStateMixin<T extends StatefulWidget> on State<T>
    implements TickerProvider {
  Set<_AmbientTicker>? _tickers;
  ValueListenable<TickerModeData>? _tickerModeNotifier;

  @override
  Ticker createTicker(TickerCallback onTick) {
    if (_tickerModeNotifier == null) _updateTickerModeNotifier();
    final TickerModeData values = _tickerModeNotifier!.value;
    final _AmbientTicker result =
        _AmbientTicker(
            onTick,
            this,
            debugLabel: kDebugMode
                ? 'ambient, created by ${describeIdentity(this)}'
                : null,
          )
          ..muted = !values.enabled
          ..forceFrames = values.forceFrames;
    (_tickers ??= <_AmbientTicker>{}).add(result);
    return result;
  }

  @override
  void activate() {
    super.activate();
    _updateTickerModeNotifier();
    _updateTickers();
  }

  void _updateTickers() {
    final Set<_AmbientTicker>? tickers = _tickers;
    if (tickers == null) return;
    final TickerModeData values = _tickerModeNotifier!.value;
    for (final Ticker ticker in tickers) {
      ticker.muted = !values.enabled;
      ticker.forceFrames = values.forceFrames;
    }
  }

  void _updateTickerModeNotifier() {
    final ValueListenable<TickerModeData> newNotifier =
        TickerMode.getValuesNotifier(context);
    if (newNotifier == _tickerModeNotifier) return;
    _tickerModeNotifier?.removeListener(_updateTickers);
    newNotifier.addListener(_updateTickers);
    _tickerModeNotifier = newNotifier;
  }

  @override
  void dispose() {
    assert(() {
      for (final Ticker ticker in _tickers ?? const <Ticker>{}) {
        if (ticker.isActive) {
          throw FlutterError.fromParts(<DiagnosticsNode>[
            ErrorSummary('$this was disposed with an active Ticker.'),
            ErrorHint(
              'Dispose the AnimationController before calling super.dispose().',
            ),
            ticker.describeForError('The offending ticker was'),
          ]);
        }
      }
      return true;
    }());
    _tickerModeNotifier?.removeListener(_updateTickers);
    _tickerModeNotifier = null;
    super.dispose();
  }
}
