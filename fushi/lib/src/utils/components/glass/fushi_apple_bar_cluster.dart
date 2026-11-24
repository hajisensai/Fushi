import 'package:flutter/rendering.dart' show BoxParentData, RenderShiftedBox;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show fushiAppleMacScale;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show FushiAppleFloatingSurface;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        DefaultButtonSettings,
        GlassBodyMode,
        GlassButtonGroup,
        GlassButtonGroupItem,
        GlassNavPinnedMetrics,
        LiquidGlassSettings;
import 'package:liquid_glass_widgets/theme/glass_theme_helpers.dart'
    show GlassThemeHelpers;

// Apple（Cupertino）导航栏的 bar button：用 liquid_glass_widgets 的玻璃钮渲染
// （[FushiAppleGlassBarButton]：与 `GlassAppBar.pinned` / `GlassPinnedBarChrome`
// 的 separate 钮同一个 [GlassButtonGroup.icons]）。iOS 27：每个动作一枚独立的中性玻璃圆钮
// （`GlassBarItemBackground.separate`，不着强调色），钮间距 8
// （[kFushiAppleBarItemGap]），带文字的动作是同高的玻璃胶囊。Fushi 没有
// GlassNavigationShell，也没有 iPhone Duo 竖条。
//
// 玻璃跟随画质档位（主题由 FushiGlassScope 下发）；实色档（含系统降低透明度 /
// 增强对比度 / 墨水屏，见 [glassMaterialOf]）库没有实色钮，退回同形状的
// 系统材质实色面（[FushiAppleFloatingSurface]）。

/// 玻璃钮直径：iOS 导航栏 44、macOS 工具栏 36（设计稿 v5 `.cap`；宽窗乘
/// [fushiAppleMacScale]，Windows / Linux 放大、Mac 不变）。
double fushiAppleBarCapsuleExtent(
  BuildContext context, {
  required bool compact,
}) => compact ? 44 : 36 * fushiAppleMacScale(context);

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
    final double extent = fushiAppleBarCapsuleExtent(context, compact: compact);
    Widget wrap(Widget item) => IconTheme.merge(
      data: IconThemeData(
        color: apple.label,
        size: compact ? 20 : 17 * fushiAppleMacScale(context),
      ),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: kFushiAppleBarItemGap,
      children: <Widget>[
        for (final Widget item in items)
          FushiAppleGlassBarButton(extent: extent, child: wrap(item)),
      ],
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
    // 高度只给上限、不给下限：槽自己恒为 extent 高、子节点竖直居中。此前给
    // minHeight = extent，按钮会自己居中内容，但不居中的子节点（纯文字等）被
    // 撑到 extent 高后字贴在胶囊顶上（视频库多选态顶栏「已选 N 项」）。
    child.layout(
      BoxConstraints(minWidth: _extent, maxHeight: _extent),
      parentUsesSize: true,
    );
    if (child.size.width <= _extent * _iconSlack) {
      child.layout(
        BoxConstraints.tight(Size.square(_extent)),
        parentUsesSize: true,
      );
    }
    size = constraints.constrain(Size(child.size.width, _extent));
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
    final double extent = fushiAppleBarCapsuleExtent(context, compact: compact);
    final Widget content = _AppleBarSlot(extent: extent, child: child);
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      return FushiAppleFloatingSurface(
        shape: const CircleBorder(),
        tint: tint,
        child: content,
      );
    }
    return FushiAppleGlassBarButton(extent: extent, tint: tint, child: content);
  }
}

/// 一枚独立的 liquid_glass 玻璃 bar button 底：`GlassBarItemBackground.separate`
/// 的同一渲染——库的 [GlassButtonGroup.icons] 单项、高 = [extent]、圆角 = 一半
/// （图标钮正圆、带字钮同高胶囊）；[tint] 非空时按库对 `tintColor` 的做法以
/// [GlassBodyMode.clear] 直接着色。[child] 自己处理点击 / 焦点 / 语义（库这一项
/// 不挂点击、不另立语义）。
///
/// 不经 `GlassPinnedBarChrome`（BUG-5444）：它无条件挂一个
/// `OverlayPortal.overlayChildLayoutBuilder`（给 iPhone Duo 竖条用；没有竖条时
/// 永远是 `SizedBox.shrink`）。框架让这种布局构建器**每一帧**都重新布局，布局又
/// `markNeedsSemanticsUpdate`，而它挂在路由的 Overlay 里、到应用根之间没有已建的
/// 语义边界——任何连续动画期间（首页编辑态抖动、加载圈……）每帧都从应用根重走
/// 语义树；保活的各 tab 顶栏合计十几枚，debug 实例主线程被占满。Fushi 只要它画
/// 玻璃钮，所以直接用它最终渲染的那个库组件。
class FushiAppleGlassBarButton extends StatelessWidget {
  const FushiAppleGlassBarButton({
    required this.extent,
    required this.child,
    this.tint,
    super.key,
  });

  /// 钮高（图标钮的直径）。
  final double extent;
  final Widget child;

  /// 强调色玻璃（iOS `.tint()` 的 prominent bar button）；null = 中性玻璃。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final TextDirection ambient = Directionality.of(context);
    final Color? tint = this.tint;
    final LiquidGlassSettings? settings = tint == null
        ? null
        : GlassThemeHelpers.resolveSettings(
            context,
            explicit: DefaultButtonSettings.of(context),
          ).copyWith(glassColor: tint, bodyMode: GlassBodyMode.clear);
    // 与库一致：组内强制 LTR，钮内容恢复环境方向。
    return Directionality(
      textDirection: TextDirection.ltr,
      child: GlassButtonGroup.icons(
        settings: settings,
        borderRadius: extent / 2,
        iconSize: GlassNavPinnedMetrics.iconSize,
        itemPadding: EdgeInsets.zero,
        items: <GlassButtonGroupItem>[
          GlassButtonGroupItem(
            icon: SizedBox(
              height: extent,
              child: Center(
                child: Directionality(textDirection: ambient, child: child),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
