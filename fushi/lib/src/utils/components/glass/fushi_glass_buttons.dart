import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 按钮族的「设计系统分派」包装：构造参数与 Material 原控件逐个同名同型，
// 调用点只改类名。MD3 设计系统下原样构造原控件（像素、焦点、语义一字不差）；
// 「玻璃」设计系统下按 iOS 26 的按钮样式渲染：主按钮 / 次按钮 / 文字按钮都是
// liquid_glass_widgets 的 [GlassButton] 玻璃胶囊（自带 GlassFocusRegion：焦点环 +
// Enter → ActivateIntent，与全局焦点导航和手柄 A 键同一条激活链路）；内联链接与
// 默认图标按钮是无底的 plain 按钮（同样走 ActivateIntent）。

enum _FushiButtonKind { text, filled, tonal, outlined }

/// 标记「iOS 26 alert 的动作区」：其中的按钮一律画成撑满宽度的 44 高胶囊——
/// 主操作（FilledButton）强调色玻璃，其余（TextButton / Outlined / Tonal）
/// 中性玻璃；前景色给成 error / destructive 的就是红字破坏性操作。由
/// [FushiAlertDialog] 的玻璃形态在动作区外包一层。
class FushiAlertActionScope extends InheritedWidget {
  const FushiAlertActionScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiAlertActionScope>() !=
      null;

  @override
  bool updateShouldNotify(FushiAlertActionScope oldWidget) => false;
}

/// 标记「对话框面板内部」：由对话框外壳（`FushiDialogFrame` / 玻璃对话框
/// 外壳）在面板里包一层。面板内的列表行据此改用菜单式选中（Apple：无底 +
/// 行尾强调色对勾；MD3：圆角 secondaryContainer 高亮），而不是页面列表的整行
/// 选中块——对话框里的单选列表读起来是「菜单」，不是「导航列表」。
class FushiDialogScope extends InheritedWidget {
  const FushiDialogScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiDialogScope>() != null;

  @override
  bool updateShouldNotify(FushiDialogScope oldWidget) => false;
}

/// 标记「macOS 26 sheet 的底部动作区」：其中的文字按钮（取消 / 关闭类）画成
/// 透明液态玻璃胶囊（`.glass`）+ label 色字，而不是无底的强调色文字——
/// sheet 底部右对齐的一排按钮要有同一个高度、同一种胶囊形，主操作才是
/// 唯一的强调色块。只在 Apple 设计系统下生效；尺寸与内容区按钮相同
/// （桌面 34 / 移动 44），不像 [FushiAlertActionScope] 那样撑满宽度。
class FushiDialogActionScope extends InheritedWidget {
  const FushiDialogActionScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiDialogActionScope>() !=
      null;

  @override
  bool updateShouldNotify(FushiDialogActionScope oldWidget) => false;
}

/// 无色透明液态玻璃（iOS / macOS 26 的 `.glass` 控件：Niratan 参考图里的
/// 分段控件轨、工具栏图标组、弹出按钮）：几乎无填充、无着色，只有一圈清楚的
/// 高光边与轻微折射——不是灰色玻璃块。[lighter] = 选中段 / 选中钮那枚「更亮
/// 一点的透明 pill」（仍无强调色）。系统降低透明度（材质 off）回落实色：
/// 底 = [fushiGlassSettings] 的实心填充，[lighter] 换成高一阶的分组底色。
///
/// [bar] = 浮在内容上的大块导航 / 操作条（底部标签栏胶囊与搜索圆钮、批量操作条、
/// 正在听书迷你条、底部动作条、悬浮工具栏）：同样无色，但面积大、下面常压着
/// 封面与正文，可读性靠玻璃自身——iOS 26 / 27 `glassEffect(.regular)` 的配方
/// （库 [LiquidGlassSettings.ios27Light] / [LiquidGlassSettings.ios27Dark] 实测）：
/// 一层宽 frost 云 + 透出的内容「淡影」、上沿亮边 rimLight + 外圈 rimShade、
/// paraxial 折射带；填充浅色白 ≈45%（实测 53%），深色换成黑 ≈22%——深色栏
/// 要把背后内容压暗，白色填充叠在 frost 云上就是灰白雾。frost / rim 只在
/// premium（Impeller）路径画；Skia 后端（液态被降成磨砂档）没有这些项，改用
/// 更强的普通模糊兜可读性。
LiquidGlassSettings fushiClearGlassSettings(
  BuildContext context, {
  bool lighter = false,
  bool bar = false,
}) {
  final FushiGlassMaterial material = glassMaterialOf(context);
  if (material == FushiGlassMaterial.off) {
    return fushiGlassSettings(
      context,
      tint: lighter ? appleColorsOf(context).tertiaryGroupedBackground : null,
    );
  }
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  if (bar) return _clearBarGlassSettings(material, dark: dark);
  if (dark) {
    // 深色 `.glass`：几乎不抬亮底色——本体是极淡的黑（把背后内容压暗一点点，
    // 不是白雾），轮廓只靠一圈细而不刺眼的亮边。白色填充 / 高 lightIntensity /
    // ambientRim / 厚 bevel 在深底上都会把控件抬成一块灰白雾（用户 Mac 实机反馈
    // 「夜间泛白」）。选中 pill（[lighter]）只比轨道亮一阶：白 ≈9%。
    return LiquidGlassSettings(
      glassColor: lighter
          ? Colors.white.withValues(alpha: 0.09)
          : Colors.black.withValues(alpha: 0.14),
      blur: material == FushiGlassMaterial.frosted ? 10 : 2,
      thickness: 12,
      lightIntensity: 0.3,
      ambientStrength: 0,
      ambientRim: 0.18,
      fresnelStrength: 0.35,
      chromaticAberration: 0,
      saturation: 1.0,
      refractiveIndex: 1.12,
      shadowElevation: 0,
    );
  }
  // 浅色 `.glass`：可见的白色雾面 + 清楚的暗边与投影把控件从浅色背景上
  // 分离出来（浅色下库的 rim 几乎不画，边界全靠 edgeAbsorption 的暗边与外投影）。
  // 白 20% 的旧值压在 #F2F2F7 分组底上几乎看不见轮廓。
  return LiquidGlassSettings(
    glassColor: Colors.white.withValues(alpha: lighter ? 0.92 : 0.62),
    blur: material == FushiGlassMaterial.frosted ? 10 : 6,
    thickness: 16,
    lightIntensity: 0.5,
    ambientStrength: 0,
    ambientRim: 0.15,
    fresnelStrength: 0.8,
    chromaticAberration: 0,
    saturation: 1.2,
    refractiveIndex: 1.15,
    edgeAbsorption: 0.035,
    shadow: <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: lighter ? 0.16 : 0.12),
        blurRadius: 3,
        offset: const Offset(0, 0.5),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: lighter ? 0.08 : 0.06),
        blurRadius: 12,
        offset: const Offset(0, 3),
      ),
    ],
  );
}

