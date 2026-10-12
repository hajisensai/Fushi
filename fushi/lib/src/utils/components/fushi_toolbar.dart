import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show fushiAppleCompact;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show fushiAppleSolidFloatingDecoration;

/// 告诉后代按钮「你已经在一枚 Apple 玻璃组胶囊里」：[FushiIconButton] 的
/// 带文字形态与选中态据此不再自带一层玻璃（玻璃叠玻璃会出两圈折射边，
/// iOS 26 工具栏组里的按钮本身是无底的）。只有 [FushiToolbar] 的 Apple
/// 分支会放 true；MD3 与域外一律 false。
class FushiToolbarScope extends InheritedWidget {
  const FushiToolbarScope({
    required this.inGlassGroup,
    required super.child,
    super.key,
  });

  final bool inGlassGroup;

  static bool inGlassGroupOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiToolbarScope>()
          ?.inGlassGroup ??
      false;

  @override
  bool updateShouldNotify(FushiToolbarScope oldWidget) =>
      inGlassGroup != oldWidget.inGlassGroup;
}

/// 一组图标按钮 / 小按钮的工具栏，按设计系统分派外观：
///
/// - **MD3（M3 Expressive toolbar）**：嵌入（[floating] = false）= 无底一排，
///   组间 8 留白，[showDividers] 时组间加一条细竖分隔；悬浮 = surfaceContainer
///   全胶囊、高 64（[dense] 56）、elevation 3、内边距 8。按钮本身用
///   [FushiIconButton] 的 Expressive 图标按钮（按压圆 → 圆角 12）。
/// - **Apple（原生 Cupertino）**：嵌入 = 无底的一排 bar button（高 36 桌面 /
///   44 移动，[dense] 32 / 36），组与组之间 10（[dense] 8）的间隙；[floating]
///   时每组收进一枚系统材质实色胶囊 + 发丝描边 + 柔和投影
///   （[fushiAppleSolidFloatingDecoration]），不做玻璃与实时模糊。
///
/// 键盘：整条工具栏是一个 [FocusTraversalGroup]——Tab 一次走完组内按钮再
/// 离开，左右方向键由全局方向导航（FushiFocusController 的几何寻路 / Flutter
/// 默认的 DirectionalFocusIntent）在按钮间移动。子组件原样挂进去，key /
/// tooltip / 焦点注册都不变。
class FushiToolbar extends StatelessWidget {
  const FushiToolbar({
    super.key,
    this.children = const <Widget>[],
    this.groups,
    this.floating = false,
    this.dense = false,
    this.showDividers = false,
  });

  /// 单组的按钮（[groups] 为 null 时用）。
  final List<Widget> children;

  /// 分组的按钮；非 null 时忽略 [children]。空组会被跳过。
  final List<List<Widget>>? groups;

  /// 悬浮在内容上（MD3 胶囊底 + 阴影 / Apple 胶囊加投影）还是嵌入在页面里。
  final bool floating;

  /// 紧凑尺寸（库页搜索栏旁那种挤在一行里的工具栏）。
  final bool dense;

  /// MD3 嵌入形态的组间细竖分隔；Apple 的组本身就是分开的胶囊，不画。
  final bool showDividers;

  List<List<Widget>> get _groups => (groups ?? <List<Widget>>[children])
      .where((List<Widget> g) => g.isNotEmpty)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final List<List<Widget>> groups = _groups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final Widget bar = isGlassDesign(context)
        ? _buildApple(context, groups)
        : _buildMaterial(context, groups);
    return FocusTraversalGroup(child: bar);
  }

  Widget _buildMaterial(BuildContext context, List<List<Widget>> groups) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final double itemGap = dense ? 0 : 4;
    final List<Widget> row = <Widget>[];
    for (int g = 0; g < groups.length; g++) {
      if (g > 0) {
        if (showDividers && !floating) {
          row
            ..add(const SizedBox(width: 8))
            ..add(
              SizedBox(
                height: 24,
                child: VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: cs.outlineVariant,
                ),
              ),
            )
            ..add(const SizedBox(width: 8));
        } else {
          row.add(const SizedBox(width: 8));
        }
      }
      final List<Widget> group = groups[g];
      for (int i = 0; i < group.length; i++) {
        if (i > 0 && itemGap > 0) row.add(SizedBox(width: itemGap));
        row.add(group[i]);
      }
    }
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: row,
    );
    if (!floating) return content;
    // M3 Expressive floating toolbar：surfaceContainer 全胶囊、elevation 3、
    // 内边距 8、总高 64（dense 56）。墨水屏不要阴影（残影），改描边。
    final double height = dense ? 56 : 64;
    return Material(
      color: cs.surfaceContainer,
      elevation: eink ? 0 : 3,
      shadowColor: cs.shadow,
      surfaceTintColor: Colors.transparent,
      shape: StadiumBorder(
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height, minWidth: height),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Center(widthFactor: 1, heightFactor: 1, child: content),
        ),
      ),
    );
  }

  Widget _buildApple(BuildContext context, List<List<Widget>> groups) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final double height = dense ? (compact ? 32 : 36) : (compact ? 36 : 44);
    final double groupGap = dense ? 8 : 10;
    final List<Widget> row = <Widget>[];
    for (int g = 0; g < groups.length; g++) {
      if (g > 0) row.add(SizedBox(width: groupGap));
      // 原生 Cupertino（用户 2026-10-12「特效都去掉，直接原生 Cupertino」）：
      // 栏内的按钮组不套胶囊，就是一排无底 bar button；悬浮形态浮在封面 /
      // 图片上，套一枚系统材质实色胶囊 + 发丝描边 + 柔和投影，不做玻璃与
      // 实时模糊（逐颗模糊会掉帧）。
      Widget capsule = ConstrainedBox(
        constraints: BoxConstraints(minHeight: height, minWidth: height),
        child: Padding(
          // 胶囊两端留一点，让首尾按钮的悬停圆底不贴着胶囊边。
          padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
          child: IconTheme.merge(
            data: IconThemeData(color: apple.label, size: compact ? 18 : 20),
            child: FushiToolbarScope(
              inGlassGroup: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: groups[g],
              ),
            ),
          ),
        ),
      );
      if (floating) {
        capsule = DecoratedBox(
          decoration: fushiAppleSolidFloatingDecoration(
            context,
            shape: const StadiumBorder(),
          ),
          child: capsule,
        );
      }
      row.add(capsule);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: row,
    );
  }
}
