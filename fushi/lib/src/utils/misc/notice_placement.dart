/// 短时通知（制卡结果卡、底部 toast、视频 OSD）避让页面 chrome 的**唯一**口径。
///
/// 起因（用户 2026-11-22）：两处位置都是写死的数——
/// * 视频 OSD 的 top 恒为「顶栏高 + 8」，顶栏收起后照样空出那段；
/// * 底部 toast 的底距恒为桌面 50 / 移动端安全区 + 96，不知道页面底部 chrome 有多高：
///   漫画有声模式的播放条（连同页码滑条）、阅读器底栏都比它高，卡片压在栏上。
///
/// 改成「页面登记它此刻占着的边」：chrome 显隐组件（`FushiChromeReveal` /
/// `MangaChromeReveal`）把自己包进 [FushiNoticeObstacle]，按显隐进度（0..1）登记
/// 自己的全局矩形；通知每次重建都按**当前**登记重新算位置（[noticeBottomOffset] /
/// [noticeTopOffset]），栏的进退场动画在走，卡片就跟着走。视频页的顶栏是 media_kit
/// 内部控件包不进来，它用同一个纯函数、自己给出合成的顶栏矩形与显隐进度。
///
/// 住在 `utils/misc/` 且不依赖 toast：视频页禁止 import toast（BUG-931 守卫）。
library;

import 'dart:async' show scheduleMicrotask;
import 'dart:ui' show FlutterView;
import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:material_ui/material_ui.dart';

/// chrome 贴着的屏幕边。
enum NoticeObstacleEdge { top, bottom }

/// 一块登记中的 chrome：全局矩形 + 显隐进度（0 = 完全收起，1 = 完全显示）。
typedef NoticeObstacle = ({
  NoticeObstacleEdge edge,
  Rect rect,
  double presence,
});

/// 通知与 chrome / 屏幕边的间距。
const double kNoticeChromeGap = 12;

/// 底部锚定的通知离 overlay 底边多远：默认 [fallback]；有底部 chrome 横在通知
/// 那条竖向通道（[laneLeft]..[laneRight]，overlay 本地坐标）上时，抬到 chrome
/// 上沿再往上 [gap]。chrome 正在进退场时按 [NoticeObstacle.presence] 在两者间插值，
/// 卡片随栏平滑移动而不是等栏收完才跳。
///
/// [obstacles] 的矩形须已换到 overlay 本地坐标（[FushiNoticeObstacles.inOverlay]）。
double noticeBottomOffset({
  required double overlayHeight,
  required double fallback,
  required Iterable<NoticeObstacle> obstacles,
  required double laneLeft,
  required double laneRight,
  double gap = kNoticeChromeGap,
}) {
  double offset = fallback;
  for (final NoticeObstacle o in obstacles) {
    if (o.edge != NoticeObstacleEdge.bottom) continue;
    if (!_crossesLane(o.rect, laneLeft, laneRight)) continue;
    final double presence = o.presence.clamp(0.0, 1.0);
    if (presence <= 0) continue;
    final double clear = overlayHeight - o.rect.top + gap;
    final double needed = fallback + (clear - fallback) * presence;
    offset = math.max(offset, needed);
  }
  return offset;
}

/// 顶部锚定的通知离 overlay 顶边多远：口径同 [noticeBottomOffset]——顶部 chrome
/// 显示时落在 chrome 下沿下方 [gap]，收起时回到 [fallback]。
double noticeTopOffset({
  required double fallback,
  required Iterable<NoticeObstacle> obstacles,
  required double laneLeft,
  required double laneRight,
  double gap = kNoticeChromeGap,
}) {
  double offset = fallback;
  for (final NoticeObstacle o in obstacles) {
    if (o.edge != NoticeObstacleEdge.top) continue;
    if (!_crossesLane(o.rect, laneLeft, laneRight)) continue;
    final double presence = o.presence.clamp(0.0, 1.0);
    if (presence <= 0) continue;
    final double clear = o.rect.bottom + gap;
    final double needed = fallback + (clear - fallback) * presence;
    offset = math.max(offset, needed);
  }
  return offset;
}

bool _crossesLane(Rect rect, double left, double right) =>
    rect.right > left && rect.left < right && !rect.isEmpty;