/// 控件层 bezel：把 [child] 放进一枚无色透明液态玻璃（[fushiClearGlassSettings]）。
/// 用于内容里那些「控件」而非「内容」的底：弹出 / 下拉按钮（Niratan「Klee ⌃⌄」）、
/// 设置行尾的选择器、浮在封面上的角标、页头元信息胶囊。HIG Materials：Liquid
/// Glass 属于控件 / 导航层，内容层（分组卡、列表行、封面）才是实色——所以这些
/// 控件不再铺 systemFill 灰块。已经在另一枚玻璃面里（avoidsRefraction）时不再
/// 另起折射层，避免玻璃套玻璃；系统降低透明度时 settings 回落实色。
Widget fushiClearGlassBezel(
  BuildContext context, {
  required Widget child,
  required double radius,
  bool lighter = false,
}) {
  final bool nested =
      context
          .dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>()
          ?.avoidsRefraction ??
      false;
  return GlassContainer(
    useOwnLayer: !nested,
    quality: fushiGlassQuality(context),
    settings: fushiClearGlassSettings(context, lighter: lighter),
    shape: LiquidRoundedSuperellipse(borderRadius: radius),
    child: child,
  );
}

/// [fushiClearGlassSettings] 的 `bar` 档（见那里的说明）。[material] 只会是
/// liquid（Impeller，premium 路径）或 frosted（Skia 回退）。
LiquidGlassSettings _clearBarGlassSettings(
  FushiGlassMaterial material, {
  required bool dark,
}) {
  if (material != FushiGlassMaterial.liquid) {
    return LiquidGlassSettings(
      glassColor: Colors.white.withValues(alpha: dark ? 0.08 : 0.3),
      blur: dark ? 10 : 12,
      thickness: 24,
      lightIntensity: dark ? 0.6 : 0.7,
      ambientStrength: 0,
      ambientRim: dark ? 0.4 : 0.3,
      fresnelStrength: dark ? 0.6 : 1.0,
      chromaticAberration: 0,
      saturation: dark ? 1.3 : 1.6,
      refractiveIndex: 1.2,
      shadowElevation: dark ? 0 : 1.5,
    );
  }
  if (dark) {
    // 深色栏：库 ios27Dark 的 frost 云 + rim 配方，但填充换成黑 ≈22%——
    // frost 云把背后的封面 / 亮色内容平均成一层灰，再叠白色填充就成了灰白雾；
    // iOS 26 深色栏是把背后内容压暗，不是抬亮。上沿亮边 rimLight 稍收。
    return const LiquidGlassSettings(
      glassColor: Color(0x38000000),
      saturation: 1.3,
      blur: 0.6,
      blurWeight: 2.5,
      frost: 14,
      frostOpacity: 0.8,
      frostClamp: -0.45,
      frostWeight: 0.5,
      thickness: 32,
      refractiveIndex: 1.24,
      lensModel: GlassLensModel.paraxial,
      lightAngle: -1.5707963267948966,
      lightIntensity: 0,
      fresnelStrength: 0,
      chromaticAberration: 0,
      edgeAbsorption: 0.035,
      rimShade: 0.45,
      rimShadeEnds: 0,
      rimLight: 1.1,
      shadowElevation: 0,
    );
  }
  // 浅色栏：白 ≈45%（库 ios27Light 实测 53%，旧值 26% 压在封面上字发虚）+
  // frost 云 + 外圈 rimShade 暗边 + 双层投影，把栏从浅色内容上分离出来。
  return const LiquidGlassSettings(
    glassColor: Color(0x73F8F8F8),
    saturation: 2.1,
    blur: 0.6,
    blurWeight: 0.8,
    frost: 14,
    frostOpacity: 0.6,
    frostClamp: 0.4,
    frostWeight: 2.0,
    thickness: 32,
    refractiveIndex: 1.24,
    lensModel: GlassLensModel.paraxial,
    lightAngle: 1.5707963267948966,
    lightIntensity: 0,
    fresnelStrength: 0,
    chromaticAberration: 0,
    edgeAbsorption: 0.035,
    rimShade: 1,
    rimLight: 1,
    shadow: <BoxShadow>[
      BoxShadow(
        color: Color(0x0F000000),
        blurRadius: 2,
        offset: Offset(0, 0.5),
      ),
      BoxShadow(color: Color(0x1A000000), blurRadius: 20, offset: Offset(0, 6)),
    ],
  );
}

