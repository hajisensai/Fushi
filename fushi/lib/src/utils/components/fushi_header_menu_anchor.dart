import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';

/// 页头动作打开的菜单（库页「排序」菜单）的控制器（BUG-4715）。
///
/// 页头动作可能被收进「⋯」，菜单因此不能挂在某颗按钮上（按钮会被卸载），只能由
/// 常驻的 [FushiHeaderMenuAnchor] 持有；但菜单的**弹出位置**必须跟着真正点下去
/// 的那颗控件——按钮外露时是按钮自己，被收纳时是「⋯」。本控制器在打开时把触发
/// 控件（默认取 [FushiActionOrigin.current]）交给锚点，锚点把自己的锚框挪到触发
/// 控件的矩形上，菜单于是与其他 [FushiMenuAnchor] 一样从按钮下沿弹出。
///
/// 回归：锚点曾是叠在页头动作组右下角的零尺寸盒子，只要排序按钮不在动作组最右
/// 端，菜单就弹在离按钮老远的右下角。
class FushiHeaderMenuController {
  final MenuController _menu = MenuController();
  _FushiHeaderMenuAnchorState? _anchor;

  /// 交给 [FushiMenuAnchor] 的底层控制器（菜单项关菜单等用）。
  MenuController get menu => _menu;

  bool get isOpen => _menu.isOpen;

  /// 从 [trigger] 打开菜单；省略时取正在派发的动作的触发控件
  /// （[FushiActionOrigin.current]，所以必须在按钮 onTap 的同步段里调用）。
  /// 两者都没有时锚在页头动作组的末端下沿。
  void open({BuildContext? trigger}) {
    _anchor?._anchorTo(trigger ?? FushiActionOrigin.current);
    _menu.open();
  }

  void close() => _menu.close();

  /// 开着就关，关着就从触发控件打开（见 [open]）。
  void toggle({BuildContext? trigger}) {
    if (isOpen) {
      close();
    } else {
      open(trigger: trigger);
    }
  }
}

/// [FushiHeaderMenuController] 的常驻锚点：经 `FushiPageHeader.menuAnchor`
/// 铺满页头动作组（`fushiHeaderActionsWithMenuAnchor`），动作画在页头本行就随
/// 本行、登记进外壳浮动工具栏就随那枚胶囊；锚框本身落在最近一次打开菜单的触发
/// 控件上。
class FushiHeaderMenuAnchor extends StatefulWidget {
  const FushiHeaderMenuAnchor({
    required this.controller,
    required this.menuChildren,
    super.key,
  });

  final FushiHeaderMenuController controller;
  final List<Widget> menuChildren;

  @override
  State<FushiHeaderMenuAnchor> createState() => _FushiHeaderMenuAnchorState();
}

class _FushiHeaderMenuAnchorState extends State<FushiHeaderMenuAnchor> {
  /// 触发控件在本锚点坐标系里的矩形；null = 没有触发控件（锚在末端下沿）。
  Rect? _triggerRect;

  @override
  void initState() {
    super.initState();
    widget.controller._anchor = this;
  }

  @override
  void didUpdateWidget(FushiHeaderMenuAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller._anchor == this) {
        oldWidget.controller._anchor = null;
      }
      widget.controller._anchor = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller._anchor == this) widget.controller._anchor = null;
    super.dispose();
  }

  /// 量出 [trigger] 相对本锚点的矩形并据此重排锚框。与 [MenuController.open]
  /// 同步调用即可：菜单浮层在下一帧布局时才读锚框的位置（OverlayPortal 的
  /// childPaintTransform），那时锚框已经挪到位。
  void _anchorTo(BuildContext? trigger) {
    final Rect? rect = _rectOf(trigger);
    if (rect == _triggerRect) return;
    setState(() => _triggerRect = rect);
  }

  Rect? _rectOf(BuildContext? trigger) {
    if (trigger == null || !trigger.mounted) return null;
    final RenderObject? host = context.findRenderObject();
    final RenderObject? target = trigger.findRenderObject();
    if (host is! RenderBox || target is! RenderBox) return null;
    if (!host.hasSize || !target.hasSize) return null;
    if (!host.attached || !target.attached) return null;
    return Rect.fromPoints(
      host.globalToLocal(target.localToGlobal(Offset.zero)),
      host.globalToLocal(
        target.localToGlobal(target.size.bottomRight(Offset.zero)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Rect? rect = _triggerRect;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    // 两种摆法都用同一个 [Positioned] 类型，菜单锚点的 State（及其挂着的
    // MenuController）不会因为换位置被重建。
    final Positioned anchor = rect == null
        ? Positioned(
            left: rtl ? 0 : null,
            right: rtl ? null : 0,
            bottom: 0,
            width: 0,
            height: 0,
            child: _menuAnchor(),
          )
        : Positioned(
            left: rect.left,
            top: rect.top,
            width: rect.width,
            height: rect.height,
            child: _menuAnchor(),
          );
    // 锚框只是位置参照，不吃指针：点击照常落到下面的动作按钮。
    return IgnorePointer(
      child: Stack(clipBehavior: Clip.none, children: <Widget>[anchor]),
    );
  }

  Widget _menuAnchor() {
    return FushiMenuAnchor(
      controller: widget.controller.menu,
      menuChildren: widget.menuChildren,
      child: const SizedBox.expand(),
    );
  }
}
