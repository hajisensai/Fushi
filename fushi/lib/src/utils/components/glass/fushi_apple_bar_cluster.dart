import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show FushiAppleFloatingSurface;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassBarItem, GlassBarItemBackground, GlassPinnedBarChrome;

// Apple（Cupertino）库页导航栏的 bar button：直接用 liquid_glass_widgets 的
// [GlassPinnedBarChrome] + [GlassBarItem] 渲染（与 `GlassAppBar.pinned` 同一套
// 胶囊——相邻动作 `shared` 合成一枚玻璃胶囊、强调动作 `separate` 单独一枚
// 着色圆钮），不自绘。不注册到导航壳（`enabled: false`，Fushi 没有
// GlassNavigationShell），只取它的在路由内渲染。
//
// 玻璃跟随画质档位（主题由 FushiGlassScope 下发）；实色档（含系统降低透明度 /
// 增强对比度 / 墨水屏，见 [glassMaterialOf]）库没有实色胶囊，退回同形状的
// 系统材质实色胶囊（[FushiAppleFloatingSurface]）。

/// 动作胶囊高度：iOS 导航栏 44、macOS 工具栏 36（设计稿 v5 `.cap`）。
double fushiAppleBarCapsuleExtent({required bool compact}) => compact ? 44 : 36;

/// 胶囊里每颗按钮的最小宽（设计稿 v5 `.bb`：手机 36、桌面 32）。
double _itemMinWidth({required bool compact}) => compact ? 36 : 32;

/// 一组相邻动作合成的一枚玻璃胶囊（`GlassBarItemBackground.shared`）。
///
/// [items] 是已按宽度收过「⋯」的按钮（各自处理点击、焦点与语义，簇只画底）。
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
    final double minWidth = _itemMinWidth(compact: compact);
    Widget wrap(Widget item) => IconTheme.merge(
      data: IconThemeData(color: apple.label, size: compact ? 20 : 17),
      child: FushiToolbarScope(
        inGlassGroup: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth),
          child: Center(widthFactor: 1, child: item),
        ),
      ),
    );
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      final double extent = fushiAppleBarCapsuleExtent(compact: compact);
      return FushiAppleFloatingSurface(
        shape: const StadiumBorder(),
        child: SizedBox(
          height: extent,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[for (final Widget item in items) wrap(item)],
            ),
          ),
        ),
      );
    }
    return GlassPinnedBarChrome(
      enabled: false,
      backButton: false,
      // shared 胶囊高 = buttonSize + 2（库的 slot 46 − 圆钮 44）。
      buttonSize: fushiAppleBarCapsuleExtent(compact: compact) - 2,
      actions: <GlassBarItem>[
        for (final Widget item in items)
          GlassBarItem.custom(
            background: GlassBarItemBackground.shared,
            child: wrap(item),
          ),
      ],
      builder: (BuildContext context, chrome) =>
          Row(mainAxisSize: MainAxisSize.min, children: chrome.actions),
    );
  }
}

/// 一颗独立的强调色玻璃圆钮（`GlassBarItemBackground.separate` + `tintColor`，
/// iOS 26 `.tint()` 的 prominent bar button），如库页「导入」。[child] 自己处理
/// 点击 / 焦点 / 语义，前景色由调用方按 [tint] 取对比色。
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
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      return FushiAppleFloatingSurface(
        shape: const CircleBorder(),
        tint: tint,
        child: SizedBox.square(
          dimension: extent,
          child: Center(child: child),
        ),
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
          child: SizedBox.square(
            dimension: extent,
            child: Center(child: child),
          ),
        ),
      ],
      builder: (BuildContext context, chrome) =>
          Row(mainAxisSize: MainAxisSize.min, children: chrome.actions),
    );
  }
}