/// 桌面（Windows / macOS / Linux）用 macOS 26 的紧凑控件尺寸；移动端用
/// iOS 26 的 44pt 触控尺寸。按 [ThemeData.platform] 判（测试可覆盖）。
bool fushiAppleCompact(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// 玻璃按钮的共用渲染，形态对齐 iOS 26 的按钮样式（[GlassButton.custom]
/// 液态玻璃胶囊）：
/// - filled = `.glassProminent`：强调色着色的玻璃胶囊，onAccent 字 semibold；
/// - tonal / outlined = `.glass`：透明玻璃胶囊，label 色文字；
/// - text = 同样是 `.glass` 透明玻璃胶囊 + label 色字；只有内边距被调用方
///   压成 0 的内联链接是 `.plain` 无底强调色文字（见 [FushiPlainButton]）。
///   调用方给了实底背景色时按着色玻璃画。
///
/// 高度：移动端 44（Messages 的 Edit 胶囊）、桌面 34；圆角恒为全胶囊。
/// [style] 里能映射的字段（前景 / 背景色、内边距、最小 / 固定尺寸、字体）照用，
/// 其余忽略。
Widget _glassButton(
  BuildContext context, {
  required _FushiButtonKind kind,
  required VoidCallback? onPressed,
  required VoidCallback? onLongPress,
  required ValueChanged<bool>? onHover,
  required ValueChanged<bool>? onFocusChange,
  required ButtonStyle? style,
  required FocusNode? focusNode,
  required bool autofocus,
  required Widget? icon,
  required Widget? label,
  required IconAlignment? iconAlignment,
  bool destructive = false,
  bool overImage = false,
}) {
  final ThemeData theme = Theme.of(context);
  final FushiAppleColors apple = appleColorsOf(context);
  final bool compact = fushiAppleCompact(context);
  final bool enabled = onPressed != null || onLongPress != null;
  final Set<WidgetState> resolveStates = enabled
      ? const <WidgetState>{}
      : const <WidgetState>{WidgetState.disabled};

  final Color? styleBg = style?.backgroundColor?.resolve(resolveStates);
  final Color? styleFg = style?.foregroundColor?.resolve(resolveStates);
  final bool customBg = styleBg != null && styleBg.a > 0;
  final bool alertAction = FushiAlertActionScope.of(context);
  final bool sheetAction = FushiDialogActionScope.of(context);
  // 用户 2026-10-04 三次拍板：「很多按钮都不是玻璃胶囊」——文字按钮也是
  // `.glass` 透明玻璃胶囊（label 色字），只有正文里的内联链接（调用方把
  // 内边距压成 0 的那种）保持 `.plain` 纯强调色文字。
  final EdgeInsetsGeometry? stylePadding = style?.padding?.resolve(
    resolveStates,
  );
  final bool inlineLink = stylePadding != null && stylePadding.horizontal == 0;
  final bool plain =
      kind == _FushiButtonKind.text &&
      !customBg &&
      !alertAction &&
      !sheetAction &&
      inlineLink;

  GlassButtonStyle glassStyle = GlassButtonStyle.filled;
  Color? tint;
  Color fg;
  FontWeight weight = FontWeight.w500;
  switch (kind) {
    case _FushiButtonKind.filled:
      glassStyle = GlassButtonStyle.prominent;
      tint = apple.accent;
      fg = apple.onAccent;
      weight = FontWeight.w600;
    case _FushiButtonKind.tonal:
    case _FushiButtonKind.outlined:
      fg = apple.label;
    case _FushiButtonKind.text:
      // 玻璃胶囊里一律 label 色字；只有内联链接是强调色纯文字。
      fg = plain ? apple.accent : apple.label;
  }
  if (customBg) {
    tint = styleBg;
    if (kind == _FushiButtonKind.text) fg = Colors.white;
  }
  // 破坏性操作（删除 / 退出登录）：systemRed 字，胶囊仍是透明玻璃。
  if (destructive) fg = apple.destructive;
  // 压在图片 / hero 上的主按钮（Apple TV「播放」）：固定白底黑字的
  // prominent 玻璃——单色强调色在浅色下是黑胶囊，压在 hero 黑渐变上看不见。
  if (overImage && kind == _FushiButtonKind.filled) {
    tint = Colors.white;
    fg = Colors.black;
  }
  if (styleFg != null) fg = styleFg;
  if (!enabled) {
    // iOS 禁用态：主按钮褪成中性灰玻璃，文字一律 tertiaryLabel。
    fg = apple.tertiaryLabel;
    if (glassStyle == GlassButtonStyle.prominent) {
      glassStyle = GlassButtonStyle.filled;
      tint = null;
    }
  }

  final double height = alertAction ? (compact ? 36 : 48) : (compact ? 34 : 44);
  final EdgeInsetsGeometry padding =
      style?.padding?.resolve(resolveStates) ??
      EdgeInsets.symmetric(
        horizontal: plain ? (compact ? 8 : 10) : (compact ? 14 : 20),
      );
  final Size? minimumSize = style?.minimumSize?.resolve(resolveStates);
  final Size? fixedSize = style?.fixedSize?.resolve(resolveStates);

  final TextStyle textStyle = (theme.textTheme.labelLarge ?? const TextStyle())
      .copyWith(fontSize: compact ? 15 : 17, fontWeight: weight)
      .merge(style?.textStyle?.resolve(resolveStates))
      .copyWith(color: fg);
  Widget content;
  if (icon != null && label != null) {
    final bool trailing = iconAlignment == IconAlignment.end;
    final List<Widget> parts = <Widget>[
      icon,
      SizedBox(width: compact ? 5 : 6),
      Flexible(child: label),
    ];
    content = Row(
      mainAxisSize: MainAxisSize.min,
      children: trailing ? parts.reversed.toList() : parts,
    );
  } else {
    content = label ?? icon ?? const SizedBox.shrink();
  }
  content = IconTheme.merge(
    data: IconThemeData(color: fg, size: compact ? 16 : 19),
    child: DefaultTextStyle.merge(
      style: textStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: Padding(padding: padding, child: content),
    ),
  );
  final double minHeight =
      fixedSize?.height ??
      (minimumSize != null && minimumSize.height > 0
          ? minimumSize.height
          : (plain ? (compact ? 28 : 44) : height));
  content = ConstrainedBox(
    constraints: BoxConstraints(
      minWidth: fixedSize?.width ?? minimumSize?.width ?? (plain ? 0 : height),
      minHeight: alertAction ? height : minHeight,
    ),
    child: Center(widthFactor: 1, heightFactor: 1, child: content),
  );

  if (plain) {
    return FushiPlainButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      onHover: onHover,
      onFocusChange: onFocusChange,
      focusNode: focusNode,
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(minHeight / 2),
      child: content,
    );
  }

  // 液态玻璃胶囊（用户 2026-10-04 二次拍板：「所有组件都要往液态玻璃靠」，
  // 撤回同日早些时候的实色胶囊）：filled = `.glassProminent` 强调色着色玻璃，
  // tonal / outlined（以及 alert / sheet 动作区里的取消类）= `.glass` 透明
  // 玻璃。按压 / 拉伸 / 高光由库的 GlassButton 自己做；焦点环 + Enter →
  // ActivateIntent 由它内置的 GlassFocusRegion 接上。内容区多是平底，按钮
  // 各自 useOwnLayer 取背景折射。
  // 已经浮在另一枚玻璃面（批量操作栏、迷你条、悬浮工具条）里时不再另起
  // 一层折射：交给库的嵌套 vibrancy 路径（半透明着色 + 高光边，iOS 26 玻璃
  // 工具条里的按钮就是这样），避免玻璃套玻璃的双重模糊。
  final bool nested =
      context
          .dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>()
          ?.avoidsRefraction ??
      false;
  final bool dark = theme.colorScheme.brightness == Brightness.dark;
  Widget button = GlassButton.custom(
    onTap: onPressed ?? () {},
    enabled: enabled,
    style: glassStyle,
    // 只有主按钮（及调用方着色）是有色玻璃；其余一律无色透明玻璃。
    settings: enabled && tint != null
        ? fushiGlassSettings(context, tint: tint)
        : fushiClearGlassSettings(context),
    quality: fushiGlassQuality(context),
    useOwnLayer: !nested,
    // Messages「Edit」胶囊同参：按下拖出按钮外仍保持按压态，浅色按压有
    // 均匀提亮、深色只靠高光。
    persistPressOnDrag: true,
    ambientBaseLight: dark ? 0.0 : 0.25,
    shape: LiquidRoundedSuperellipse(
      borderRadius: (fixedSize?.height ?? minHeight) / 2,
    ),
    focusNode: focusNode,
    autofocus: autofocus,
    child: content,
  );
  if (onLongPress != null) {
    button = GestureDetector(onLongPress: onLongPress, child: button);
  }
  if (onHover != null) {
    button = MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: button,
    );
  }
  if (onFocusChange != null) {
    button = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: onFocusChange,
      child: button,
    );
  }
  return button;
}

