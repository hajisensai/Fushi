import 'package:flutter/rendering.dart' show BoxParentData, RenderShiftedBox;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show FushiAppleFloatingSurface;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassBarItem, GlassBarItemBackground, GlassPinnedBarChrome;

// Apple（Cupertino）导航栏的 bar button：直接用 liquid_glass_widgets 的
// [GlassPinnedBarChrome] + [GlassBarItem] 渲染（与 `GlassAppBar.pinned` 同一套
// 玻璃钮）。iOS 27：每个动作一枚独立的中性玻璃圆钮
// （`GlassBarItemBackground.separate`，不着强调色），钮间距 8
// （[kFushiAppleBarItemGap]），带文字的动作是同高的玻璃胶囊。不注册到导航壳
// （`enabled: false`，Fushi 没有 GlassNavigationShell），只取它的在路由内渲染。
//
// 玻璃跟随画质档位（主题由 FushiGlassScope 下发）；实色档（含系统降低透明度 /
// 增强对比度 / 墨水屏，见 [glassMaterialOf]）库没有实色钮，退回同形状的
// 系统材质实色面（[FushiAppleFloatingSurface]）。

/// 玻璃钮直径：iOS 导航栏 44、macOS 工具栏 36（设计稿 v5 `.cap`）。
double fushiAppleBarCapsuleExtent({required bool compact}) => compact ? 44 : 36;

/// 相邻两枚独立玻璃钮之间的间距（iOS 27 导航栏实测 ≈ 8）。
const double kFushiAppleBarItemGap = 8;

/// 一排动作：每个动作一枚独立的中性玻璃圆钮（`GlassBarItemBackground.separate`）。
///
/// [items] 是已按宽度收过「⋯」的按钮（各自处理点击、焦点与语义，簇只画底）。
/// 纯图标钮（含「⋯」）一律按 [fushiAppleBarCapsuleExtent] 的正方形排，底是
/// 正圆；带文字的钮按自身宽度排成同高胶囊（见 [_AppleBarSlot]）。
class FushiAppleBarCluster extends StatelessWidget {
  const FushiAppleBarCluster({
    required this.items,
    required this.compact,
    super.key,
  });

  final List<Widget> items;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final FushiAppleColors apple = appleColorsOf(context);
    final double extent = fushiAppleBarCapsuleExtent(compact: compact);
    Widget wrap(Widget item) => IconTheme.merge(
      data: IconThemeData(color: apple.label, size: compact ? 20 : 17),
      child: FushiToolbarScope(
        inGlassGroup: true,
        child: _AppleBarSlot(extent: extent, child: item),
      ),
    );
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: kFushiAppleBarItemGap,
        children: <Widget>[
          for (final Widget item in items)
            FushiAppleFloatingSurface(
              shape: const StadiumBorder(),
              child: wrap(item),
            ),
        ],
      );
    }
    return GlassPinnedBarChrome(
      enabled: false,
      backButton: false,
      // separate 钮的直径就是 buttonSize（单钮组 crossExtent = buttonSize，
      // 圆角 = 一半，正圆）。
      buttonSize: extent,
      actions: <GlassBarItem>[
        for (final Widget item in items)
          GlassBarItem.custom(
            background: GlassBarItemBackground.separate,
            child: wrap(item),
          ),
      ],
      builder: (BuildContext context, chrome) => Row(
        mainAxisSize: MainAxisSize.min,
        spacing: kFushiAppleBarItemGap,
        children: chrome.actions,
      ),
    );
  }
}

/// 一枚 bar button 的槽：先按「高 = [extent]、宽不限」量子节点；量出来不比
/// [extent] 宽太多（纯图标钮：Material 弹出菜单钮自带 48 的点按区、图标钮带
/// padding）就改按 [extent] 见方的紧约束重排——玻璃底恒为正圆、图标居中；带
/// 文字的钮按自身宽度排（同高胶囊）。只用真实布局判，不取 intrinsic（槽里的
/// 钮可能含 LayoutBuilder）。
class _AppleBarSlot extends SingleChildRenderObjectWidget {
  const _AppleBarSlot({required this.extent, required Widget super.child});

  final double extent;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAppleBarSlot(extent);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAppleBarSlot renderObject,
  ) {
    renderObject.extent = extent;
  }
}

class _RenderAppleBarSlot extends RenderShiftedBox {
  _RenderAppleBarSlot(this._extent) : super(null);

  /// 量出的宽不超过 extent 的这个倍数就当纯图标钮（48 / 44 ≈ 1.09，
  /// 36 宽窗里 48 的菜单钮 ≈ 1.33；最短的带字胶囊也在 2 倍以上）。
  static const double _iconSlack = 1.5;

  double get extent => _extent;
  double _extent;
  set extent(double value) {
    if (value == _extent) return;
    _extent = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(Size.square(_extent));
      return;
    }
    child.layout(
      BoxConstraints(minWidth: _extent, minHeight: _extent, maxHeight: _extent),
      parentUsesSize: true,
    );
    if (child.size.width <= _extent * _iconSlack) {
      child.layout(
        BoxConstraints.tight(Size.square(_extent)),
        parentUsesSize: true,
      );
    }
    size = constraints.constrain(child.size);
    final BoxParentData data = child.parentData! as BoxParentData;
    data.offset = Alignment.center.alongOffset(size - child.size as Offset);
  }
}

/// 一颗独立的强调色玻璃圆钮（`GlassBarItemBackground.separate` + `tintColor`，
/// iOS 26 `.tint()` 的 prominent bar button）。iOS 27 导航栏的动作不着强调色
/// （所有者 2026-11-24 对照 iOS 27 图书：「+」也是中性圆钮）——顶栏动作一律走
/// [FushiAppleBarCluster]；这里只留给仍要强调色的调用方。[child] 自己处理点击 /
/// 焦点 / 语义，前景色由调用方按 [tint] 取对比色。
class FushiAppleBarProminentButton extends StatelessWidget {
  const FushiAppleBarProminentButton({
    required this.child,
    required this.tint,
    required this.compact,
    super.key,
  });

  final Widget child;
  final Color tint;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final double extent = fushiAppleBarCapsuleExtent(compact: compact);
    final Widget content = _AppleBarSlot(extent: extent, child: child);
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      return FushiAppleFloatingSurface(
        shape: const CircleBorder(),
        tint: tint,
        child: content,
      );
    }
    return GlassPinnedBarChrome(
      enabled: false,
      backButton: false,
      buttonSize: extent,
      actions: <GlassBarItem>[
        GlassBarItem.custom(
          background: GlassBarItemBackground.separate,
          tintColor: tint,
          child: content,
        ),
      ],
      builder: (BuildContext context, chrome) =>
          Row(mainAxisSize: MainAxisSize.min, children: chrome.actions),
    );
  }
}
