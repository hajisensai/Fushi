import 'dart:async';

/// 把高频触发的异步动作合并成「最多一个在飞 + 一个待跑」的串行执行。
///
/// 拖 slider 这类每 tick 一次的通知源，如果每次都直接跑一趟昂贵动作
/// （WebView evaluateJavascript 往返 + 样式重锚 + 整页 setState），一次拖动
/// 就是上百趟叠加（BUG-969）。这里的合并语义：
/// - 空闲时触发 → 立即跑一趟；
/// - 在飞时触发（无论多少次）→ 只记一个脏标记，当前趟结束后再补跑一趟；
/// - 动作总是在跑的时刻读取最新状态，last-write-wins，最终状态绝不丢。
///
/// 不用定时器节流：合并粒度天然等于动作自身耗时，动作快就跑得密、动作慢就
/// 自动降频，没有拍脑袋的毫秒常数。
class CoalescedAsyncRunner {
  CoalescedAsyncRunner(this._action);

  final Future<void> Function() _action;

  bool _running = false;
  bool _dirty = false;

  /// 是否有一趟动作正在执行（含即将补跑的脏标记趟）。
  bool get isRunning => _running;

  /// 触发一趟动作；在飞时只置脏标记。返回的 Future 在本次触发所属的
  /// 执行链（含补跑）全部结束后完成。
  Future<void> trigger() async {
    if (_running) {
      _dirty = true;
      return;
    }
    _running = true;
    try {
      do {
        _dirty = false;
        await _action();
      } while (_dirty);
    } finally {
      _running = false;
    }
  }
}