/// 登记表：[FushiNoticeObstacle] 挂载 / 更新 / 卸载时改它，通知宿主监听它重排。
///
/// 只收**此刻看得见**的页面里的 chrome：被别的路由整个盖住的页面，Overlay 会把
/// 它的 [TickerMode] 关掉，那里的 chrome 不算（否则设置页盖在阅读器上时，toast 还
/// 会给阅读器的底栏让位）。
final class FushiNoticeObstacles extends ChangeNotifier {
  FushiNoticeObstacles._();

  static final FushiNoticeObstacles instance = FushiNoticeObstacles._();

  final Set<_FushiNoticeObstacleState> _entries = <_FushiNoticeObstacleState>{};
  bool _notifyScheduled = false;

  /// 此刻生效的 chrome，矩形是全局坐标。
  Iterable<NoticeObstacle> get current sync* {
    for (final _FushiNoticeObstacleState s in _entries) {
      final NoticeObstacle? o = s._resolve();
      if (o != null) yield o;
    }
  }

  /// 换到 [overlay]（通知所在 Overlay 的 RenderBox）本地坐标。
  Iterable<NoticeObstacle> inOverlay(RenderBox overlay) sync* {
    for (final NoticeObstacle o in current) {
      final Offset topLeft = overlay.globalToLocal(o.rect.topLeft);
      yield (edge: o.edge, rect: topLeft & o.rect.size, presence: o.presence);
    }
  }

  void _add(_FushiNoticeObstacleState s) {
    _entries.add(s);
    _changed();
  }

  void _remove(_FushiNoticeObstacleState s) {
    if (_entries.remove(s)) _changed();
  }

  /// 登记方在 build 里也会调（进度每帧变），而 build / layout 阶段不能让监听方
  /// setState：一律挪到帧后统一发一次。
  void _changed() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    final SchedulerBinding binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle) {
      scheduleMicrotask(_flush);
    } else {
      binding.addPostFrameCallback((Duration _) => _flush());
    }
  }

  void _flush() {
    _notifyScheduled = false;
    notifyListeners();
  }

  @visibleForTesting
  int get debugEntryCount => _entries.length;
}

/// 把 [child] 登记成贴着 [edge] 的 chrome：短时通知会让开它。
///
/// [presence] 是显隐进度（显隐组件传自己的动画值；收起完 = 0，不再算障碍）。
/// 矩形取 [child] 布局后的全局矩形——包在位移变换**外面**，变换前的位置就是栏
/// 落定后的位置，进度只负责插值。
class FushiNoticeObstacle extends StatefulWidget {
  const FushiNoticeObstacle({
    super.key,
    this.edge,
    required this.presence,
    required this.child,
  });

  /// 贴着哪条边；null = 按矩形中心落在屏幕上半还是下半自动判（显隐组件不知道
  /// 自己被摆在哪儿，同一个组件既做顶栏也做底栏）。
  final NoticeObstacleEdge? edge;
  final double presence;
  final Widget child;

  @override
  State<FushiNoticeObstacle> createState() => _FushiNoticeObstacleState();
}

class _FushiNoticeObstacleState extends State<FushiNoticeObstacle> {
  final GlobalKey _box = GlobalKey();
  bool _live = true;

  NoticeObstacle? _resolve() {
    if (!mounted || !_live) return null;
    if (widget.presence <= 0) return null;
    final RenderObject? r = _box.currentContext?.findRenderObject();
    if (r is! RenderBox || !r.hasSize || !r.attached) return null;
    final Offset topLeft = r.localToGlobal(Offset.zero);
    final Rect rect = topLeft & r.size;
    final NoticeObstacleEdge edge =
        widget.edge ??
        (rect.center.dy > _viewHeight() / 2
            ? NoticeObstacleEdge.bottom
            : NoticeObstacleEdge.top);
    return (edge: edge, rect: rect, presence: widget.presence);
  }

  double _viewHeight() {
    final FlutterView view = View.of(context);
    return view.physicalSize.height / view.devicePixelRatio;
  }

  @override
  void initState() {
    super.initState();
    FushiNoticeObstacles.instance._add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool live = TickerMode.valuesOf(context).enabled;
    if (live != _live) {
      _live = live;
      FushiNoticeObstacles.instance._changed();
    }
  }

  @override
  void didUpdateWidget(FushiNoticeObstacle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.presence != widget.presence ||
        oldWidget.edge != widget.edge) {
      FushiNoticeObstacles.instance._changed();
    }
  }

  @override
  void dispose() {
    FushiNoticeObstacles.instance._remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _box, child: widget.child);
}
