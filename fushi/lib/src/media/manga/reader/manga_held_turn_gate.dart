/// 漫画长按方向键连发翻页的节流闸（反馈 uz_2m0E_Eu ②）。
///
/// 维护者拍板：长按 ← / → 漫画也像小说一样连发翻页，但**每次等上一页的翻页动画
/// 走完再翻下一页**，不堆翻页风暴。所以长按产生的自动重复（OS `KeyRepeatEvent` /
/// DOM `e.repeat`）只在「没有翻页在飞、且上一次翻页动画已经落定」时放行一次，其余
/// 直接丢掉——不进 [MangaTurnQueue] 攒步数（攒下来就是松手后还继续翻的风暴）。
///
/// 单次按下不经过本闸：照旧进翻页队列（快速连点仍按次数翻，换窗加载期间的输入
/// 折成净步数，见 [MangaTurnQueue]）。
///
/// 纯状态 + 显式时间参数，便于单测；页面在每一步翻页真正开始执行时调
/// [noteTurnStarted]。
library;

class MangaHeldTurnGate {
  DateTime? _settlesAt;

  /// 一步翻页开始执行：[animation] 是这一步要播的翻页动画时长（效果为无时为零）。
  /// 多步重叠时取最晚的落定时刻。
  void noteTurnStarted({required DateTime now, required Duration animation}) {
    final DateTime settles = now.add(animation);
    final DateTime? current = _settlesAt;
    if (current == null || settles.isAfter(current)) _settlesAt = settles;
  }

  /// 长按的这一次重复是否放行：没有翻页在飞（[turnInFlight] 由页面按翻页队列 /
  /// 窗口加载 / 换章状态合成），且上一次翻页动画已在 [now] 之前落定。
  bool acceptsHeldTurn({required DateTime now, required bool turnInFlight}) {
    if (turnInFlight) return false;
    final DateTime? settles = _settlesAt;
    return settles == null || !now.isBefore(settles);
  }

  /// 换文档 / 换章：上一份文档里的动画已无意义。
  void reset() => _settlesAt = null;
}
