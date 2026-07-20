import 'package:flutter/material.dart';

/// 视频侧栏「当前项自动滚动」共享机器（TODO-424 章节 / TODO-638 剧集面板同款）：
/// 持有列表的 [ScrollController]，把当前项滚到视口中部偏上，并记住上次滚过的
/// 下标，避免对同一项重复触发动画。
///
/// 两个面板此前各持一份逐字相同的 `ScrollController + _lastScrolledIndex +
/// 行高估算滚动`，抽到此处消除重复（零行为变化）。面板自身保留 initState /
/// didUpdateWidget 里的 addPostFrameCallback 调度——当前下标与条数必须在回调
/// 时刻从最新 widget 读取，不能在调度时刻快照。
class VideoPanelAutoScroller {
  /// 挂到面板 [ListView.builder] 上的滚动控制器。
  final ScrollController controller = ScrollController();

  int _lastScrolledIndex = -1;

  /// 估算行高（dense ListTile：标题最多两行 / 标题 + 时间戳行）约 56。
  static const double _rowExtent = 56;

  /// 把第 [index] 项滚到视口中部偏上；下标越界、与上次滚过的项相同、或列表
  /// 尚无 viewport（未挂载）时 no-op。
  void scrollToIndex(int index, {required int itemCount}) {
    if (index < 0 || index >= itemCount) return;
    if (index == _lastScrolledIndex) return;
    if (!controller.hasClients) return;
    _lastScrolledIndex = index;
    final double viewport = controller.position.viewportDimension;
    final double target = (index * _rowExtent) - (viewport / 2) + _rowExtent;
    final double clamped =
        target.clamp(0.0, controller.position.maxScrollExtent);
    controller.animateTo(
      clamped,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void dispose() {
    controller.dispose();
  }
}
