/// 首页（仪表盘）的浮动工具栏与「继续」FAB（2026-10 统一浮动工具栏）。
///
/// 小说 / 漫画 / 视频的顶底栏统一成 M3 Expressive floating toolbar 之后，首页
/// 也换成同一套组件（`fushi_floating_toolbar.dart` 的 [FushiFloatingTopBar] /
/// [FushiToolbarFab] / [FushiChromeReveal]）：页面顶上不再是贴边的实体条，而是
/// 悬浮胶囊——起始侧标题胶囊（页面名）、末尾侧动作按钮组（更新中心 · 统计中心 ·
/// 排行榜）。MD3 = M3E 胶囊 + 阴影；Apple = iOS 26 浮动材质胶囊。
///
/// 滚动行为（M3 Expressive「floating toolbar 随滚动退场」）：内容离开顶部后继续
/// 向下滚，整条栏弹簧上滑退场；任意位置向上回滚，栏弹簧回落；顶部一屏栏高之内
/// 恒显示。退场中的栏 [ExcludeFocus] + 不吃指针：看不见的按钮不该被点到或 Tab
/// 到。墨水屏 / 系统「减弱动态效果」下瞬时切换（[FushiChromeReveal] 自带）。
///
/// FAB：「继续」主角卡滚出视野后，右下角弹出「继续阅读 / 继续观看 / 打开」FAB
/// （首屏主角卡自己就有这颗主按钮，首屏不重复）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';

/// 栏离内容区顶边的距离。
const double kHomeToolbarTopGap = 8;

/// 悬浮条高（[FushiFloatingTopBar] 的动作组走紧凑档 48）。
const double kHomeToolbarHeight = kFushiFloatingToolbarCompactExtent;

/// 内容列表顶部要让出的高度（栏 + 上留白）；列表自己的内边距另算。
const double kHomeToolbarExtent = kHomeToolbarTopGap + kHomeToolbarHeight;

/// FAB 离内容区底边 / 末尾边的距离（M3：16）。
const double kHomeFabMargin = kFushiFloatingToolbarEdgeMargin;

/// FAB 边长（M3E FAB 56 档，[FushiToolbarFab] 默认）。
const double kHomeFabSize = 56;

/// 列表底部为 FAB 预留的高度：最后一张卡滚到底时不被 FAB 压住。
const double kHomeFabClearance = kHomeFabSize + kHomeFabMargin;

/// 同一方向累计滚过这么多才切换显隐，避免手指微抖导致栏来回闪。
const double _kRevealHysteresis = 24;

/// 首页浮动栏 / FAB 的滚动驱动状态。
///
/// 只认仪表盘主列表（`depth == 0` 的纵向滚动）——卡片里的横滑行、热力图横滚
/// 是横向或更深的通知，不参与。[handle] 恒返回 false，通知照常冒泡给外壳（Apple
/// 底栏最小化 / 大标题收起都还要读它）。
class HomeToolbarScrollState extends ChangeNotifier {
  HomeToolbarScrollState({this.fabRevealOffset = 280});

  /// 滚过这个偏移（≈「继续」主角卡底边）后 FAB 才出现。
  final double fabRevealOffset;

  bool _visible = true;
  bool _pastHero = false;
  double _accumulated = 0;

  /// 栏是否显示。
  bool get visible => _visible;

  /// 主角卡是否已滚出视野（FAB 出现的条件之一）。
  bool get pastHero => _pastHero;

  bool handle(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification) return false;
    final double pixels = notification.metrics.pixels;
    final double delta = notification.scrollDelta ?? 0;
    bool visible = _visible;
    if (pixels <= kHomeToolbarExtent) {
      // 顶部一屏栏高之内恒显示：此时栏下压的是列表自己让出的空白。
      visible = true;
      _accumulated = 0;
    } else if (delta != 0) {
      // 换向就重新累计。
      if (delta.sign != _accumulated.sign) _accumulated = 0;
      _accumulated += delta;
      if (_accumulated > _kRevealHysteresis) {
        visible = false;
        _accumulated = 0;
      } else if (_accumulated < -_kRevealHysteresis) {
        visible = true;
        _accumulated = 0;
      }
    }
    _set(visible: visible, pastHero: pixels > fabRevealOffset);
    return false;
  }

  void _set({required bool visible, required bool pastHero}) {
    if (visible == _visible && pastHero == _pastHero) return;
    _visible = visible;
    _pastHero = pastHero;
    notifyListeners();
  }
}

/// 更新中心未读总数（工具栏按钮的状态），订阅 [UpdateFeedService.watchChanged]。
///
/// 与 `UpdatesDashboardBanner` 同一信号流（不是裸 drift watch，见 BUG-834）。
class HomeUpdateCount extends ValueNotifier<int> {
  HomeUpdateCount(this._service) : super(0) {
    _changes = _service.watchChanged().listen((_) => unawaited(reload()));
    unawaited(reload());
  }

  final UpdateFeedService _service;
  StreamSubscription<void>? _changes;
  bool _disposed = false;

  Future<void> reload() async {
    final Map<UpdateFeedKind, int> counts = await _service.unseenCounts();
    if (_disposed) return;
    value = counts.values.fold<int>(0, (int a, int b) => a + b);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes?.cancel());
    super.dispose();
  }
}

/// 首页浮动工具栏：[FushiFloatingTopBar]（标题胶囊 + 动作按钮组胶囊），外包
/// [FushiChromeReveal] 做弹簧显隐。
class HomeFloatingToolbar extends StatelessWidget {
  const HomeFloatingToolbar({
    super.key,
    required this.title,
    required this.actions,
    required this.visible,
  });

  final String title;
  final List<FushiToolbarItem> actions;

  /// 栏是否在场（false = 弹簧上滑退场）。
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      excluding: !visible,
      child: FushiChromeReveal(
        visible: visible,
        // 整栏连同投影一起滑出顶边。
        distance: kHomeToolbarExtent + 16,
        child: Padding(
          padding: const EdgeInsets.only(top: kHomeToolbarTopGap),
          child: SizedBox(
            height: kHomeToolbarHeight,
            child: FocusTraversalGroup(
              child: FushiFloatingTopBar(
                title: title,
                actions: <List<FushiToolbarItem>>[actions],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「继续」FAB：主角卡滚出视野后弹出（[FushiChromeReveal] 自下而上 + 淡入）。
/// 本体是 [FushiToolbarFab]（MD3 = primaryContainer 圆角方 56；Apple = 强调色
/// 圆钮），tooltip / 语义标签是动作文案。
class HomeResumeFab extends StatelessWidget {
  const HomeResumeFab({
    super.key,
    required this.visible,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool visible;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      excluding: !visible,
      child: FushiChromeReveal(
        visible: visible,
        from: AxisDirection.down,
        distance: kHomeFabClearance,
        child: FushiToolbarFab(
          icon: icon,
          tooltip: label,
          onPressed: onPressed,
        ),
      ),
    );
  }
}
