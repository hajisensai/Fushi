// 常驻装饰动画（主页背景漂移 / 旋转这类永不停止的 repeat）不算调度器眼里的「忙」（BUG-4387）。
//
// Flutter 默认调度策略 [defaultSchedulingStrategy]：只要
// [SchedulerBinding.transientCallbackCount] > 0（任何 ticker 挂着帧回调），低于
// [Priority.animation] 的任务就不执行，`_runTasks` 用零延迟 `Timer.run` 把自己重新排上、
// 下一轮事件循环再看。常驻动画永远挂着帧回调，于是一个 [Priority.idle] 任务会让调度器
// 无限空转：每圈一条自发消息，Windows 嵌入层每条都 `PostMessage(WM_NULL)` 唤醒主线程，
// `GetMessage` 先取 posted 消息，鼠标键盘永远排不上——整机输入全失灵。
//
// 修法：常驻装饰动画用 [AmbientTickerProviderStateMixin] 建 ticker，登记进
// [AmbientTickers]；[ambientAwareSchedulingStrategy] 计「忙」时把这些 ticker 挂着的帧回调
// 减掉。「空闲」恢复原意——没有真实动画（入场 / 转场 / 交互动效）在跑。

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

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
  final int realAnimations =
      scheduler.transientCallbackCount -
      AmbientTickers.scheduledFrameCallbackCount;
  if (realAnimations > 0) return priority >= Priority.animation.value;
  return true;
}

class _AmbientTicker extends Ticker {
  _AmbientTicker(super.onTick, this._creator, {super.debugLabel}) {
    AmbientTickers._live.add(this);
  }

  final AmbientTickerProviderStateMixin<StatefulWidget> _creator;

  /// [Ticker.scheduled] 是 protected，只能在子类里读。
  bool get holdsFrameCallback => scheduled;

  @override
  void dispose() {
    AmbientTickers._live.remove(this);
    _creator._tickers?.remove(this);
    super.dispose();
  }
}

/// 与 [TickerProviderStateMixin] 行为一致（跟随 [TickerMode] 静音 / forceFrames），
/// 但建出的 ticker 被视为常驻装饰动画，不阻塞 [Priority.idle] 等低优先级任务。
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