/// MD3 破坏性按钮：error 色前景（描边按钮连描边一起），调用方 style 里显式
/// 给了的前景 / 描边优先；禁用态交回按钮默认。
ButtonStyle _md3DestructiveStyle(
  BuildContext context,
  ButtonStyle? style, {
  required bool outlined,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final ButtonStyle base = style ?? const ButtonStyle();
  return base.copyWith(
    foregroundColor:
        base.foregroundColor ??
        WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) =>
              states.contains(WidgetState.disabled) ? null : cs.error,
        ),
    side: outlined
        ? (base.side ??
              WidgetStateProperty.resolveWith<BorderSide?>(
                (Set<WidgetState> states) =>
                    states.contains(WidgetState.disabled)
                    ? null
                    : BorderSide(color: cs.error),
              ))
        : base.side,
  );
}

/// iOS 的 `.plain` / `.borderless` 按钮：无底、无玻璃，按下整体变淡
/// （UIButton highlighted 的 alpha），桌面悬停给一层 tertiaryFill 底
/// （macOS 无边框工具栏按钮的 hover）。键盘 / 手柄可达：自带焦点节点，
/// [ActivateIntent]（Enter / 手柄 A）触发 [onPressed]，键盘焦点时画一圈强调色
/// 焦点环。
class FushiPlainButton extends StatefulWidget {
  const FushiPlainButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.focusNode,
    this.autofocus = false,
    required this.borderRadius,
    required this.child,
    this.semanticLabel,
    this.fill,
  });

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final bool autofocus;
  final BorderRadius borderRadius;
  final String? semanticLabel;
  final Widget child;

  /// 实色按钮底（iOS `.bordered` / `.borderedProminent`）；null = plain 无底。
  /// 有底时悬停 / 按下在底色上叠一层前景色，不再整体变淡。
  final Color? fill;

  @override
  State<FushiPlainButton> createState() => _FushiPlainButtonState();
}

class _FushiPlainButtonState extends State<FushiPlainButton> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focusHighlight = false;

  bool get _enabled => widget.onPressed != null || widget.onLongPress != null;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool enabled = _enabled;
    final Color? fill = widget.fill;
    Widget body = AnimatedOpacity(
      // 按下立即变淡、松手缓回，与 UIKit 高亮的节奏一致。
      duration: _pressed ? Duration.zero : const Duration(milliseconds: 180),
      opacity: _pressed ? (fill == null ? 0.3 : 0.85) : 1,
      child: widget.child,
    );
    final Color overlay = appleOnAccent(fill ?? apple.groupedBackground);
    body = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: fill != null
            ? Color.alphaBlend(
                overlay.withValues(
                  alpha: !enabled
                      ? 0
                      : (_pressed ? 0.16 : (_hovered ? 0.08 : 0)),
                ),
                fill,
              )
            : (enabled && _hovered && !_pressed
                  ? apple.tertiaryFill
                  : Colors.transparent),
        borderRadius: widget.borderRadius,
        border: _focusHighlight
            ? Border.all(color: apple.accent, width: 2)
            : null,
      ),
      child: body,
    );
    return FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      onShowHoverHighlight: (bool value) {
        setState(() => _hovered = value);
        widget.onHover?.call(value);
      },
      onShowFocusHighlight: (bool value) {
        setState(() => _focusHighlight = value);
      },
      onFocusChange: widget.onFocusChange,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => _setPressed(true) : null,
          onTapUp: enabled ? (_) => _setPressed(false) : null,
          onTapCancel: enabled ? () => _setPressed(false) : null,
          onTap: widget.onPressed,
          onLongPress: widget.onLongPress,
          child: body,
        ),
      ),
    );
  }
}

/// MD3 按钮族的 M3 Expressive 形变包装：尺寸档 / 形状参数折算成
/// [FushiPressMorph] 的样式与圆角（见 fushi_expressive_controls.dart）。
/// 两者都是默认值（size == null、圆形）时与改造前逐像素一致。
Widget _md3MorphButton(
  BuildContext context, {
  required FushiButtonSize? size,
  required FushiButtonShape shape,
  required bool outlined,
  required bool enabled,
  required ButtonStyle? style,
  required WidgetStatesController? statesController,
  required FushiPressMorphBuilder builder,
}) {
  if (size == null && shape == FushiButtonShape.round) {
    return FushiPressMorph(
      enabled: enabled,
      style: style,
      statesController: statesController,
      builder: builder,
    );
  }
  final FushiButtonSize effective = size ?? FushiButtonSize.s;
  ButtonStyle? merged = style;
  if (size != null) {
    final ButtonStyle sized = fushiButtonSizeStyle(
      context,
      size,
      outlined: outlined,
    );
    merged = style?.merge(sized) ?? sized;
  }
  final ({double pressedRadius, bool squared, double squareRadius}) spec =
      fushiButtonMorphSpec(effective, shape);
  return FushiPressMorph(
    enabled: enabled,
    style: merged,
    statesController: statesController,
    pressedRadius: spec.pressedRadius,
    selected: spec.squared,
    selectedRadius: spec.squareRadius,
    builder:
        (
          BuildContext context,
          ButtonStyle? morphStyle,
          WidgetStatesController? controller,
        ) => builder(
          context,
          fushiStaticSquareShape(
            morphStyle,
            squared: spec.squared && !fushiExpressiveMotionEnabled(context),
            radius: spec.squareRadius,
          ),
          controller,
        ),
  );
}

