/// 一次「就绪后进全屏」尝试的结果（见 [VideoInitialFullscreenGate]）。
enum VideoInitialFullscreenStep {
  /// 前提还没齐（controls 子树 context 尚未赋值），等下一次 [VideoInitialFullscreenGate.notify]。
  waiting,

  /// 本次已了结：压了全屏路由、栈上已有全屏路由、或失败 / 缺失态放弃。闸门就此关闭。
  settled,
}

/// 「换集保持全屏」（BUG-839）的一次性闸门：新页**就绪**后、controls 子树 context
/// 可用时进全屏路由，只进一次。
///
/// 旧做法（video-36e）是就绪后逐帧 `addPostFrameCallback` 重试、最多 30 帧：每帧空转，
/// 而 controls 首建慢于 30 帧（大文件首帧、原盘菜单换正片）时直接放弃，全屏丢了。
/// 现在改成事件驱动——只在三个时刻各尝试一次：
///
/// - [arm]：页面就绪（快路径 / 慢路径各调一次，重复调用无害）；
/// - [notify]：controls 子树 context 赋值点、失败 / 缺失态渲染时（页面喂进来）；
///
/// 同一帧里多次 [notify] 合并成一个帧后回调；[arm] 之前的 [notify] 什么都不做；
/// [settle] 之后一切调用都是 no-op。尝试体 [attempt] 由页面提供：前提不齐返回
/// [VideoInitialFullscreenStep.waiting]（不排下一帧，等下一个事件），其余返回
/// [VideoInitialFullscreenStep.settled]。
class VideoInitialFullscreenGate {
  VideoInitialFullscreenGate({
    required void Function(void Function() callback) schedulePostFrame,
    required VideoInitialFullscreenStep Function() attempt,
  }) : _schedulePostFrame = schedulePostFrame,
       _attempt = attempt;

  final void Function(void Function() callback) _schedulePostFrame;
  final VideoInitialFullscreenStep Function() _attempt;

  bool _settled = false;
  bool _armed = false;
  bool _queued = false;

  /// 闸门是否已关（进过 / 放弃了 / 本页根本不需要）。
  bool get isSettled => _settled;

  /// 直接关闸：本页不需要（非换集页、移动端）或所有权已交给别处（网页档收作窗口全屏、
  /// 再换下一集）。
  void settle() => _settled = true;

  /// 页面就绪：开始等 controls。
  void arm() {
    if (_settled) return;
    _armed = true;
    notify();
  }

  /// 前提可能变了（controls context 刚赋值 / 页面进了失败态）：已 [arm] 且未关闸时，
  /// 排一个帧后尝试（同帧合并）。
  void notify() {
    if (_settled || !_armed || _queued) return;
    _queued = true;
    _schedulePostFrame(() {
      _queued = false;
      if (_settled) return;
      if (_attempt() == VideoInitialFullscreenStep.settled) _settled = true;
    });
  }
}
