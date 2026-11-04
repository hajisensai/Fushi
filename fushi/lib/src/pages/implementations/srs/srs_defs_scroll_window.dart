/// 复习卡窄版式释义区的「滚动窗口」（BUG-4038）。
///
/// 窄版式背面是一条 Flutter 滚动：原生标题区 → 释义 WebView（跟内容等高）→ 原生页脚。
/// 释义高过平台视图纹理上限时，平台视图只能是内容里的一段窗口。旧做法把它改成一屏高、
/// 「WebView 内部滚动」，可平台视图不认领纵向拖（外层 Flutter 滚动要用），触屏上页内永远
/// 停在顶部：只看得到第一屏释义，下面的词典全够不着。
///
/// 这里滚动物理只归外层一个所有者：
/// - 释义区在外层滚动里始终占满内容高度，所以外层能一路滚到页脚；
/// - 平台视图（窗口）摆在内容坐标 [_SrsDefsScrollWindowState._top] 处，页面被
///   [SrsPageWindowLink] 钉在同一个页内滚动位置，窗口里显示的正好是那一段内容；
/// - 视口滑出窗口时换窗口：**先**等页面换到新位置，**再**挪平台视图。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart'
    show SrsPageWindowLink;

/// 窗口起点（内容坐标，整数 px）：可见段 `[visibleTop, visibleTop + visibleHeight]`
/// 仍完整落在当前窗口里就不动（换窗口有一次跨平台通道往返，越少越好），否则让可见段
/// 居中到新窗口里。窗口不越出内容。
@visibleForTesting
double srsDefsWindowTop({
  required double current,
  required double visibleTop,
  required double visibleHeight,
  required double contentHeight,
  required double windowHeight,
}) {
  final double maxTop = math.max(0, contentHeight - windowHeight);
  final double cur = current.clamp(0.0, maxTop);
  final double v0 = visibleTop.clamp(0.0, contentHeight);
  final double v1 = (visibleTop + visibleHeight).clamp(0.0, contentHeight);
  if (v0 >= cur && v1 <= cur + windowHeight) return cur;
  final double slack = math.max(0, windowHeight - (v1 - v0));
  return (v0 - slack / 2).clamp(0.0, maxTop).roundToDouble();
}

/// 释义区：内容不超过 [maxFrameHeight] 时 [child] 铺满自己（与旧行为相同）；超过时
/// [child] 是一段 [maxFrameHeight] 高的窗口，跟着外层 [controller] 的滚动换位置。
class SrsDefsScrollWindow extends StatefulWidget {
  const SrsDefsScrollWindow({
    super.key,
    required this.contentHeight,
    required this.maxFrameHeight,
    required this.controller,
    required this.link,
    required this.child,
  });

  /// 页面上报的内容高度（本组件在外层滚动里占的高度）。
  final double contentHeight;

  /// 平台视图的最大高度（纹理上限）。
  final double maxFrameHeight;

  /// 外层滚动（唯一的滚动所有者）。
  final ScrollController controller;

  /// 驱动页内滚动位置的通道。
  final SrsPageWindowLink link;

  /// 释义 WebView。树形在两种模式下不变，平台视图不会被重建。
  final Widget child;

  @override
  State<SrsDefsScrollWindow> createState() => _SrsDefsScrollWindowState();
}

class _SrsDefsScrollWindowState extends State<SrsDefsScrollWindow> {
  /// 平台视图当前摆放的窗口起点（内容坐标）。
  double _top = 0;

  /// 正在等页面执行的窗口起点（null = 没有在途的切换）。
  double? _pending;

  bool get _windowed => widget.contentHeight > widget.maxFrameHeight;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_reposition);
    _schedule();
  }

  @override
  void didUpdateWidget(SrsDefsScrollWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_reposition);
      widget.controller.addListener(_reposition);
    }
    final bool wasWindowed = oldWidget.contentHeight > oldWidget.maxFrameHeight;
    if (wasWindowed && !_windowed) {
      // 内容收回上限以内：页面退出窗口态，平台视图重新跟内容等高。
      _top = 0;
      _pending = null;
      unawaited(widget.link.apply(null));
    }
    _schedule();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reposition);
    if (widget.link.top != null) unawaited(widget.link.apply(null));
    super.dispose();
  }

  /// 布局完成后再量自己在外层滚动里的位置。
  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reposition();
    });
  }

  void _reposition() {
    if (!_windowed || _pending != null) return;
    final ScrollController controller = widget.controller;
    final RenderObject? box = context.findRenderObject();
    if (!controller.hasClients || box is! RenderBox || !box.attached) return;
    final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(
      box,
    );
    if (viewport == null) return;
    final ScrollPosition pos = controller.position;
    final double boxTop = viewport.getOffsetToReveal(box, 0).offset;
    final double next = srsDefsWindowTop(
      current: _top,
      visibleTop: pos.pixels - boxTop,
      visibleHeight: pos.viewportDimension,
      contentHeight: widget.contentHeight,
      windowHeight: widget.maxFrameHeight,
    );
    if (next == _top && widget.link.top == next) return;
    unawaited(_move(next));
  }

  Future<void> _move(double next) async {
    _pending = next;
    await widget.link.apply(next);
    if (!mounted || _pending != next) return;
    _pending = null;
    setState(() => _top = next);
    // 等页面期间外层可能又滚了一段。
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    final bool windowed = _windowed;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          top: windowed ? _top : 0,
          height: windowed ? widget.maxFrameHeight : null,
          bottom: windowed ? null : 0,
          child: widget.child,
        ),
      ],
    );
  }
}