/// [TextButton] 的设计系统分派版。
class FushiTextButton extends StatelessWidget {
  const FushiTextButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.destructive = false,
    this.isSemanticButton = true,
    required this.child,
  }) : icon = null,
       label = null,
       iconAlignment = null,
       _withIcon = false;

  const FushiTextButton.icon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.destructive = false,
    this.icon,
    required this.label,
    this.iconAlignment,
  }) : child = null,
       isSemanticButton = true,
       _withIcon = true;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip? clipBehavior;
  final WidgetStatesController? statesController;

  /// M3 Expressive 尺寸档（XS 32 / S 40 / M 56 / L 96 / XL 136，只影响 MD3）。
  /// null = 主题默认（40 高胶囊，与改造前一致）。
  final FushiButtonSize? size;

  /// M3 Expressive 形状（只影响 MD3）：方形 = 按尺寸档常驻圆角矩形。
  final FushiButtonShape shape;
  final bool? isSemanticButton;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final IconAlignment? iconAlignment;
  final bool _withIcon;

  /// 破坏性操作（删除 / 退出登录）：MD3 error 色字，Apple systemRed 字。
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _glassButton(
        context,
        kind: _FushiButtonKind.text,
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        icon: icon,
        label: _withIcon ? label : child,
        iconAlignment: iconAlignment,
        destructive: destructive,
      );
    }
    // MD3：M3 Expressive 按压变形（胶囊 → 圆角 10，见 [FushiPressMorph]）。
    return _md3MorphButton(
      context,
      size: size,
      shape: shape,
      outlined: false,
      enabled: onPressed != null || onLongPress != null,
      style: destructive
          ? _md3DestructiveStyle(context, style, outlined: false)
          : style,
      statesController: statesController,
      builder:
          (
            BuildContext context,
            ButtonStyle? morphStyle,
            WidgetStatesController? morphController,
          ) {
            if (_withIcon) {
              return TextButton.icon(
                onPressed: onPressed,
                onLongPress: onLongPress,
                onHover: onHover,
                onFocusChange: onFocusChange,
                style: morphStyle,
                focusNode: focusNode,
                autofocus: autofocus,
                clipBehavior: clipBehavior,
                statesController: morphController,
                icon: icon,
                label: label!,
                iconAlignment: iconAlignment,
              );
            }
            return TextButton(
              onPressed: onPressed,
              onLongPress: onLongPress,
              onHover: onHover,
              onFocusChange: onFocusChange,
              style: morphStyle,
              focusNode: focusNode,
              autofocus: autofocus,
              clipBehavior: clipBehavior ?? Clip.none,
              statesController: morphController,
              isSemanticButton: isSemanticButton,
              child: child!,
            );
          },
    );
  }
}

enum _FilledVariant { filled, tonal }

/// [FilledButton] 的设计系统分派版（含 `.icon` / `.tonal` / `.tonalIcon`）。
class FushiFilledButton extends StatelessWidget {
  const FushiFilledButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.overImage = false,
    required this.child,
  }) : icon = null,
       label = null,
       iconAlignment = null,
       _withIcon = false,
       _variant = _FilledVariant.filled;

  const FushiFilledButton.icon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.overImage = false,
    this.icon,
    required this.label,
    this.iconAlignment,
  }) : child = null,
       _withIcon = true,
       _variant = _FilledVariant.filled;

  const FushiFilledButton.tonal({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.overImage = false,
    required this.child,
  }) : icon = null,
       label = null,
       iconAlignment = null,
       _withIcon = false,
       _variant = _FilledVariant.tonal;

  const FushiFilledButton.tonalIcon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior = Clip.none,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.overImage = false,
    required Widget this.icon,
    required this.label,
    this.iconAlignment,
  }) : child = null,
       _withIcon = true,
       _variant = _FilledVariant.tonal;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip clipBehavior;
  final WidgetStatesController? statesController;

  /// M3 Expressive 尺寸档（XS 32 / S 40 / M 56 / L 96 / XL 136，只影响 MD3）。
  /// null = 主题默认（40 高胶囊，与改造前一致）。
  final FushiButtonSize? size;

  /// M3 Expressive 形状（只影响 MD3）：方形 = 按尺寸档常驻圆角矩形。
  final FushiButtonShape shape;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final IconAlignment? iconAlignment;
  final bool _withIcon;

  /// 压在图片 / hero 上的主按钮（Apple TV 播放钮）：Apple 下固定白底黑字的
  /// 玻璃胶囊；MD3 不变。
  final bool overImage;
  final _FilledVariant _variant;

  @override
  Widget build(BuildContext context) {
    final bool tonal = _variant == _FilledVariant.tonal;
    if (isGlassDesign(context)) {
      return _glassButton(
        context,
        kind: tonal ? _FushiButtonKind.tonal : _FushiButtonKind.filled,
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        icon: icon,
        label: _withIcon ? label : child,
        iconAlignment: iconAlignment,
        overImage: overImage,
      );
    }
    // MD3：M3 Expressive 按压变形（胶囊 → 圆角 10，见 [FushiPressMorph]）。
    return _md3MorphButton(
      context,
      size: size,
      shape: shape,
      outlined: false,
      enabled: onPressed != null || onLongPress != null,
      style: style,
      statesController: statesController,
      builder:
          (
            BuildContext context,
            ButtonStyle? morphStyle,
            WidgetStatesController? morphController,
          ) => _buildMaterial(tonal, morphStyle, morphController),
    );
  }

  Widget _buildMaterial(
    bool tonal,
    ButtonStyle? style,
    WidgetStatesController? statesController,
  ) {
    if (_withIcon) {
      return tonal
          ? FilledButton.tonalIcon(
              onPressed: onPressed,
              onLongPress: onLongPress,
              onHover: onHover,
              onFocusChange: onFocusChange,
              style: style,
              focusNode: focusNode,
              autofocus: autofocus,
              clipBehavior: clipBehavior,
              statesController: statesController,
              icon: icon!,
              label: label!,
              iconAlignment: iconAlignment,
            )
          : FilledButton.icon(
              onPressed: onPressed,
              onLongPress: onLongPress,
              onHover: onHover,
              onFocusChange: onFocusChange,
              style: style,
              focusNode: focusNode,
              autofocus: autofocus,
              clipBehavior: clipBehavior,
              statesController: statesController,
              icon: icon,
              label: label!,
              iconAlignment: iconAlignment,
            );
    }
    return tonal
        ? FilledButton.tonal(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: statesController,
            child: child,
          )
        : FilledButton(
            onPressed: onPressed,
            onLongPress: onLongPress,
            onHover: onHover,
            onFocusChange: onFocusChange,
            style: style,
            focusNode: focusNode,
            autofocus: autofocus,
            clipBehavior: clipBehavior,
            statesController: statesController,
            child: child,
          );
  }
}

/// 菜单触发器声明自己的可视形状（`FushiPopupMenuButton` / `FushiOverflowMenu`
/// 的 `child` 实现它）。MD3 下状态层（悬停 / 按压 / 焦点，含涟漪）按这个形状
/// 裁剪并叠在触发器之上，与可视胶囊同尺寸同圆角。实现方的布局边界必须就是
/// 可视形状本身（chip / 按钮作触发器时用 `MaterialTapTargetSize.shrinkWrap`，
/// 不留 48dp 点击区外边距）。
abstract interface class FushiShapedMenuTrigger {
  ShapeBorder menuTriggerShape(BuildContext context);
}

/// 按钮作菜单触发器（`onPressed: null`、点击交给外层菜单）时的 style：去掉
/// 48dp 点击区外边距，让布局边界 = 可视胶囊（见 [FushiShapedMenuTrigger]）。
const ButtonStyle kFushiMenuTriggerButtonStyle = ButtonStyle(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// [OutlinedButton] 的设计系统分派版（含 `.icon`）。
class FushiOutlinedButton extends StatelessWidget
    implements FushiShapedMenuTrigger {
  const FushiOutlinedButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.destructive = false,
    required this.child,
  }) : icon = null,
       label = null,
       iconAlignment = null,
       _withIcon = false;

  const FushiOutlinedButton.icon({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.onHover,
    this.onFocusChange,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.clipBehavior,
    this.statesController,
    this.size,
    this.shape = FushiButtonShape.round,
    this.destructive = false,
    this.icon,
    required this.label,
    this.iconAlignment,
  }) : child = null,
       _withIcon = true;

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onFocusChange;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus;
  final Clip? clipBehavior;
  final WidgetStatesController? statesController;

  /// M3 Expressive 尺寸档（XS 32 / S 40 / M 56 / L 96 / XL 136，只影响 MD3）。
  /// null = 主题默认（40 高胶囊，与改造前一致）。
  final FushiButtonSize? size;

  /// M3 Expressive 形状（只影响 MD3）：方形 = 按尺寸档常驻圆角矩形。
  final FushiButtonShape shape;
  final Widget? child;
  final Widget? icon;
  final Widget? label;
  final IconAlignment? iconAlignment;
  final bool _withIcon;

  /// 破坏性操作（删除 / 退出登录）：MD3 error 色字与描边，Apple systemRed 字。
  final bool destructive;

  /// 作菜单触发器（onPressed 为 null、点击交给外层菜单）时的可视形状：
  /// [style] / 主题给的 shape，缺省 MD3 胶囊。
  @override
  ShapeBorder menuTriggerShape(BuildContext context) =>
      style?.shape?.resolve(const <WidgetState>{}) ??
      OutlinedButtonTheme.of(
        context,
      ).style?.shape?.resolve(const <WidgetState>{}) ??
      const StadiumBorder();

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _glassButton(
        context,
        kind: _FushiButtonKind.outlined,
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: onFocusChange,
        style: style,
        focusNode: focusNode,
        autofocus: autofocus,
        icon: icon,
        label: _withIcon ? label : child,
        iconAlignment: iconAlignment,
        destructive: destructive,
      );
    }
    // MD3：M3 Expressive 按压变形（胶囊 → 圆角 10，见 [FushiPressMorph]）。
    return _md3MorphButton(
      context,
      size: size,
      shape: shape,
      outlined: true,
      enabled: onPressed != null || onLongPress != null,
      style: destructive
          ? _md3DestructiveStyle(context, style, outlined: true)
          : style,
      statesController: statesController,
      builder:
          (
            BuildContext context,
            ButtonStyle? morphStyle,
            WidgetStatesController? morphController,
          ) {
            if (_withIcon) {
              return OutlinedButton.icon(
                onPressed: onPressed,
                onLongPress: onLongPress,
                onHover: onHover,
                onFocusChange: onFocusChange,
                style: morphStyle,
                focusNode: focusNode,
                autofocus: autofocus,
                clipBehavior: clipBehavior,
                statesController: morphController,
                icon: icon,
                label: label!,
                iconAlignment: iconAlignment,
              );
            }
            return OutlinedButton(
              onPressed: onPressed,
              onLongPress: onLongPress,
              onHover: onHover,
              onFocusChange: onFocusChange,
              style: morphStyle,
              focusNode: focusNode,
              autofocus: autofocus,
              clipBehavior: clipBehavior ?? Clip.none,
              statesController: morphController,
              child: child,
            );
          },
    );
  }
}

enum _IconButtonVariant { standard, filled, filledTonal, outlined }

/// [IconButton] 的设计系统分派版（含 `.filled` / `.filledTonal` / `.outlined`）。
class FushiIconButtonControl extends StatelessWidget {
  const FushiIconButtonControl({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    this.size,
    this.width = FushiIconButtonWidth.standard,
    this.shape = FushiIconButtonShape.round,
    required this.icon,
  }) : _variant = _IconButtonVariant.standard;

  const FushiIconButtonControl.filled({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    this.size,
    this.width = FushiIconButtonWidth.standard,
    this.shape = FushiIconButtonShape.round,
    required this.icon,
  }) : _variant = _IconButtonVariant.filled;

  const FushiIconButtonControl.filledTonal({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    this.size,
    this.width = FushiIconButtonWidth.standard,
    this.shape = FushiIconButtonShape.round,
    required this.icon,
  }) : _variant = _IconButtonVariant.filledTonal;

  const FushiIconButtonControl.outlined({
    super.key,
    this.iconSize,
    this.visualDensity,
    this.padding,
    this.alignment,
    this.splashRadius,
    this.color,
    this.focusColor,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.disabledColor,
    required this.onPressed,
    this.onHover,
    this.onLongPress,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
    this.enableFeedback,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    this.size,
    this.width = FushiIconButtonWidth.standard,
    this.shape = FushiIconButtonShape.round,
    required this.icon,
  }) : _variant = _IconButtonVariant.outlined;

  final double? iconSize;
  final VisualDensity? visualDensity;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final double? splashRadius;
  final Color? color;
  final Color? focusColor;
  final Color? hoverColor;
  final Color? highlightColor;
  final Color? splashColor;
  final Color? disabledColor;
  final VoidCallback? onPressed;
  final ValueChanged<bool>? onHover;
  final VoidCallback? onLongPress;
  final MouseCursor? mouseCursor;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? tooltip;
  final bool? enableFeedback;
  final BoxConstraints? constraints;
  final ButtonStyle? style;
  final bool? isSelected;
  final Widget? selectedIcon;
  final Widget icon;
  final _IconButtonVariant _variant;

  /// M3 Expressive 尺寸档（只影响 MD3）。null = 按 [visualDensity] 推：
  /// compact → XS 32，其余 → S 40。
  final FushiIconButtonSize? size;

  /// 实际尺寸档：显式 [size]，否则 compact 密度 → XS，其余 → S。
  FushiIconButtonSize get _effectiveSize =>
      size ??
      (visualDensity == VisualDensity.compact
          ? FushiIconButtonSize.xs
          : FushiIconButtonSize.s);

  /// M3 Expressive 宽度变体（只影响 MD3）。
  final FushiIconButtonWidth width;

  /// M3 Expressive 形状（只影响 MD3）：方形 = 常驻圆角 12。
  final FushiIconButtonShape shape;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    // MD3 = M3 Expressive 图标按钮：尺寸档 / 宽度 / 形状 + 变体配色（见
    // [_expressiveDefaults]），按压变形圆 → 圆角 12；toggle 选中态与方形按钮
    // 常驻圆角 12、按下收到 8。IconButton 不暴露 statesController，按指针判按下。
    // 墨水屏不套 Expressive 配色（那套方案的容器色塌成页面底色），保持原件。
    final bool square = shape == FushiIconButtonShape.square;
    final bool selected = isSelected ?? false;
    final bool einkMode = isEinkTheme(context);
    final ButtonStyle? base = einkMode
        ? style
        : (style?.merge(_expressiveDefaults(context)) ??
              _expressiveDefaults(context));
    // 圆角按尺寸档（XS / S 12→8、M 16→12、L / XL 28→16）；圆形未选按下收到
    // 方形圆角，方形 / 选中按下再收到 pressed 圆角。
    final ({double square, double pressed}) radii =
        fushiExpressiveIconButtonRadii(_effectiveSize);
    return FushiPressMorph(
      enabled: onPressed != null || onLongPress != null,
      style: base,
      trackPointer: true,
      pressedRadius: (square || selected) ? radii.pressed : radii.square,
      selected: selected || square,
      selectedRadius: radii.square,
      builder:
          (
            BuildContext context,
            ButtonStyle? morphStyle,
            WidgetStatesController? _,
          ) {
            ButtonStyle? effective = morphStyle;
            // 不做动效（减少动画）时形变包装原样透传：方形 / 选中态仍要静态方圆角。
            if (!einkMode && effective?.shape == null && (square || selected)) {
              effective = (effective ?? const ButtonStyle()).copyWith(
                shape: WidgetStatePropertyAll<OutlinedBorder>(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(radii.square),
                    ),
                  ),
                ),
              );
            }
            return _buildMaterial(effective);
          },
    );
  }

  /// M3 Expressive 图标按钮默认样式（合并在调用方 style **之下**）。调用方
  /// 显式给了的 IconButton 参数（color / iconSize / padding / constraints /
  /// 各状态色）对应的字段不填，交回 IconButton 自己的合并逻辑。
  ///
  /// 配色：standard 无底 onSurfaceVariant；filled primary + onPrimary；
  /// filledTonal secondaryContainer + onSecondaryContainer；outlined 1px
  /// outlineVariant 描边。toggle（isSelected 非 null）未选时 filled / tonal 退成
  /// surfaceContainer + onSurfaceVariant，选中时上填充色（standard 选中
  /// secondaryContainer、outlined 选中 inverseSurface）。
  ButtonStyle _expressiveDefaults(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiIconButtonSize effectiveSize = _effectiveSize;
    final Size extent = fushiExpressiveIconButtonExtent(effectiveSize, width);
    final bool toggle = isSelected != null;

    (Color?, Color) colorsFor(Set<WidgetState> states) {
      final bool on = states.contains(WidgetState.selected);
      if (states.contains(WidgetState.disabled)) {
        final Color fg = cs.onSurface.withValues(alpha: 0.38);
        return switch (_variant) {
          _IconButtonVariant.standard ||
          _IconButtonVariant.outlined => (null, fg),
          _ => (cs.onSurface.withValues(alpha: 0.12), fg),
        };
      }
      switch (_variant) {
        case _IconButtonVariant.standard:
          return on
              ? (cs.secondaryContainer, cs.onSecondaryContainer)
              : (null, cs.onSurfaceVariant);
        case _IconButtonVariant.filled:
          return (toggle && !on)
              ? (cs.surfaceContainer, cs.onSurfaceVariant)
              : (cs.primary, cs.onPrimary);
        case _IconButtonVariant.filledTonal:
          return (toggle && !on)
              ? (cs.surfaceContainer, cs.onSurfaceVariant)
              : (cs.secondaryContainer, cs.onSecondaryContainer);
        case _IconButtonVariant.outlined:
          return on
              ? (cs.inverseSurface, cs.onInverseSurface)
              : (null, cs.onSurfaceVariant);
      }
    }

    final bool customOverlay =
        focusColor != null ||
        hoverColor != null ||
        highlightColor != null ||
        splashColor != null;
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => colorsFor(states).$1,
      ),
      foregroundColor: color != null || disabledColor != null
          ? null
          : WidgetStateProperty.resolveWith<Color?>(
              (Set<WidgetState> states) => colorsFor(states).$2,
            ),
      overlayColor: customOverlay
          ? null
          : WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
              final Color fg = colorsFor(states).$2;
              if (states.contains(WidgetState.pressed)) {
                return fg.withValues(alpha: 0.1);
              }
              if (states.contains(WidgetState.hovered)) {
                return fg.withValues(alpha: 0.08);
              }
              if (states.contains(WidgetState.focused)) {
                return fg.withValues(alpha: 0.1);
              }
              return null;
            }),
      side: _variant == _IconButtonVariant.outlined
          ? WidgetStateProperty.resolveWith<BorderSide?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.selected)) return BorderSide.none;
              return BorderSide(
                color: states.contains(WidgetState.disabled)
                    ? cs.onSurface.withValues(alpha: 0.12)
                    : cs.outlineVariant,
              );
            })
          : null,
      iconSize: iconSize != null
          ? null
          : WidgetStatePropertyAll<double>(
              fushiExpressiveIconSize(effectiveSize),
            ),
      padding: padding != null
          ? null
          : const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
      minimumSize: constraints != null
          ? null
          : WidgetStatePropertyAll<Size>(extent),
      maximumSize: constraints != null
          ? null
          : WidgetStatePropertyAll<Size>(extent),
      // 尺寸档已经把 compact 解释成 XS；不再让 VisualDensity 二次缩小。
      visualDensity: constraints != null ? null : VisualDensity.standard,
    );
  }

  Widget _buildMaterial(ButtonStyle? style) {
    switch (_variant) {
      case _IconButtonVariant.standard:
        return IconButton(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
      case _IconButtonVariant.filled:
        return IconButton.filled(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
      case _IconButtonVariant.filledTonal:
        return IconButton.filledTonal(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
      case _IconButtonVariant.outlined:
        return IconButton.outlined(
          iconSize: iconSize,
          visualDensity: visualDensity,
          padding: padding,
          alignment: alignment,
          splashRadius: splashRadius,
          color: color,
          focusColor: focusColor,
          hoverColor: hoverColor,
          highlightColor: highlightColor,
          splashColor: splashColor,
          disabledColor: disabledColor,
          onPressed: onPressed,
          onHover: onHover,
          onLongPress: onLongPress,
          mouseCursor: mouseCursor,
          focusNode: focusNode,
          autofocus: autofocus,
          tooltip: tooltip,
          enableFeedback: enableFeedback,
          constraints: constraints,
          style: style,
          isSelected: isSelected,
          selectedIcon: selectedIcon,
          icon: icon,
        );
    }
  }

  /// iOS 26 图标按钮：
  /// - 默认（[IconButton]）= `.plain`，无底 label 色图标，44 / 36 的触控区，
  ///   按下变淡——**不是玻璃**；选中（toggle）时是更亮的透明玻璃圆钮；
  /// - `.filled` = 强调色着色玻璃圆钮（`.glassProminent`），onAccent 图标；
  /// - `.filledTonal` / `.outlined` = 无色透明玻璃圆钮（`.glass`，Messages /
  ///   Niratan 顶栏那颗圆钮：只有高光边，无灰底），label 色图标。
  Widget _buildGlass(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final bool selected = isSelected ?? false;
    final bool enabled = onPressed != null || onLongPress != null;
    final Set<WidgetState> states = <WidgetState>{
      if (!enabled) WidgetState.disabled,
      if (selected) WidgetState.selected,
    };
    final Color? styleFg = style?.foregroundColor?.resolve(states);
    final Color? styleBg = style?.backgroundColor?.resolve(states);
    // 非 standard 变体、toggle 选中态、调用方给了底色时画玻璃圆钮；其余无底。
    final bool raised =
        _variant != _IconButtonVariant.standard ||
        selected ||
        (styleBg != null && styleBg.a > 0);
    // 只有 `.filled` 是强调色玻璃；toggle 选中态是「更亮一点的透明玻璃」
    // （Niratan / macOS 26 工具栏：选中不铺强调色），图标仍 label 色。
    // `.filled` 的 toggle 未选中时与 MD3 一样退成中性（这里 = 透明玻璃）。
    final bool prominent =
        _variant == _IconButtonVariant.filled && (isSelected ?? true);
    final Color fg = !enabled
        ? (disabledColor ?? apple.tertiaryLabel)
        : (styleFg ?? color ?? (prominent ? apple.onAccent : apple.label));
    final Color? tint = (styleBg != null && styleBg.a > 0)
        ? styleBg
        : (prominent && enabled ? apple.accent : null);
    final double effectiveIconSize =
        iconSize ?? style?.iconSize?.resolve(states) ?? (compact ? 18 : 20);
    final double defaultExtent = compact ? 36 : 44;
    final double extent =
        constraints?.minWidth != null && constraints!.minWidth > 0
        ? constraints!.minWidth
        : (visualDensity == VisualDensity.compact
              ? defaultExtent - 8
              : defaultExtent);
    final Widget glyph = IconTheme.merge(
      data: IconThemeData(color: fg, size: effectiveIconSize),
      child: selected && selectedIcon != null ? selectedIcon! : icon,
    );

    Widget button;
    if (!raised) {
      button = FushiPlainButton(
        onPressed: onPressed,
        onLongPress: onLongPress,
        onHover: onHover,
        onFocusChange: null,
        focusNode: focusNode,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(extent / 2),
        semanticLabel: tooltip,
        child: SizedBox(
          width: extent,
          height: extent,
          child: Center(child: glyph),
        ),
      );
    } else {
      button = GlassButton.custom(
        onTap: onPressed ?? () {},
        enabled: enabled,
        style: tint != null
            ? GlassButtonStyle.prominent
            : GlassButtonStyle.filled,
        settings: tint != null
            ? fushiGlassSettings(context, tint: tint)
            : fushiClearGlassSettings(context, lighter: selected),
        quality: fushiGlassQuality(context),
        // 浮在别的玻璃面里时走库的嵌套 vibrancy（见 [_glassButton]）。
        useOwnLayer:
            !(context
                    .dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>()
                    ?.avoidsRefraction ??
                false),
        persistPressOnDrag: true,
        ambientBaseLight:
            Theme.of(context).colorScheme.brightness == Brightness.dark
            ? 0.0
            : 0.25,
        shape: const LiquidOval(),
        width: extent,
        height: extent,
        focusNode: focusNode,
        autofocus: autofocus,
        label: tooltip ?? '',
        child: glyph,
      );
      if (onLongPress != null) {
        button = GestureDetector(onLongPress: onLongPress, child: button);
      }
      if (onHover != null) {
        button = MouseRegion(
          onEnter: (_) => onHover!(true),
          onExit: (_) => onHover!(false),
          child: button,
        );
      }
    }
    if (tooltip != null && tooltip!.isNotEmpty) {
      button = Tooltip(message: tooltip, child: button);
    }
    return button;
  }
}
