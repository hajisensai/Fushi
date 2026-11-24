import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// 输入框族的「设计系统分派」包装：构造参数与 Material 原控件逐个同名同型，
// 调用点只改类名。MD3 设计系统下原样构造 [TextField] / [TextFormField]（像素、
// 焦点、语义一字不差）；「玻璃」设计系统下渲染 iOS 26 的实色输入框。
//
// 命名：仓库已有共享组件 `FushiTextField`（fushi_material_components.dart），
// 所以这里的包装叫 [FushiTextFieldControl] / [FushiTextFormFieldControl]。
//
// 玻璃设计系统下输入框是**内容层控件，不是玻璃**（Apple 26：玻璃只给浮在
// 内容上的导航与控件层）：tertiarySystemFill 实色底 + 圆角 10，搜索框（前缀是
// 放大镜）是高 36 的全胶囊；无下划线、无描边，聚焦只有一圈极淡的强调色光圈。
// 壳内是无边框 [CupertinoTextField]，文本编辑参数逐个转发（库的 GlassTextField
// 只暴露十几个参数，套上去等于静默丢行为）；InputDecoration 的 label / hint /
// prefix / suffix / helper / error / counter 映射到壳内外。
//
// 唯一的例外：`hintLocales`（查词输入框给 IME 的语言提示）、
// `onAppPrivateCommand`、`onTapUpOutside` 只有 Material [TextField] 能转发给
// EditableText，CupertinoTextField 没有（或类型不对）——带了它们时内层改用无装饰的 TextField
// （decoration: null，没有任何 MD3 视觉，只剩光标和文字），保住输入法行为。

/// 与 Material [TextField] 默认值同一实现（Material 的是私有静态方法，无法直接
/// 引用）。玻璃形态遇到这个默认值时换成 Cupertino 自适应工具条。
Widget _fushiDefaultContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return AdaptiveTextSelectionToolbar.editableText(
    editableTextState: editableTextState,
  );
}

/// 设计系统默认的文本框长按 / 右键菜单（Apple 设计系统下自动换成 Cupertino 菜单）。
/// 包装组件「没给自定义菜单」时传它，而不是传 null（null = 不要菜单）。
const EditableTextContextMenuBuilder fushiDefaultTextContextMenuBuilder =
    _fushiDefaultContextMenuBuilder;

Widget _cupertinoContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return CupertinoAdaptiveTextSelectionToolbar.editableText(
    editableTextState: editableTextState,
  );
}

/// 输入框正文 / 占位符的样式收口：行距**上下均分**（[TextLeadingDistribution.even]）。
///
/// 字阶给的行高（M3E bodyLarge 24/16 = 1.5、Apple 单行 1.25）比字体自身的
/// ascent + descent 高，多出来的行距 Flutter 默认按字体 ascent : descent 的比例
/// 分（proportional）。界面字体的 ascent 远大于 descent（Segoe UI 1.08 : 0.25、
/// 微软雅黑 1.06 : 0.26、测试字体 0.75 : 0.25），多出的行距几乎全加在字形上方：
/// 行盒在框里是居中的，字形却落在行盒中线下方（16 号、1.5 倍行高低约 2px），
/// 正文与占位符看上去都偏下（用户 2026-11-24「输入框、搜索框的文字都没有上下
/// 居中」）。均分后行盒中线就是字体 ascent / descent 盒的中线。只改行距在行盒内
/// 的分配，行盒高度（即框高、内边距）不变，M3E 与 Apple 的外观规格不受影响。
///
/// 同时把对齐基线钉成 [TextBaseline.alphabetic]：中日韩 locale 的主题字阶是
/// `Typography.dense`，自带 `textBaseline: ideographic`。输入框把占位符按基线
/// 对齐到编辑区（CupertinoTextField 的 `_RenderBaselineAlignedStack`、Material
/// InputDecorator 同理），而 [RenderEditable] 按样式要的 ideographic 基线报，
/// [RenderParagraph]（占位符）不论要哪种都只报 alphabetic（框架 TODO，见
/// `RenderParagraph.computeDistanceToActualBaseline`）——两者差一个 descent
/// （约 0.19em，17 号低约 3px），中文界面下占位符整体下沉、看着不居中（用户
/// 2026-11-24「这个字还是没有上下居中」）。两边都按 alphabetic 对齐就重合了；
/// 基线种类只影响对齐、不影响字形绘制。
///
/// 调用方给的样式（常是 inherit: false 的主题样式）原样保留，只覆盖行距分配与
/// 对齐基线；[WidgetStateTextStyle] 原样返回（copyWith 会丢掉它的状态解析）。
TextStyle fushiFieldTextStyle(TextStyle? style) {
  if (style is WidgetStateTextStyle) return style;
  return (style ?? const TextStyle()).copyWith(
    leadingDistribution: TextLeadingDistribution.even,
    textBaseline: TextBaseline.alphabetic,
  );
}

/// [fushiFieldTextStyle] 的占位符版：InputDecorator 的占位符样式是
/// `bodyLarge.merge(正文样式).merge(hintStyle)`，调用方的 hintStyle 若是
/// inherit: false 的完整样式会整个顶掉正文样式里的均分行距，这里补回。
InputDecoration? _fushiFieldEvenHint(InputDecoration? decoration) {
  final TextStyle? hint = decoration?.hintStyle;
  if (decoration == null || hint == null) return decoration;
  return decoration.copyWith(hintStyle: fushiFieldTextStyle(hint));
}

/// iOS 档页面顶部独立搜索栏（[FushiAppleLargeSearchScope]）的度量。参照 iOS 26
/// 真机大标题页（3x 截图按逻辑宽 393pt 换算）：胶囊高 ≈ 43.7 → 44、放大镜字形
/// ≈ 16pt → 图标 20、图标离左缘 ≈ 13.5 → 内边距 12（图标自带 2 的留白）、占位字
/// 左缘离胶囊左缘 ≈ 39.7 → 12 + 20 + 间距 8、占位字 17 号（与正文同字号）。
/// 行内 / 工具条搜索胶囊仍是 36 高（UISearchTextField 的紧凑形态）。
const double kFushiAppleSearchBarHeight = 44;
const double kFushiAppleSearchBarIconSize = 20;
const double kFushiAppleSearchBarHorizontalPadding = 12;
const double kFushiAppleSearchBarIconGap = 8;

/// 子树里的 Apple 搜索框按 iOS 档「页面顶部独立搜索栏」排（高 44，见
/// [kFushiAppleSearchBarHeight]）。由 `FushiSearchField(size: large)` 的 Apple
/// 分支挂上；macOS 档（[FushiAppleMetrics.desktop]）不受影响，仍是 28 高的
/// NSSearchField。纯度量作用域，本身不画任何东西。
class FushiAppleLargeSearchScope extends InheritedWidget {
  const FushiAppleLargeSearchScope({required super.child, super.key});

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiAppleLargeSearchScope>() !=
      null;

  @override
  bool updateShouldNotify(FushiAppleLargeSearchScope oldWidget) => false;
}

/// 子树是 inset grouped 分组（`AdaptiveSettingsSection`）里的一行。设置行据此判断
/// 自己是不是分组的一整行（trailing 是输入框的设置行在分组里改排表单行，分组
/// 外——对话框正文直接放一行——维持原样）。纯语义作用域，本身不画任何东西。
class FushiAppleGroupedRowScope extends InheritedWidget {
  const FushiAppleGroupedRowScope({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiAppleGroupedRowScope>() !=
      null;

  @override
  bool updateShouldNotify(FushiAppleGroupedRowScope oldWidget) => false;
}

/// 标记接口：Apple 设计系统下，作为 inset grouped 分组里**一整行**时渲染成
/// iOS / macOS 表单行的文本输入组件（[FushiTextFieldControl]、
/// [FushiTextFormFieldControl]、`FushiTextField`、`SettingsFormField`）。
///
/// 分组容器（`AdaptiveSettingsSection` 等）只给**直接**是这类组件的行挂
/// [FushiAppleFormRowScope]（见 [FushiAppleFormRowScope.wrapRow]），嵌在自绘
/// 复合行里的输入框（行尾小输入、标题 + 字段的组合行）不受影响。
abstract interface class FushiAppleFormRowField {}

/// 子树里的 Apple 文本输入框是 inset grouped 分组的一整行，按表单行排：
///
/// - iOS 档：行高 = [FushiAppleMetrics.rowMinHeight]、无填充框无描边，行间分隔线
///   由分组画。只有标题（`labelText`）时标题当占位文字（写法①，Contacts /
///   「新建提醒事项」）；标题 + 占位都有时左标题、右侧右对齐输入（写法②，
///   SwiftUI `LabeledContent` / Settings）。多行是行内多行，不加外框。
/// - macOS 档（[FushiAppleMetrics.desktop]）：macOS 27 grouped Form 行——左标题、
///   右侧 NSTextField 式小圆角输入框（白 / 深灰底 + 0.5px 描边 + 聚焦环）。
///
/// 纯语义作用域，本身不画任何东西；MD3 下不读它。
///
/// 设置行（`AdaptiveSettingsRow` 的 trailing 是输入框）把行标题 / 说明 / 行首
/// 图标经 [label] / [helper] / [leading] 交给字段：标题取代字段自己的
/// `labelText`（两者常常同文，避免画两遍），说明排在行内下方。
class FushiAppleFormRowScope extends InheritedWidget {
  const FushiAppleFormRowScope({
    required super.child,
    super.key,
    this.label,
    this.helper,
    this.leading,
  });

  /// 行标题；null = 用字段自己的 `labelText` / `label`。
  final String? label;

  /// 行说明（字段没有 helper 时排在行内下方）。
  final String? helper;

  /// 行首件（设置行的彩色图标块），自带与标题之间的间距（与同组其它设置行的
  /// 文字起点、分隔线缩进对齐）。
  final Widget? leading;

  static FushiAppleFormRowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiAppleFormRowScope>();

  static bool of(BuildContext context) => maybeOf(context) != null;

  /// 分组的一行：一律挂 [FushiAppleGroupedRowScope]；直接是
  /// [FushiAppleFormRowField] 时再挂表单行作用域。
  static Widget wrapRow(Widget row) => FushiAppleGroupedRowScope(
    child: row is FushiAppleFormRowField
        ? FushiAppleFormRowScope(child: row)
        : row,
  );

  @override
  bool updateShouldNotify(FushiAppleFormRowScope oldWidget) =>
      oldWidget.label != label ||
      oldWidget.helper != helper ||
      oldWidget.leading != leading;
}

/// 装饰是不是「搜索框」：前缀图标是放大镜。iOS 上搜索框是全胶囊
/// （UISearchBar），普通输入框是圆角 10 的矩形——这是唯一能从调用点无侵入
/// 读出的信号。
bool _isSearchDecoration(InputDecoration decoration) {
  Widget? prefix = decoration.prefixIcon;
  // 调用点给放大镜自配留白（设置页 MD3 胶囊搜索栏的 `Padding(FushiIcon)`）时
  // 要看穿这层包装：认不出来就会把调用方写好的胶囊边框压成 12 圆角方框
  // （BUG-3038，Android 设置页搜索栏变成圆角矩形）。
  while (prefix is Padding) {
    prefix = prefix.child;
  }
  // 自定义 leading（M3E search bar 的返回箭头 / 菜单钮）显式声明自己是搜索框。
  if (prefix is FushiSearchLeading) return true;
  // 调用点的图标经全局替换是 FushiIcon（玻璃下映射成 SF 字形），原生 Icon
  // 也认——只认 Icon 会让全部搜索框失去胶囊形态。
  final IconData? icon = switch (prefix) {
    final FushiIcon i => i.icon,
    final Icon i => i.icon,
    _ => null,
  };
  if (icon == null) return false;
  // 调用点的放大镜已迁到语义图标层 `FushiIcons.search`（FushiSymbols 字族码位，
  // 与 Icons.search 不相等）；只认旧 Material 图标会让全部搜索框丢掉胶囊形态
  // ——MD3 退成 12 圆角方框、Apple 退成 48 高普通输入框（BUG-3054）。线框与
  // 实心两个字族都认。
  if (isFushiSymbol(icon) && icon.codePoint == FushiIcons.search.codePoint) {
    return true;
  }
  return icon == Icons.search ||
      icon == Icons.search_rounded ||
      icon == Icons.search_outlined ||
      icon == CupertinoIcons.search;
}

/// 搜索框的自定义 leading 包装：把返回箭头 / 菜单钮等放进搜索框前缀位时，
/// 用它包一层，[fushiMd3FieldDecoration] 与 Apple 分支仍按「搜索框」给全胶囊
/// （否则前缀不是放大镜就认不出，会退成圆角 12 的普通输入框）。
class FushiSearchLeading extends StatelessWidget {
  const FushiSearchLeading({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// M3E outlined 文本框的边框标记：调用方给 `border: const FushiOutlinedFieldBorder()`
/// 即选 outlined 变体——[fushiMd3FieldDecoration] 认出它后给透明底 + 1px outline
/// 描边（聚焦 2px 主色、错误 error），标题骑在描边线上（M3
/// outlined text field）。其余调用默认是 filled 变体。
class FushiOutlinedFieldBorder extends OutlineInputBorder {
  const FushiOutlinedFieldBorder({
    super.borderSide,
    super.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  FushiOutlinedFieldBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) => FushiOutlinedFieldBorder(
    borderSide: borderSide ?? this.borderSide,
    borderRadius: borderRadius ?? this.borderRadius,
  );
}

/// M3E 文本框状态层：悬停在填充色上叠 8% onSurface（M3 hover state layer）。
const double kFushiFieldHoverStateOpacity = 0.08;

/// MD3 设计系统下的输入框外观（用户 2026-10-04：「所有输入框都很丑」）。
///
/// 调用点普遍手写 `border: const OutlineInputBorder()`（灰色细描边方框），
/// 或不写边框（Flutter 默认下划线）。这里统一换成现代 MD3 的填充式：
/// surfaceContainerHigh 柔和底、圆角 12、静止无描边，聚焦 2px 主色描边，
/// 错误态 error 描边；搜索框（前缀放大镜）是全圆角胶囊。
/// 调用方显式 `InputBorder.none`（嵌在自绘容器里的输入）与自定义边框类型
/// 原样保留；墨水屏保留原样（它靠描边表达边界，填充色在墨水屏上是灰噪点）。
InputDecoration? fushiMd3FieldDecoration(
  BuildContext context,
  InputDecoration? decoration,
) {
  if (decoration == null || isEinkTheme(context)) return decoration;
  final InputBorder? border = decoration.border;
  if (border == InputBorder.none) return decoration;
  if (border is FushiOutlinedFieldBorder) {
    return _fushiMd3OutlinedDecoration(context, decoration, border);
  }
  if (border != null &&
      border is! OutlineInputBorder &&
      border is! UnderlineInputBorder) {
    return decoration;
  }
  final ColorScheme cs = Theme.of(context).colorScheme;
  final bool search = _isSearchDecoration(decoration);
  // M3 filled text field：只有上两角圆（extra-small 4），下沿是活动指示线
  // （静止 1dp onSurfaceVariant、聚焦 2dp primary、错误 error）。搜索框是 M3
  // search bar（另一种组件），保持全圆胶囊、无指示线。
  final BorderRadius radius = search
      ? const BorderRadius.all(Radius.circular(999))
      : FushiM3eShape.textFieldRadius;
  // 彩色色块里的字段（[FushiFieldFillScope]）：静止指示线 / 标题 / 尾部图标取
  // 块的前景色，聚焦仍是主题 primary。
  final Color? scopedFg = FushiFieldFillScope.foregroundOf(context);
  // 活动指示线由 [FushiFieldIndicatorHost] 按焦点 / 悬停 / 错误状态以
  // FushiMotion 时长补间并直接画；没有宿主时按下面各状态的静态描边画。
  final FushiFieldIndicator? indicator = FushiFieldIndicatorHost.maybeOf(
    context,
  );
  final Color quiet = scopedFg?.withValues(alpha: 0.72) ?? cs.onSurfaceVariant;
  // 带标题（labelText / label）的字段用「填充式」边框：OutlineInputBorder 会把
  // 浮起的标题放在边框线**上**（为描边留缺口），没有可见描边的填充框里，标题就
  // 骑在填充块的上沿、一半露在框外（禁用 / 已有内容的「服务器」「API Key」）。
  // M3 填充式文本框的标题浮在填充块**内**顶部，总高 56——非 outline 边框就是
  // 这个布局；描边（聚焦 / 错误）照旧画一整圈圆角。
  final bool labelled =
      decoration.label != null || decoration.labelText != null;
  InputBorder outline([Color? color, double width = 0]) {
    final BorderSide side = color == null
        ? BorderSide.none
        : BorderSide(color: color, width: width);
    if (search) {
      return OutlineInputBorder(borderRadius: radius, borderSide: side);
    }
    // 带标题的走非 outline 布局（标题浮在填充块内顶端）；不带标题的保留
    // outline 布局（尺寸档的单行高 / 竖直居中不变），两者画法一样。
    return _FushiFilledFieldBorder(
      borderRadius: radius,
      borderSide: side,
      outlineLayout: !labelled,
      indicator: indicator,
      error: color == cs.error,
    );
  }

  final EdgeInsetsGeometry? padding = search
      ? const EdgeInsets.symmetric(horizontal: 16, vertical: 10)
      : (labelled
            ? fushiFilledLabelContentPadding(context, decoration)
            : decoration.contentPadding);
  return decoration.copyWith(
    filled: true,
    fillColor: decoration.fillColor ?? fushiMd3FieldFill(context),
    // M3E 状态层：悬停 8% onSurface 叠在填充上（InputDecorator 把 hoverColor
    // 混进 fillColor），鼠标指上去看得见可输入。
    hoverColor:
        decoration.hoverColor ??
        cs.onSurface.withValues(alpha: kFushiFieldHoverStateOpacity),
    border: search ? outline() : outline(quiet, 1),
    enabledBorder: search ? outline() : outline(quiet, 1),
    disabledBorder: search
        ? outline()
        : outline(cs.onSurface.withValues(alpha: 0.38), 1),
    focusedBorder: outline(cs.primary, 2),
    errorBorder: outline(cs.error, search ? 1.5 : 1),
    focusedErrorBorder: outline(cs.error, 2),
    labelStyle:
        decoration.labelStyle ??
        (scopedFg == null ? null : TextStyle(color: quiet)),
    hintStyle: decoration.hintStyle ?? TextStyle(color: quiet),
    prefixIconColor: decoration.prefixIconColor ?? quiet,
    suffixIconColor: decoration.suffixIconColor ?? quiet,
    contentPadding: padding,
  );
}

/// MD3 填充式字段的容器色：比所在表面高一级色调，框才看得出来。
///
/// 页面 / 卡片上是 surfaceContainerHigh；对话框面板（[FushiDialogScope]，
/// 面板本身就是 surfaceContainerHigh）里升到 surfaceContainerHighest（M3 filled
/// text field 规范色）——此前对话框里填充色与面板同色，输入框看上去「无框无底」
/// 只剩一行浮动标题（导入对话框反馈）。
///
/// 祖先有 [FushiFieldFillScope]（彩色色块里的字段）时用它给的底色。
Color fushiMd3FieldFill(BuildContext context) {
  final Color? scoped = FushiFieldFillScope.maybeOf(context);
  if (scoped != null) return scoped;
  final ColorScheme cs = Theme.of(context).colorScheme;
  return FushiDialogScope.of(context)
      ? cs.surfaceContainerHighest
      : cs.surfaceContainerHigh;
}

/// 子树里 MD3 填充式字段 / 下拉触发器的底色覆盖（[fushiMd3FieldFill]）：灰底
/// 压在彩色色块上发脏，色块（导入对话框的 `ImportSectionBlock`）给一档向块色
/// 偏的底色。只影响字段填充，不改主题。
class FushiFieldFillScope extends InheritedWidget {
  const FushiFieldFillScope({
    required this.color,
    required super.child,
    this.foreground,
    super.key,
  });

  final Color color;

  /// 块的前景色：静止指示线、标题、尾部图标按它取（压暗 72%）；null = 主题
  /// onSurfaceVariant。
  final Color? foreground;

  static Color? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiFieldFillScope>()?.color;

  static Color? foregroundOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FushiFieldFillScope>()
      ?.foreground;

  @override
  bool updateShouldNotify(FushiFieldFillScope oldWidget) =>
      oldWidget.color != color || oldWidget.foreground != foreground;
}

/// 带标题的填充式字段（M3 filled text field）的内边距：浮起标题的顶部留白
/// **不被平台密度吃掉**（反馈 jIlpJV-xW4「文字显示不全」）。
///
/// InputDecorator 把填充式字段的浮起标题画在 `contentPadding.top + 密度dy/2`
/// 处，M3 默认 top 是 8（dense 4）。桌面（Windows / macOS / Linux）主题默认
/// `VisualDensity.compact`（dy = -8），于是 dense 字段的标题顶在 0——字形直接贴着
/// 填充块上沿被切（字幕合集面板的「Jimaku API 密钥」「番剧名」「偏好版本」）；
/// 非 dense 也只剩 4。密度本意是压整体高度，这里把它从顶部补回来、只让它作用在
/// 底部：标题顶距在所有平台都等于 M3 默认（8 / dense 4）。
///
/// 调用方显式给了 [InputDecoration.contentPadding] 或 isCollapsed 时原样返回；
/// 密度不为负时返回 null，交给 InputDecorator 的 M3 默认。
EdgeInsetsGeometry? fushiFilledLabelContentPadding(
  BuildContext context,
  InputDecoration decoration,
) {
  if (decoration.contentPadding != null || (decoration.isCollapsed ?? false)) {
    return decoration.contentPadding;
  }
  final double dy =
      (decoration.visualDensity ?? Theme.of(context).visualDensity)
          .baseSizeAdjustment
          .dy;
  if (dy >= 0) return null;
  // InputDecorator 的 M3 填充式默认：dense (12, 4, 12, 4)，常规 (12, 8, 12, 8)。
  final double base = (decoration.isDense ?? false) ? 4.0 : 8.0;
  return EdgeInsetsDirectional.fromSTEB(12, base - dy / 2, 12, base);
}

/// M3E outlined 变体（见 [FushiOutlinedFieldBorder]）：透明底、1px outline 描边，
/// 聚焦 2px 主色、错误 error、禁用 12% onSurface；圆角跟调用方给的边框走。
InputDecoration _fushiMd3OutlinedDecoration(
  BuildContext context,
  InputDecoration decoration,
  FushiOutlinedFieldBorder border,
) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  InputBorder side(Color color, double width) => border.copyWith(
    borderSide: BorderSide(color: color, width: width),
  );
  return decoration.copyWith(
    filled: false,
    hoverColor: Colors.transparent,
    border: side(cs.outline, 1),
    enabledBorder: side(cs.outline, 1),
    disabledBorder: side(cs.onSurface.withValues(alpha: 0.12), 1),
    focusedBorder: side(cs.primary, 2),
    errorBorder: side(cs.error, 1),
    focusedErrorBorder: side(cs.error, 2),
    hintStyle: decoration.hintStyle ?? TextStyle(color: cs.onSurfaceVariant),
    prefixIconColor: decoration.prefixIconColor ?? cs.onSurfaceVariant,
    suffixIconColor: decoration.suffixIconColor ?? cs.onSurfaceVariant,
  );
}

/// MD3 填充式字段的边框（M3 filled text field）：填充按 [borderRadius] 裁
/// （上两角圆、下两角方），[borderSide] 只画在下沿当活动指示线。
///
/// [outlineLayout] 为 false（带标题的字段）时 [isOutline] 为 false——
/// InputDecorator 据此把浮起的标题放在填充块内部顶端，而不是骑在边框线上；
/// 不带标题的字段保持 outline 布局（尺寸档的高度与竖直居中不变）。状态切换
/// （静止 ↔ 聚焦 ↔ 错误）由 InputDecorator 按 [lerpFrom] / [lerpTo] 补间。
/// 见 [fushiMd3FieldDecoration]。
class _FushiFilledFieldBorder extends InputBorder {
  const _FushiFilledFieldBorder({
    required this.borderRadius,
    super.borderSide = BorderSide.none,
    this.outlineLayout = false,
    this.indicator,
    this.error = false,
  });

  final BorderRadius borderRadius;
  final bool outlineLayout;

  /// 宿主的活动指示线（见 [FushiFieldIndicatorHost]）；非 null 时线的颜色 /
  /// 粗细取它此刻的动画值，不取 [borderSide]（InputDecorator 自带的 167ms
  /// 边框补间因此不再决定观感）。
  final FushiFieldIndicator? indicator;

  /// 这是错误态边框（InputDecorator 按校验结果选中）。宿主不知道错误时
  /// （TextFormField 的 validator）据此直接画错误色。
  final bool error;

  @override
  bool get isOutline => outlineLayout;

  @override
  EdgeInsetsGeometry get dimensions =>
      EdgeInsets.only(bottom: borderSide.width);

  @override
  _FushiFilledFieldBorder copyWith({BorderSide? borderSide}) =>
      _FushiFilledFieldBorder(
        borderRadius: borderRadius,
        borderSide: borderSide ?? this.borderSide,
        outlineLayout: outlineLayout,
        indicator: indicator,
        error: error,
      );

  @override
  ShapeBorder scale(double t) => _FushiFilledFieldBorder(
    borderRadius: borderRadius * t,
    borderSide: borderSide.scale(t),
    outlineLayout: outlineLayout,
    indicator: indicator,
    error: error,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is _FushiFilledFieldBorder) {
      return _FushiFilledFieldBorder(
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        outlineLayout: outlineLayout,
        indicator: indicator,
        error: error,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is _FushiFilledFieldBorder) {
      return _FushiFilledFieldBorder(
        borderRadius: BorderRadius.lerp(borderRadius, b.borderRadius, t)!,
        borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
        outlineLayout: outlineLayout,
        indicator: indicator,
        error: error,
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(
        Rect.fromLTRB(
          rect.left,
          rect.top,
          rect.right,
          math.max(rect.top, rect.bottom - borderSide.width),
        ),
      );

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(borderRadius.resolve(textDirection).toRRect(rect));

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    final FushiFieldIndicator? live = indicator;
    final BorderSide line = live == null ? borderSide : live.side(error: error);
    if (line.style == BorderStyle.none || line.width == 0) return;
    final double y = rect.bottom - line.width / 2;
    canvas.drawLine(
      Offset(rect.left, y),
      Offset(rect.right, y),
      line.toPaint(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _FushiFilledFieldBorder &&
      other.borderSide == borderSide &&
      other.borderRadius == borderRadius &&
      other.outlineLayout == outlineLayout &&
      other.indicator == indicator &&
      other.error == error;

  @override
  int get hashCode =>
      Object.hash(borderSide, borderRadius, outlineLayout, indicator, error);
}

/// MD3 填充式字段 / 下拉触发器的活动指示线（M3 filled text field 的下沿线）
/// 此刻的样子：由 [FushiFieldIndicatorHost] 的动画驱动，填充式边框在 paint 时
/// 读它。静止 1dp（块里是压暗的块前景色，否则 onSurfaceVariant）、悬停换
/// onSurface、聚焦 / 展开 2dp primary、错误 error、禁用 onSurface 38%。
class FushiFieldIndicator {
  FushiFieldIndicator._(this._focus, this._hover, this._error);

  final Animation<double> _focus;
  final Animation<double> _hover;
  final Animation<double> _error;

  Color _rest = const Color(0x00000000);
  Color _hovered = const Color(0x00000000);
  Color _active = const Color(0x00000000);
  Color _errorColor = const Color(0x00000000);
  Color _disabled = const Color(0x00000000);
  bool _enabled = true;

  /// 指示线此刻的描边；[error] = 边框自己是错误态（宿主不知道的校验错误）。
  BorderSide side({bool error = false}) {
    if (!_enabled) return BorderSide(color: _disabled);
    final double e = error ? 1 : _error.value;
    final double f = _focus.value;
    final Color base = Color.lerp(
      Color.lerp(_rest, _hovered, _hover.value),
      _errorColor,
      e,
    )!;
    final Color active = Color.lerp(_active, _errorColor, e)!;
    return BorderSide(color: Color.lerp(base, active, f)!, width: 1 + f);
  }
}

/// 给子树里的 MD3 填充式字段装一条按状态补间的活动指示线（见
/// [FushiFieldIndicator]）：被动 [Focus] 听子孙焦点、[MouseRegion] 听悬停，
/// 时长取 [fushiMotionDuration]（减弱动效时直接跳到终态）。[builder] 拿到的
/// context 在宿主之下，[fushiMd3FieldDecoration] 据此把指示线交给边框。
///
/// 只换线的画法，不动布局：浮动标题、命中区、帮助 / 错误文字照旧。[active] =
/// 外部的「展开」态（下拉菜单打开时与聚焦同一档）。
class FushiFieldIndicatorHost extends StatefulWidget {
  const FushiFieldIndicatorHost({
    required this.builder,
    this.enabled = true,
    this.error = false,
    this.active = false,
    super.key,
  });

  final WidgetBuilder builder;
  final bool enabled;
  final bool error;
  final bool active;

  static FushiFieldIndicator? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_FushiFieldIndicatorScope>()
      ?.indicator;

  @override
  State<FushiFieldIndicatorHost> createState() =>
      _FushiFieldIndicatorHostState();
}

class _FushiFieldIndicatorHostState extends State<FushiFieldIndicatorHost>
    with TickerProviderStateMixin {
  late final AnimationController _focus = AnimationController(vsync: this);
  late final AnimationController _hover = AnimationController(vsync: this);
  late final AnimationController _error = AnimationController(
    vsync: this,
    value: widget.error ? 1 : 0,
  );
  late final FushiFieldIndicator _indicator = FushiFieldIndicator._(
    _focus,
    _hover,
    _error,
  );
  late final Listenable _repaint = Listenable.merge(<Listenable>[
    _focus,
    _hover,
    _error,
  ]);
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _focus.value = 1;
  }

  void _drive(AnimationController controller, bool on) {
    final double target = on ? 1 : 0;
    if (controller.value == target && !controller.isAnimating) return;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    if (duration == Duration.zero) {
      controller.value = target;
      return;
    }
    controller.animateTo(
      target,
      duration: duration,
      curve: FushiMotion.standard,
    );
  }

  @override
  void didUpdateWidget(FushiFieldIndicatorHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.error != widget.error) _drive(_error, widget.error);
    if (oldWidget.active != widget.active) {
      _drive(_focus, _hasFocus || widget.active);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _hover.dispose();
    _error.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color? scopedFg = FushiFieldFillScope.foregroundOf(context);
    _indicator
      .._rest = scopedFg?.withValues(alpha: 0.72) ?? cs.onSurfaceVariant
      .._hovered = scopedFg ?? cs.onSurface
      .._active = cs.primary
      .._errorColor = cs.error
      .._disabled = cs.onSurface.withValues(alpha: 0.38)
      .._enabled = widget.enabled;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (bool focused) {
        _hasFocus = focused;
        _drive(_focus, focused || widget.active);
      },
      child: MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (_) => _drive(_hover, true),
        onExit: (_) => _drive(_hover, false),
        // 指示线动画每一帧让本子树重画：填充式边框在 InputDecorator 的
        // paint 里读 [FushiFieldIndicator] 的当前值（两者之间没有重画边界，
        // TextField 只把 EditableText 隔在 RepaintBoundary 里）。
        child: CustomPaint(
          foregroundPainter: _FushiFieldIndicatorRepaint(_repaint),
          child: _FushiFieldIndicatorScope(
            indicator: _indicator,
            child: Builder(builder: widget.builder),
          ),
        ),
      ),
    );
  }
}

/// 不经 InputDecorator 的字段式控件（下拉触发器）自己画活动指示线：在
/// [child] 下沿画 [FushiFieldIndicatorHost] 此刻的线。没有宿主时原样返回。
class FushiFieldIndicatorLine extends StatelessWidget {
  const FushiFieldIndicatorLine({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final FushiFieldIndicator? indicator = FushiFieldIndicatorHost.maybeOf(
      context,
    );
    if (indicator == null) return child;
    return CustomPaint(
      foregroundPainter: _FushiFieldIndicatorLinePainter(indicator),
      child: child,
    );
  }
}

class _FushiFieldIndicatorLinePainter extends CustomPainter {
  _FushiFieldIndicatorLinePainter(this.indicator);

  final FushiFieldIndicator indicator;

  @override
  void paint(Canvas canvas, Size size) {
    final BorderSide line = indicator.side();
    if (line.width == 0) return;
    final double y = size.height - line.width / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line.toPaint());
  }

  // 宿主动画每帧让子树重画（见 [FushiFieldIndicatorHost]），值随之更新。
  @override
  bool shouldRepaint(_FushiFieldIndicatorLinePainter oldDelegate) =>
      oldDelegate.indicator != indicator;
}

class _FushiFieldIndicatorRepaint extends CustomPainter {
  _FushiFieldIndicatorRepaint(Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_FushiFieldIndicatorRepaint oldDelegate) => false;
}

class _FushiFieldIndicatorScope extends InheritedWidget {
  const _FushiFieldIndicatorScope({
    required this.indicator,
    required super.child,
  });

  final FushiFieldIndicator indicator;

  @override
  bool updateShouldNotify(_FushiFieldIndicatorScope oldWidget) =>
      oldWidget.indicator != indicator;
}

/// [TextField] 的设计系统分派版。
///
/// @design dual —— MD3 走 [TextField] + M3E 字段装饰；Apple 走无边框
/// [CupertinoTextField] + 自绘壳：iOS 27 `tertiarySystemFill` 圆角 10 无描边
/// （搜索装饰 = 高 36 全胶囊），macOS 27 宽窗白底 / 深色 tertiaryFill + 0.5px
/// 描边圆角 6（搜索装饰 = 高 28 灰填充胶囊），正文 17 / 13。
class FushiTextFieldControl extends StatelessWidget
    implements FushiAppleFormRowField {
  const FushiTextFieldControl({
    super.key,
    this.groupId = EditableText,
    this.controller,
    this.focusNode,
    this.undoController,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.strutStyle,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.textDirection,
    this.readOnly = false,
    this.toolbarOptions,
    this.showCursor,
    this.autofocus = false,
    this.statesController,
    this.obscuringCharacter = '•',
    this.obscureText = false,
    this.autocorrect,
    this.smartDashesType,
    this.smartQuotesType,
    this.enableSuggestions = true,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.maxLength,
    this.maxLengthEnforcement,
    this.onChanged,
    this.onEditingComplete,
    this.onSubmitted,
    this.onAppPrivateCommand,
    this.inputFormatters,
    this.enabled,
    this.ignorePointers,
    this.cursorWidth = 2.0,
    this.cursorHeight,
    this.cursorRadius,
    this.cursorOpacityAnimates,
    this.cursorColor,
    this.cursorErrorColor,
    this.selectionHeightStyle,
    this.selectionWidthStyle,
    this.keyboardAppearance,
    this.scrollPadding = const EdgeInsets.all(20.0),
    this.dragStartBehavior = DragStartBehavior.start,
    this.enableInteractiveSelection,
    this.selectAllOnFocus,
    this.selectionControls,
    this.onTap,
    this.onTapAlwaysCalled = false,
    this.onTapOutside,
    this.onTapUpOutside,
    this.mouseCursor,
    this.buildCounter,
    this.scrollController,
    this.scrollPhysics,
    this.autofillHints = const <String>[],
    this.contentInsertionConfiguration,
    this.clipBehavior = Clip.hardEdge,
    this.restorationId,
    this.scribbleEnabled = true,
    this.stylusHandwritingEnabled =
        EditableText.defaultStylusHandwritingEnabled,
    this.enableIMEPersonalizedLearning = true,
    this.enableInlinePrediction,
    this.contextMenuBuilder = _fushiDefaultContextMenuBuilder,
    this.canRequestFocus = true,
    this.spellCheckConfiguration,
    this.magnifierConfiguration,
    this.hintLocales,
  });

  final Object groupId;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final UndoHistoryController? undoController;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final TextDirection? textDirection;
  final bool readOnly;
  final ToolbarOptions? toolbarOptions;
  final bool? showCursor;
  final bool autofocus;
  final WidgetStatesController? statesController;
  final String obscuringCharacter;
  final bool obscureText;
  final bool? autocorrect;
  final SmartDashesType? smartDashesType;
  final SmartQuotesType? smartQuotesType;
  final bool enableSuggestions;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final int? maxLength;
  final MaxLengthEnforcement? maxLengthEnforcement;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final ValueChanged<String>? onSubmitted;
  final AppPrivateCommandCallback? onAppPrivateCommand;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final bool? ignorePointers;
  final double cursorWidth;
  final double? cursorHeight;
  final Radius? cursorRadius;
  final bool? cursorOpacityAnimates;
  final Color? cursorColor;
  final Color? cursorErrorColor;
  final ui.BoxHeightStyle? selectionHeightStyle;
  final ui.BoxWidthStyle? selectionWidthStyle;
  final Brightness? keyboardAppearance;
  final EdgeInsets scrollPadding;
  final DragStartBehavior dragStartBehavior;
  final bool? enableInteractiveSelection;
  final bool? selectAllOnFocus;
  final TextSelectionControls? selectionControls;
  final GestureTapCallback? onTap;
  final bool onTapAlwaysCalled;
  final TapRegionCallback? onTapOutside;
  final TapRegionUpCallback? onTapUpOutside;
  final MouseCursor? mouseCursor;
  final InputCounterWidgetBuilder? buildCounter;
  final ScrollController? scrollController;
  final ScrollPhysics? scrollPhysics;
  final Iterable<String>? autofillHints;
  final ContentInsertionConfiguration? contentInsertionConfiguration;
  final Clip clipBehavior;
  final String? restorationId;
  final bool scribbleEnabled;
  final bool stylusHandwritingEnabled;
  final bool enableIMEPersonalizedLearning;
  final bool? enableInlinePrediction;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final bool canRequestFocus;
  final SpellCheckConfiguration? spellCheckConfiguration;
  final TextMagnifierConfiguration? magnifierConfiguration;
  final List<Locale>? hintLocales;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _GlassTextFieldView(config: this);
    }
    // MD3：活动指示线按状态以 FushiMotion 补间（FushiFieldIndicatorHost）。
    return FushiFieldIndicatorHost(
      enabled: (enabled ?? decoration?.enabled ?? true),
      error: (decoration?.errorText != null || decoration?.error != null),
      builder: (BuildContext context) => TextField(
        groupId: groupId,
        controller: controller,
        focusNode: focusNode,
        undoController: undoController,
        decoration: _fushiFieldEvenHint(
          fushiMd3FieldDecoration(context, decoration),
        ),
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        style: fushiFieldTextStyle(style),
        strutStyle: strutStyle,
        textAlign: textAlign,
        textAlignVertical:
            textAlignVertical ??
            (maxLines == 1 &&
                    decoration != null &&
                    _isSearchDecoration(decoration!)
                ? TextAlignVertical.center
                : null),
        textDirection: textDirection,
        readOnly: readOnly,
        toolbarOptions: toolbarOptions,
        showCursor: showCursor,
        autofocus: autofocus,
        statesController: statesController,
        obscuringCharacter: obscuringCharacter,
        obscureText: obscureText,
        autocorrect: autocorrect,
        smartDashesType: smartDashesType,
        smartQuotesType: smartQuotesType,
        enableSuggestions: enableSuggestions,
        maxLines: maxLines,
        minLines: minLines,
        expands: expands,
        maxLength: maxLength,
        maxLengthEnforcement: maxLengthEnforcement,
        onChanged: onChanged,
        onEditingComplete: onEditingComplete,
        onSubmitted: onSubmitted,
        onAppPrivateCommand: onAppPrivateCommand,
        inputFormatters: inputFormatters,
        enabled: enabled,
        ignorePointers: ignorePointers,
        cursorWidth: cursorWidth,
        cursorHeight: cursorHeight,
        cursorRadius: cursorRadius,
        cursorOpacityAnimates: cursorOpacityAnimates,
        cursorColor: cursorColor,
        cursorErrorColor: cursorErrorColor,
        selectionHeightStyle: selectionHeightStyle,
        selectionWidthStyle: selectionWidthStyle,
        keyboardAppearance: keyboardAppearance,
        scrollPadding: scrollPadding,
        dragStartBehavior: dragStartBehavior,
        enableInteractiveSelection: enableInteractiveSelection,
        selectAllOnFocus: selectAllOnFocus,
        selectionControls: selectionControls,
        onTap: onTap,
        onTapAlwaysCalled: onTapAlwaysCalled,
        onTapOutside: onTapOutside,
        onTapUpOutside: onTapUpOutside,
        mouseCursor: mouseCursor,
        buildCounter: buildCounter,
        scrollController: scrollController,
        scrollPhysics: scrollPhysics,
        autofillHints: autofillHints,
        contentInsertionConfiguration: contentInsertionConfiguration,
        clipBehavior: clipBehavior,
        restorationId: restorationId,
        scribbleEnabled: scribbleEnabled,
        stylusHandwritingEnabled: stylusHandwritingEnabled,
        enableIMEPersonalizedLearning: enableIMEPersonalizedLearning,
        enableInlinePrediction: enableInlinePrediction,
        contextMenuBuilder: contextMenuBuilder,
        canRequestFocus: canRequestFocus,
        spellCheckConfiguration: spellCheckConfiguration,
        magnifierConfiguration: magnifierConfiguration,
        hintLocales: hintLocales,
      ),
    );
  }
}

/// 玻璃输入框本体。所有文本编辑行为来自 [config]（与 Material TextField 同一份
/// 参数），本类只负责玻璃壳与 InputDecoration 的映射。
class _GlassTextFieldView extends StatefulWidget {
  const _GlassTextFieldView({required this.config});

  final FushiTextFieldControl config;

  @override
  State<_GlassTextFieldView> createState() => _GlassTextFieldViewState();
}

class _GlassTextFieldViewState extends State<_GlassTextFieldView> {
  TextEditingController? _ownController;
  FocusNode? _ownFocusNode;

  FushiTextFieldControl get _c => widget.config;

  TextEditingController get _controller =>
      _c.controller ?? (_ownController ??= TextEditingController());

  FocusNode get _focusNode => _c.focusNode ?? (_ownFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    _controller.addListener(_onTextChanged);
    _syncStates();
  }

  @override
  void didUpdateWidget(covariant _GlassTextFieldView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final FushiTextFieldControl old = oldWidget.config;
    if (old.focusNode != _c.focusNode) {
      (old.focusNode ?? _ownFocusNode)?.removeListener(_onFocusChanged);
      if (_c.focusNode != null) {
        _ownFocusNode?.dispose();
        _ownFocusNode = null;
      }
      _focusNode.addListener(_onFocusChanged);
    }
    if (old.controller != _c.controller) {
      (old.controller ?? _ownController)?.removeListener(_onTextChanged);
      if (_c.controller != null) {
        _ownController?.dispose();
        _ownController = null;
      } else if (old.controller != null) {
        _ownController = TextEditingController.fromValue(old.controller!.value);
      }
      _controller.addListener(_onTextChanged);
    }
    _syncStates();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _controller.removeListener(_onTextChanged);
    _ownFocusNode?.dispose();
    _ownController?.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    _syncStates();
    setState(() {});
  }

  void _onTextChanged() {
    // 只有计数器依赖文本长度；没有计数器时不为每次击键重建整个壳。
    if (!mounted) return;
    if (_c.maxLength != null || _c.buildCounter != null) setState(() {});
  }

  bool get _enabled => _c.enabled ?? _c.decoration?.enabled ?? true;

  bool get _hasError =>
      _c.decoration?.errorText != null || _c.decoration?.error != null;

  /// 与 Material TextField 一样把 disabled / focused / error 同步进调用方的
  /// [WidgetStatesController]（只在生命周期回调里改，不在 build 里通知）。
  void _syncStates() {
    final WidgetStatesController? states = _c.statesController;
    if (states == null) return;
    states.update(WidgetState.disabled, !_enabled);
    states.update(WidgetState.focused, _focusNode.hasFocus);
    states.update(WidgetState.error, _hasError);
  }

  Widget _buildEditable(
    BuildContext context,
    TextStyle style,
    bool hasError, {
    String? placeholder,
    TextAlign? textAlign,
  }) {
    final FushiAppleColors apple = appleColorsOf(context);
    final InputDecoration? decoration = _c.decoration;
    // 占位符与正文同字号、secondaryLabel 色（iOS placeholder）。
    final TextStyle hintStyle = fushiFieldTextStyle(
      style.copyWith(color: apple.secondaryLabel).merge(decoration?.hintStyle),
    );
    final Color cursorColor = hasError
        ? (_c.cursorErrorColor ?? apple.destructive)
        : (_c.cursorColor ?? apple.accent);
    final bool cursorAnimates =
        _c.cursorOpacityAnimates ??
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);

    if (_c.hintLocales != null ||
        _c.onAppPrivateCommand != null ||
        _c.onTapUpOutside != null) {
      // 见文件头：只有 Material TextField 能把这几个参数转给 EditableText
      // （CupertinoTextField.onTapUpOutside 的类型在 3.44 里声明错成了
      // PointerDownEvent 回调，无法桥接）。
      return TextField(
        groupId: _c.groupId,
        controller: _controller,
        focusNode: _focusNode,
        undoController: _c.undoController,
        decoration: null,
        keyboardType: _c.keyboardType,
        textInputAction: _c.textInputAction,
        textCapitalization: _c.textCapitalization,
        style: style,
        strutStyle: _c.strutStyle,
        textAlign: _c.textAlign,
        textAlignVertical: _c.textAlignVertical,
        textDirection: _c.textDirection,
        readOnly: _c.readOnly,
        showCursor: _c.showCursor,
        autofocus: _c.autofocus,
        obscuringCharacter: _c.obscuringCharacter,
        obscureText: _c.obscureText,
        autocorrect: _c.autocorrect,
        smartDashesType: _c.smartDashesType,
        smartQuotesType: _c.smartQuotesType,
        enableSuggestions: _c.enableSuggestions,
        maxLines: _c.maxLines,
        minLines: _c.minLines,
        expands: _c.expands,
        maxLength: _c.maxLength,
        maxLengthEnforcement: _c.maxLengthEnforcement,
        onChanged: _c.onChanged,
        onEditingComplete: _c.onEditingComplete,
        onSubmitted: _c.onSubmitted,
        onAppPrivateCommand: _c.onAppPrivateCommand,
        inputFormatters: _c.inputFormatters,
        enabled: _enabled,
        ignorePointers: _c.ignorePointers,
        cursorWidth: _c.cursorWidth,
        cursorHeight: _c.cursorHeight,
        cursorRadius: _c.cursorRadius,
        cursorOpacityAnimates: cursorAnimates,
        cursorColor: cursorColor,
        selectionHeightStyle: _c.selectionHeightStyle,
        selectionWidthStyle: _c.selectionWidthStyle,
        keyboardAppearance: _c.keyboardAppearance,
        scrollPadding: _c.scrollPadding,
        dragStartBehavior: _c.dragStartBehavior,
        enableInteractiveSelection: _c.enableInteractiveSelection,
        selectAllOnFocus: _c.selectAllOnFocus,
        selectionControls: _c.selectionControls,
        onTap: _c.onTap,
        onTapAlwaysCalled: _c.onTapAlwaysCalled,
        onTapOutside: _c.onTapOutside,
        onTapUpOutside: _c.onTapUpOutside,
        mouseCursor: _c.mouseCursor,
        // 计数器画在玻璃壳外（与其它玻璃输入框一致），这里不再画一份。
        buildCounter: _hideCounter,
        scrollController: _c.scrollController,
        scrollPhysics: _c.scrollPhysics,
        autofillHints: _c.autofillHints,
        contentInsertionConfiguration: _c.contentInsertionConfiguration,
        clipBehavior: _c.clipBehavior,
        restorationId: _c.restorationId,
        stylusHandwritingEnabled: _c.stylusHandwritingEnabled,
        enableIMEPersonalizedLearning: _c.enableIMEPersonalizedLearning,
        enableInlinePrediction: _c.enableInlinePrediction,
        contextMenuBuilder:
            identical(_c.contextMenuBuilder, _fushiDefaultContextMenuBuilder)
            ? _cupertinoContextMenuBuilder
            : _c.contextMenuBuilder,
        canRequestFocus: _c.canRequestFocus,
        spellCheckConfiguration: _c.spellCheckConfiguration,
        magnifierConfiguration: _c.magnifierConfiguration,
        hintLocales: _c.hintLocales,
      );
    }

    Widget field = CupertinoTextField.borderless(
      // 显式给一个无色装饰：borderless 的 decoration 是 null，禁用态时
      // CupertinoTextField 会在文字后面铺 _kDisabledBackground（深色 #050505 /
      // 浅色 #FAFAFA）——圆角实色框里多出一条方形黑 / 白底。
      decoration: const BoxDecoration(),
      groupId: _c.groupId,
      controller: _controller,
      focusNode: _focusNode,
      undoController: _c.undoController,
      padding: EdgeInsets.zero,
      placeholder: placeholder ?? decoration?.hintText,
      placeholderStyle: hintStyle,
      keyboardType: _c.keyboardType,
      textInputAction: _c.textInputAction,
      textCapitalization: _c.textCapitalization,
      style: style,
      strutStyle: _c.strutStyle,
      textAlign: textAlign ?? _c.textAlign,
      // 多行框必须显式顶对齐（BUG-2973）：CupertinoTextField 在有占位符时把
      // 缺省的竖直对齐当成 center，而它的占位符栈高度取「占位符全部行」与
      // 「编辑区一行」的并集——空框里一行高的编辑区被居中进两行高的栈，占位符
      // 再按基线贴到编辑区上，于是整段占位符下沉半行、第二行掉出框外被裁。
      // 顶对齐时编辑区与占位符都从栈顶开始，外层壳（对称内边距 + 行内竖直
      // 居中）负责把整块内容放在框的中线上。
      textAlignVertical:
          _c.textAlignVertical ??
          (_c.maxLines == 1 ? TextAlignVertical.center : TextAlignVertical.top),
      textDirection: _c.textDirection,
      readOnly: _c.readOnly,
      showCursor: _c.showCursor,
      autofocus: _c.autofocus,
      obscuringCharacter: _c.obscuringCharacter,
      obscureText: _c.obscureText,
      autocorrect: _c.autocorrect,
      smartDashesType: _c.smartDashesType,
      smartQuotesType: _c.smartQuotesType,
      enableSuggestions: _c.enableSuggestions,
      maxLines: _c.maxLines,
      minLines: _c.minLines,
      expands: _c.expands,
      maxLength: _c.maxLength,
      maxLengthEnforcement: _c.maxLengthEnforcement,
      onChanged: _c.onChanged,
      onEditingComplete: _c.onEditingComplete,
      onSubmitted: _c.onSubmitted,
      onTapOutside: _c.onTapOutside,
      inputFormatters: _c.inputFormatters,
      enabled: _enabled,
      cursorWidth: _c.cursorWidth,
      cursorHeight: _c.cursorHeight,
      cursorRadius: _c.cursorRadius ?? const Radius.circular(2.0),
      cursorOpacityAnimates: cursorAnimates,
      cursorColor: cursorColor,
      selectionHeightStyle: _c.selectionHeightStyle,
      selectionWidthStyle: _c.selectionWidthStyle,
      keyboardAppearance: _c.keyboardAppearance,
      scrollPadding: _c.scrollPadding,
      dragStartBehavior: _c.dragStartBehavior,
      enableInteractiveSelection: _c.enableInteractiveSelection,
      selectAllOnFocus: _c.selectAllOnFocus,
      selectionControls: _c.selectionControls,
      onTap: _c.onTap,
      scrollController: _c.scrollController,
      scrollPhysics: _c.scrollPhysics,
      autofillHints: _c.autofillHints,
      contentInsertionConfiguration: _c.contentInsertionConfiguration,
      clipBehavior: _c.clipBehavior,
      restorationId: _c.restorationId,
      stylusHandwritingEnabled: _c.stylusHandwritingEnabled,
      enableIMEPersonalizedLearning: _c.enableIMEPersonalizedLearning,
      enableInlinePrediction: _c.enableInlinePrediction,
      contextMenuBuilder:
          identical(_c.contextMenuBuilder, _fushiDefaultContextMenuBuilder)
          ? _cupertinoContextMenuBuilder
          : _c.contextMenuBuilder,
      spellCheckConfiguration: _c.spellCheckConfiguration,
      magnifierConfiguration: _c.magnifierConfiguration,
    );
    if (_c.mouseCursor != null) {
      field = MouseRegion(cursor: _c.mouseCursor!, child: field);
    }
    if (_c.ignorePointers ?? false) {
      field = IgnorePointer(child: field);
    }
    return field;
  }

  static Widget? _hideCounter(
    BuildContext context, {
    required int currentLength,
    required bool isFocused,
    required int? maxLength,
  }) => null;

  Widget? _buildCounter(BuildContext context, TextStyle style) {
    final InputDecoration? decoration = _c.decoration;
    if (decoration?.counter != null) return decoration!.counter;
    if (decoration?.counterText != null) {
      final String text = decoration!.counterText!;
      return text.isEmpty
          ? null
          : Text(text, style: style.merge(decoration.counterStyle));
    }
    final int length = _controller.value.text.characters.length;
    if (_c.buildCounter != null) {
      return _c.buildCounter!(
        context,
        currentLength: length,
        maxLength: _c.maxLength,
        isFocused: _focusNode.hasFocus,
      );
    }
    final int? maxLength = _c.maxLength;
    if (maxLength == null || maxLength == 0) return null;
    final String text = maxLength > 0 ? '$length/$maxLength' : '$length';
    return Text(text, style: style.merge(decoration?.counterStyle));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme tt = theme.textTheme;
    final FushiAppleColors apple = appleColorsOf(context);
    final InputDecoration? decoration = _c.decoration;
    final bool enabled = _enabled;
    final bool focused = _focusNode.hasFocus;
    final bool hasError = _hasError;
    // 尺寸档：桌面宽窗按 macOS 27（正文 13、搜索框高 28、输入框圆角 6 + 描边），
    // 触屏 / 桌面窄窗按 iOS 27（正文 17、搜索胶囊高 36、输入框圆角 10 无描边）。
    final bool desktop = FushiAppleMetrics.of(context).desktop;
    final double macScale = fushiAppleMacScale(context);

    // 单行框收紧行高（1.25）；行距一律上下均分（[fushiFieldTextStyle]），
    // 均分放在合并调用方样式**之后**：调用方常传 inherit: false 的主题样式，
    // merge 会整个顶掉这里的设置，文字又落回行盒中线下方。
    final TextStyle style = fushiFieldTextStyle(
      (tt.bodyLarge ?? const TextStyle())
          .copyWith(
            fontSize: desktop ? 13 * macScale : 17,
            color: enabled ? apple.label : apple.tertiaryLabel,
            height: _c.maxLines == 1 ? 1.25 : null,
          )
          .merge(_c.style),
    );

    // inset grouped 分组的一整行（[FushiAppleFormRowScope]）：表单行。iOS 档只有
    // 标题时标题当占位（写法①），标题 + 占位都有时左标题、右侧右对齐输入
    // （写法②）；macOS 档有标题就是「左标题 + 右输入框」。
    final FushiAppleFormRowScope? rowScope = FushiAppleFormRowScope.maybeOf(
      context,
    );
    final bool formRow =
        rowScope != null &&
        decoration != null &&
        !_isSearchDecoration(decoration) &&
        !_c.expands;
    final String? formLabelText = formRow
        ? (rowScope.label ?? decoration.labelText)
        : null;
    final Widget? formLabel = !formRow
        ? null
        : (rowScope.label == null ? decoration.label : null) ??
              (formLabelText == null ? null : Text(formLabelText));
    final bool formLabeled =
        formLabel != null &&
        (desktop ||
            decoration!.hintText != null ||
            (rowScope!.label == null && decoration.label != null));
    final Widget editable = _buildEditable(
      context,
      style,
      hasError,
      placeholder: formRow && !formLabeled
          ? (decoration.hintText ?? formLabelText)
          : null,
      textAlign:
          formLabeled &&
              !desktop &&
              _c.maxLines == 1 &&
              _c.textAlign == TextAlign.start
          ? TextAlign.end
          : null,
    );

    // decoration: null 在 Material 下是「只有文字、没有任何装饰」；玻璃形态
    // 同样不加壳，保持调用方的布局意图（常见于自绘容器里的内嵌输入）。
    if (decoration == null) return editable;

    final bool dense = decoration.isDense ?? false;
    final bool search = _isSearchDecoration(decoration);
    // iOS 档页面顶部的独立搜索栏（44 高，见 [kFushiAppleSearchBarHeight]）。
    final bool largeSearch =
        search && !desktop && FushiAppleLargeSearchScope.of(context);
    final Color iconColor = enabled
        ? apple.secondaryLabel
        : apple.tertiaryLabel;
    final Color accent = hasError
        ? apple.destructive
        : (focused ? apple.accent : apple.secondaryLabel);

    Widget? affix(Widget? widget, String? text, TextStyle? textStyle) {
      if (widget != null) return widget;
      if (text == null) return null;
      return Text(
        text,
        style: style.copyWith(color: apple.secondaryLabel).merge(textStyle),
      );
    }

    Widget? iconSlot(Widget? icon) {
      if (icon == null) return null;
      return IconTheme.merge(
        data: IconThemeData(
          color: iconColor,
          size: desktop
              ? (search ? 14 : 15) * macScale
              : (largeSearch
                    ? kFushiAppleSearchBarIconSize
                    : (search ? 17 : (dense ? 18 : 20))),
        ),
        child: icon,
      );
    }

    // 搜索框的放大镜换成 SF 风格的 CupertinoIcons.search（iOS 搜索栏的
    // magnifyingglass），其余前缀图标原样。
    final Widget? prefixIcon = iconSlot(
      search && decoration.prefixIcon is! FushiSearchLeading
          ? const FushiIcon(CupertinoIcons.search)
          : decoration.prefixIcon,
    );
    // 搜索胶囊定高（iOS 36 / macOS 28）：调用方常把标准图标按钮（40–48 高）
    // 塞进 suffixIcon 当清除钮，它会把输入行撑高、在定高父级里溢出，文字随之
    // 偏离竖直中线（用户 2026-10-04「搜索框文字没有垂直居中」）。布局上只给
    // 尾部图标比胶囊矮 8 的高度，按钮本体照原尺寸居中绘制在上面
    // （OverflowBox），点按区不变小。
    final double searchHeight = desktop
        ? 28 * macScale
        : (largeSearch ? kFushiAppleSearchBarHeight : 36);
    Widget? suffixIcon = iconSlot(decoration.suffixIcon);
    if (search && suffixIcon != null && _c.maxLines == 1) {
      suffixIcon = _CappedHeightBox(
        height: searchHeight - 8,
        child: suffixIcon,
      );
    }
    final Widget? prefix = affix(
      decoration.prefix,
      decoration.prefixText,
      decoration.prefixStyle,
    );
    final Widget? suffix = affix(
      decoration.suffix,
      decoration.suffixText,
      decoration.suffixStyle,
    );
    final bool multiline = _c.maxLines != 1 || _c.expands;

    Widget row = Row(
      crossAxisAlignment: _c.expands
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.center,
      children: <Widget>[
        if (prefixIcon != null) ...<Widget>[
          prefixIcon,
          SizedBox(
            width: largeSearch
                ? kFushiAppleSearchBarIconGap
                : (search ? 6 : (dense ? 8 : 10)) * (desktop ? macScale : 1),
          ),
        ],
        if (prefix != null) prefix,
        Expanded(child: editable),
        if (suffix != null) suffix,
        if (suffixIcon != null) ...<Widget>[
          SizedBox(width: (dense ? 6 : 8) * (desktop ? macScale : 1)),
          suffixIcon,
        ],
      ],
    );
    if (multiline && !_c.expands) {
      row = Align(alignment: AlignmentDirectional.topStart, child: row);
    }

    // iOS 27：输入框是内容层控件——实色 tertiarySystemFill 底、圆角 10、无下划线
    // 无描边（roundedRect 文本框）；搜索框是同色的全胶囊（UISearchTextField，
    // 高 36）。macOS 27 宽窗：输入框是圆角 6 的白底（深色 tertiaryFill）+
    // 0.5px 分隔线描边（NSTextField bezel），搜索框是高 28 的灰填充胶囊
    // （NSSearchField）。都不是玻璃——玻璃只给浮在内容上的导航 / 控件层，所以
    // 不随玻璃画质档变化。调用方显式 filled + fillColor 时尊重它。
    final EdgeInsetsGeometry padding =
        decoration.contentPadding ??
        (search
            ? EdgeInsets.symmetric(
                horizontal: desktop
                    ? 8 * macScale
                    : (largeSearch
                          ? kFushiAppleSearchBarHorizontalPadding
                          : 10),
              )
            : (desktop
                  ? EdgeInsets.symmetric(
                      horizontal: 8 * macScale,
                      vertical: (dense ? 3 : 5) * macScale,
                    )
                  : EdgeInsets.symmetric(
                      horizontal: dense ? 10 : 12,
                      vertical: dense ? 7 : 11,
                    )));
    final Color? customFill = (decoration.filled ?? false)
        ? decoration.fillColor
        : null;
    final bool capsule = search && !multiline;
    final bool dark = theme.colorScheme.brightness == Brightness.dark;
    final bool macField = desktop && !search;
    final Color fill = customFill != null && customFill.a > 0
        ? customFill
        : (macField
              ? (dark ? apple.tertiaryFill : Colors.white)
              : apple.tertiaryFill);
    final BorderRadius shellRadius = BorderRadius.circular(
      capsule ? searchHeight / 2 : (desktop ? 6 * macScale : 10),
    );
    // 聚焦本身在 iOS 上没有描边（UISearchTextField / UITextField 触屏聚焦只亮光标）：
    // iOS 档只在键盘 / 手柄导航（traditional 高亮模式）落到输入框时给一圈细的强调色
    // 内环（1.5px、50% 透明、画在框内）；macOS 档是 NSSearchField / NSTextField 的
    // focus ring，成为第一响应者就亮，与指针 / 键盘无关。
    // 错误态 1px destructive；macOS 输入框静止态 0.5px 分隔线描边。
    final bool focusRing =
        enabled &&
        focused &&
        !hasError &&
        (desktop ||
            FocusManager.instance.highlightMode ==
                FocusHighlightMode.traditional);
    final Border? restingBorder = enabled && hasError
        ? Border.all(color: apple.destructive)
        : (macField ? Border.all(color: apple.separator, width: 0.5) : null);
    Widget shell = AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      padding: padding,
      // 搜索胶囊定高（文字更高时随文字长高），内容竖直居中。
      constraints: capsule
          ? BoxConstraints(minHeight: searchHeight)
          : const BoxConstraints(),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: shellRadius,
        border: restingBorder,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: shellRadius,
        border: focusRing
            ? Border.all(
                color: apple.accent.withValues(alpha: dark ? 0.6 : 0.5),
                width: 1.5,
              )
            : Border.all(color: Colors.transparent, width: 1.5),
      ),
      child: capsule
          ? Align(
              alignment: AlignmentDirectional.centerStart,
              heightFactor: 1,
              child: row,
            )
          : row,
    );
    if (decoration.constraints != null) {
      shell = ConstrainedBox(
        constraints: decoration.constraints!,
        child: shell,
      );
    }

    final TextStyle captionStyle = (tt.bodySmall ?? const TextStyle()).copyWith(
      color: apple.secondaryLabel,
    );
    final Widget? label =
        decoration.label ??
        (decoration.labelText == null ? null : Text(decoration.labelText!));
    final Widget? helperOrError = hasError
        ? (decoration.error ??
              Text(
                decoration.errorText!,
                maxLines: decoration.errorMaxLines,
                overflow: decoration.errorMaxLines == null
                    ? null
                    : TextOverflow.ellipsis,
                style: captionStyle
                    .copyWith(color: apple.destructive)
                    .merge(decoration.errorStyle),
              ))
        : (decoration.helper ??
              (decoration.helperText == null
                  ? null
                  : Text(
                      decoration.helperText!,
                      maxLines: decoration.helperMaxLines,
                      overflow: decoration.helperMaxLines == null
                          ? null
                          : TextOverflow.ellipsis,
                      style: captionStyle.merge(decoration.helperStyle),
                    )));
    final Widget? counter = _buildCounter(context, captionStyle);

    if (formRow) {
      final String? rowHelper = rowScope.helper;
      return _buildFormRow(
        context,
        field: desktop ? shell : row,
        leading: rowScope.leading,
        label: formLabeled ? formLabel : null,
        labelColor: enabled && hasError ? apple.destructive : apple.label,
        helperOrError:
            helperOrError ??
            (rowHelper == null ? null : Text(rowHelper, style: captionStyle)),
        counter: counter,
        multiline: multiline,
        focused: enabled && focused,
      );
    }

    Widget content = Column(
      mainAxisSize: _c.expands ? MainAxisSize.max : MainAxisSize.min,
      // 调用方常把单行框放进比字段本身更高的定高盒（库页 / 工具条搜索
      // `SizedBox(height: 40)` 而胶囊只有 36）：没有标题 / 辅助文字时让字段在
      // 多出的高度里竖直居中，而不是贴顶（贴顶时文字比盒子中线高 2px）。
      mainAxisAlignment:
          label == null && helperOrError == null && counter == null
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (label != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 6),
            child: DefaultTextStyle.merge(
              style: (tt.labelMedium ?? const TextStyle())
                  // iOS 的字段标题是小号灰字，聚焦不变色；只有错误态染红。
                  .copyWith(
                    color: enabled && hasError ? accent : apple.secondaryLabel,
                  )
                  .merge(focused ? decoration.floatingLabelStyle : null)
                  .merge(decoration.labelStyle),
              child: label,
            ),
          ),
        if (_c.expands) Expanded(child: shell) else shell,
        if (helperOrError != null || counter != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, end: 4, top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: helperOrError ?? const SizedBox.shrink()),
                if (counter != null) ...<Widget>[
                  const SizedBox(width: 8),
                  counter,
                ],
              ],
            ),
          ),
      ],
    );
    if (decoration.icon != null) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: label != null ? 30 : 12, right: 16),
            child: IconTheme.merge(
              data: IconThemeData(color: iconColor),
              child: decoration.icon!,
            ),
          ),
          Expanded(child: content),
        ],
      );
    }
    // Opacity 层恒在：按 enabled 增删会让内层输入框重挂。
    return Opacity(opacity: enabled ? 1 : 0.6, child: content);
  }

  /// inset grouped 分组里的一整行（[FushiAppleFormRowScope]）。
  ///
  /// iOS 档：行高 [FushiAppleMetrics.rowMinHeight]、左右 [FushiAppleMetrics.rowHorizontal]，
  /// [field] 是无壳的输入行（无填充、无描边），分隔线由分组画；键盘 / 手柄导航
  /// 落到行上时画一圈强调色描边（与 [FushiAppleRow] 的焦点描边同口径），触屏点
  /// 进来只有光标。macOS 档：[field] 是 NSTextField 式小框（自带聚焦环），左边
  /// 是行标题。说明 / 错误 / 计数排在行内下方，与行文字左对齐。
  Widget _buildFormRow(
    BuildContext context, {
    required Widget field,
    required Widget? leading,
    required Widget? label,
    required Color labelColor,
    required Widget? helperOrError,
    required Widget? counter,
    required bool multiline,
    required bool focused,
  }) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final bool desktop = metrics.desktop;
    final double scale = metrics.scale;
    Widget line = field;
    if (label != null) {
      line = Row(
        crossAxisAlignment: multiline
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: <Widget>[
          // 标题按内容宽，最多占一段定宽（长标题换行），其余给输入。
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: desktop ? 180 * scale : 150),
            child: Padding(
              // 多行时标题与输入首行对齐：macOS 输入框有 5 的上内边距。
              padding: EdgeInsets.only(
                top: multiline && desktop ? 5 * scale : 0,
              ),
              child: DefaultTextStyle.merge(
                style: metrics.titleStyle(context).copyWith(color: labelColor),
                child: label,
              ),
            ),
          ),
          SizedBox(width: (desktop ? 12 : 16) * scale),
          Expanded(child: field),
        ],
      );
    }
    if (leading != null) {
      line = Row(
        crossAxisAlignment: multiline
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: <Widget>[
          leading,
          Expanded(child: line),
        ],
      );
    }
    final bool keyboardFocus =
        focused &&
        !desktop &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final Widget body = Container(
      constraints: BoxConstraints(minHeight: metrics.rowMinHeight),
      padding: EdgeInsets.symmetric(
        horizontal: metrics.rowHorizontal,
        vertical: multiline
            ? (desktop ? 8 * scale : 11)
            : (desktop ? 4 * scale : 6),
      ),
      alignment: AlignmentDirectional.centerStart,
      foregroundDecoration: keyboardFocus
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: apple.accent, width: 2),
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          line,
          if (helperOrError != null || counter != null)
            Padding(
              padding: EdgeInsets.only(top: 4 * scale),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: helperOrError ?? const SizedBox.shrink()),
                  if (counter != null) ...<Widget>[
                    const SizedBox(width: 8),
                    counter,
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    // Opacity 层恒在：按 enabled 增删会让内层输入框重挂。
    return Opacity(opacity: _enabled ? 1 : 0.6, child: body);
  }
}

/// [TextFormField] 的设计系统分派版。
class FushiTextFormFieldControl extends StatelessWidget
    implements FushiAppleFormRowField {
  const FushiTextFormFieldControl({
    super.key,
    this.groupId = EditableText,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.forceErrorText,
    this.decoration = const InputDecoration(),
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction,
    this.style,
    this.strutStyle,
    this.textDirection,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.autofocus = false,
    this.readOnly = false,
    this.toolbarOptions,
    this.showCursor,
    this.obscuringCharacter = '•',
    this.obscureText = false,
    this.autocorrect = true,
    this.smartDashesType,
    this.smartQuotesType,
    this.enableSuggestions = true,
    this.maxLengthEnforcement,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.maxLength,
    this.onChanged,
    this.onTap,
    this.onTapAlwaysCalled = false,
    this.onTapOutside,
    this.onTapUpOutside,
    this.onEditingComplete,
    this.onFieldSubmitted,
    this.onSaved,
    this.validator,
    this.errorBuilder,
    this.inputFormatters,
    this.enabled,
    this.ignorePointers,
    this.cursorWidth = 2.0,
    this.cursorHeight,
    this.cursorRadius,
    this.cursorColor,
    this.cursorErrorColor,
    this.keyboardAppearance,
    this.scrollPadding = const EdgeInsets.all(20.0),
    this.enableInteractiveSelection,
    this.selectAllOnFocus,
    this.selectionControls,
    this.buildCounter,
    this.scrollPhysics,
    this.autofillHints,
    this.autovalidateMode,
    this.scrollController,
    this.restorationId,
    this.enableIMEPersonalizedLearning = true,
    this.mouseCursor,
    this.contextMenuBuilder = _fushiDefaultContextMenuBuilder,
    this.spellCheckConfiguration,
    this.magnifierConfiguration,
    this.undoController,
    this.onAppPrivateCommand,
    this.cursorOpacityAnimates,
    this.selectionHeightStyle,
    this.selectionWidthStyle,
    this.dragStartBehavior = DragStartBehavior.start,
    this.contentInsertionConfiguration,
    this.statesController,
    this.clipBehavior = Clip.hardEdge,
    this.scribbleEnabled = true,
    this.stylusHandwritingEnabled =
        EditableText.defaultStylusHandwritingEnabled,
    this.canRequestFocus = true,
    this.hintLocales,
  });

  final Object groupId;
  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final String? forceErrorText;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final TextInputAction? textInputAction;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextDirection? textDirection;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final bool autofocus;
  final bool readOnly;
  final ToolbarOptions? toolbarOptions;
  final bool? showCursor;
  final String obscuringCharacter;
  final bool obscureText;
  final bool autocorrect;
  final SmartDashesType? smartDashesType;
  final SmartQuotesType? smartQuotesType;
  final bool enableSuggestions;
  final MaxLengthEnforcement? maxLengthEnforcement;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final GestureTapCallback? onTap;
  final bool onTapAlwaysCalled;
  final TapRegionCallback? onTapOutside;
  final TapRegionUpCallback? onTapUpOutside;
  final VoidCallback? onEditingComplete;
  final ValueChanged<String>? onFieldSubmitted;
  final FormFieldSetter<String>? onSaved;
  final FormFieldValidator<String>? validator;
  final FormFieldErrorBuilder? errorBuilder;
  final List<TextInputFormatter>? inputFormatters;
  final bool? enabled;
  final bool? ignorePointers;
  final double cursorWidth;
  final double? cursorHeight;
  final Radius? cursorRadius;
  final Color? cursorColor;
  final Color? cursorErrorColor;
  final Brightness? keyboardAppearance;
  final EdgeInsets scrollPadding;
  final bool? enableInteractiveSelection;
  final bool? selectAllOnFocus;
  final TextSelectionControls? selectionControls;
  final InputCounterWidgetBuilder? buildCounter;
  final ScrollPhysics? scrollPhysics;
  final Iterable<String>? autofillHints;
  final AutovalidateMode? autovalidateMode;
  final ScrollController? scrollController;
  final String? restorationId;
  final bool enableIMEPersonalizedLearning;
  final MouseCursor? mouseCursor;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final SpellCheckConfiguration? spellCheckConfiguration;
  final TextMagnifierConfiguration? magnifierConfiguration;
  final UndoHistoryController? undoController;
  final AppPrivateCommandCallback? onAppPrivateCommand;
  final bool? cursorOpacityAnimates;
  final ui.BoxHeightStyle? selectionHeightStyle;
  final ui.BoxWidthStyle? selectionWidthStyle;
  final DragStartBehavior dragStartBehavior;
  final ContentInsertionConfiguration? contentInsertionConfiguration;
  final WidgetStatesController? statesController;
  final Clip clipBehavior;
  final bool scribbleEnabled;
  final bool stylusHandwritingEnabled;
  final bool canRequestFocus;
  final List<Locale>? hintLocales;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return _GlassTextFormField(config: this);
    }
    // MD3：活动指示线按状态以 FushiMotion 补间（FushiFieldIndicatorHost）。
    return FushiFieldIndicatorHost(
      enabled: (enabled ?? decoration?.enabled ?? true),
      error:
          (forceErrorText != null ||
          decoration?.errorText != null ||
          decoration?.error != null),
      builder: (BuildContext context) => TextFormField(
        groupId: groupId,
        controller: controller,
        initialValue: initialValue,
        focusNode: focusNode,
        forceErrorText: forceErrorText,
        decoration: _fushiFieldEvenHint(
          fushiMd3FieldDecoration(context, decoration),
        ),
        keyboardType: keyboardType,
        textCapitalization: textCapitalization,
        textInputAction: textInputAction,
        style: fushiFieldTextStyle(style),
        strutStyle: strutStyle,
        textDirection: textDirection,
        textAlign: textAlign,
        textAlignVertical:
            textAlignVertical ??
            (maxLines == 1 &&
                    decoration != null &&
                    _isSearchDecoration(decoration!)
                ? TextAlignVertical.center
                : null),
        autofocus: autofocus,
        readOnly: readOnly,
        toolbarOptions: toolbarOptions,
        showCursor: showCursor,
        obscuringCharacter: obscuringCharacter,
        obscureText: obscureText,
        autocorrect: autocorrect,
        smartDashesType: smartDashesType,
        smartQuotesType: smartQuotesType,
        enableSuggestions: enableSuggestions,
        maxLengthEnforcement: maxLengthEnforcement,
        maxLines: maxLines,
        minLines: minLines,
        expands: expands,
        maxLength: maxLength,
        onChanged: onChanged,
        onTap: onTap,
        onTapAlwaysCalled: onTapAlwaysCalled,
        onTapOutside: onTapOutside,
        onTapUpOutside: onTapUpOutside,
        onEditingComplete: onEditingComplete,
        onFieldSubmitted: onFieldSubmitted,
        onSaved: onSaved,
        validator: validator,
        errorBuilder: errorBuilder,
        inputFormatters: inputFormatters,
        enabled: enabled,
        ignorePointers: ignorePointers,
        cursorWidth: cursorWidth,
        cursorHeight: cursorHeight,
        cursorRadius: cursorRadius,
        cursorColor: cursorColor,
        cursorErrorColor: cursorErrorColor,
        keyboardAppearance: keyboardAppearance,
        scrollPadding: scrollPadding,
        enableInteractiveSelection: enableInteractiveSelection,
        selectAllOnFocus: selectAllOnFocus,
        selectionControls: selectionControls,
        buildCounter: buildCounter,
        scrollPhysics: scrollPhysics,
        autofillHints: autofillHints,
        autovalidateMode: autovalidateMode,
        scrollController: scrollController,
        restorationId: restorationId,
        enableIMEPersonalizedLearning: enableIMEPersonalizedLearning,
        mouseCursor: mouseCursor,
        contextMenuBuilder: contextMenuBuilder,
        spellCheckConfiguration: spellCheckConfiguration,
        magnifierConfiguration: magnifierConfiguration,
        undoController: undoController,
        onAppPrivateCommand: onAppPrivateCommand,
        cursorOpacityAnimates: cursorOpacityAnimates,
        selectionHeightStyle: selectionHeightStyle,
        selectionWidthStyle: selectionWidthStyle,
        dragStartBehavior: dragStartBehavior,
        contentInsertionConfiguration: contentInsertionConfiguration,
        statesController: statesController,
        clipBehavior: clipBehavior,
        scribbleEnabled: scribbleEnabled,
        stylusHandwritingEnabled: stylusHandwritingEnabled,
        canRequestFocus: canRequestFocus,
        hintLocales: hintLocales,
      ),
    );
  }
}

/// 玻璃形态的 TextFormField：与 Flutter 的 TextFormField 同构——一个
/// `FormField<String>`，状态里管理 controller 与 FormField 值的双向同步，
/// builder 里把校验错误写进 decoration 再交给玻璃输入框。所以 [Form] 的
/// validate / save / reset、autovalidateMode、forceErrorText 行为都与原控件一致。
class _GlassTextFormField extends FormField<String> {
  _GlassTextFormField({required this.config})
    : super(
        initialValue: config.controller != null
            ? config.controller!.text
            : (config.initialValue ?? ''),
        enabled: config.enabled ?? config.decoration?.enabled ?? true,
        autovalidateMode: config.autovalidateMode,
        forceErrorText: config.forceErrorText,
        onSaved: config.onSaved,
        validator: config.validator,
        errorBuilder: config.errorBuilder,
        restorationId: config.restorationId,
        builder: (FormFieldState<String> field) {
          final _GlassTextFormFieldState state =
              field as _GlassTextFormFieldState;
          InputDecoration decoration =
              config.decoration ?? const InputDecoration();
          final String? errorText = field.errorText;
          if (errorText != null) {
            decoration = config.errorBuilder != null
                ? decoration.copyWith(
                    error: config.errorBuilder!(state.context, errorText),
                  )
                : decoration.copyWith(errorText: errorText);
          }
          void onChangedHandler(String value) {
            field.didChange(value);
            config.onChanged?.call(value);
          }

          return _GlassTextFieldView(
            config: FushiTextFieldControl(
              groupId: config.groupId,
              controller: state._effectiveController,
              focusNode: config.focusNode,
              undoController: config.undoController,
              decoration: decoration,
              keyboardType: config.keyboardType,
              textInputAction: config.textInputAction,
              textCapitalization: config.textCapitalization,
              style: config.style,
              strutStyle: config.strutStyle,
              textAlign: config.textAlign,
              textAlignVertical: config.textAlignVertical,
              textDirection: config.textDirection,
              readOnly: config.readOnly,
              showCursor: config.showCursor,
              autofocus: config.autofocus,
              statesController: config.statesController,
              obscuringCharacter: config.obscuringCharacter,
              obscureText: config.obscureText,
              autocorrect: config.autocorrect,
              smartDashesType:
                  config.smartDashesType ??
                  (config.obscureText
                      ? SmartDashesType.disabled
                      : SmartDashesType.enabled),
              smartQuotesType:
                  config.smartQuotesType ??
                  (config.obscureText
                      ? SmartQuotesType.disabled
                      : SmartQuotesType.enabled),
              enableSuggestions: config.enableSuggestions,
              maxLines: config.maxLines,
              minLines: config.minLines,
              expands: config.expands,
              maxLength: config.maxLength,
              maxLengthEnforcement: config.maxLengthEnforcement,
              onChanged: onChangedHandler,
              onEditingComplete: config.onEditingComplete,
              onSubmitted: config.onFieldSubmitted,
              onAppPrivateCommand: config.onAppPrivateCommand,
              inputFormatters: config.inputFormatters,
              enabled: config.enabled ?? config.decoration?.enabled ?? true,
              ignorePointers: config.ignorePointers,
              cursorWidth: config.cursorWidth,
              cursorHeight: config.cursorHeight,
              cursorRadius: config.cursorRadius,
              cursorOpacityAnimates: config.cursorOpacityAnimates,
              cursorColor: config.cursorColor,
              cursorErrorColor: config.cursorErrorColor,
              selectionHeightStyle: config.selectionHeightStyle,
              selectionWidthStyle: config.selectionWidthStyle,
              keyboardAppearance: config.keyboardAppearance,
              scrollPadding: config.scrollPadding,
              dragStartBehavior: config.dragStartBehavior,
              enableInteractiveSelection: config.enableInteractiveSelection,
              selectAllOnFocus: config.selectAllOnFocus,
              selectionControls: config.selectionControls,
              onTap: config.onTap,
              onTapAlwaysCalled: config.onTapAlwaysCalled,
              onTapOutside: config.onTapOutside,
              onTapUpOutside: config.onTapUpOutside,
              mouseCursor: config.mouseCursor,
              buildCounter: config.buildCounter,
              scrollController: config.scrollController,
              scrollPhysics: config.scrollPhysics,
              autofillHints: config.autofillHints,
              contentInsertionConfiguration:
                  config.contentInsertionConfiguration,
              clipBehavior: config.clipBehavior,
              stylusHandwritingEnabled: config.stylusHandwritingEnabled,
              enableIMEPersonalizedLearning:
                  config.enableIMEPersonalizedLearning,
              contextMenuBuilder: config.contextMenuBuilder,
              canRequestFocus: config.canRequestFocus,
              spellCheckConfiguration: config.spellCheckConfiguration,
              magnifierConfiguration: config.magnifierConfiguration,
              hintLocales: config.hintLocales,
            ),
          );
        },
      );

  final FushiTextFormFieldControl config;

  @override
  FormFieldState<String> createState() => _GlassTextFormFieldState();
}

class _GlassTextFormFieldState extends FormFieldState<String> {
  TextEditingController? _controller;
  late final String? _initialValue;

  _GlassTextFormField get _field => super.widget as _GlassTextFormField;

  TextEditingController get _effectiveController =>
      _field.config.controller ?? _controller!;

  @override
  void initState() {
    super.initState();
    final TextEditingController? external = _field.config.controller;
    if (external == null) {
      _controller = TextEditingController(text: widget.initialValue);
    } else {
      external.addListener(_handleControllerChanged);
    }
    _initialValue = _field.config.initialValue ?? external?.text;
  }

  @override
  void didUpdateWidget(covariant FormField<String> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final TextEditingController? oldController =
        (oldWidget as _GlassTextFormField).config.controller;
    final TextEditingController? newController = _field.config.controller;
    if (oldController != newController) {
      oldController?.removeListener(_handleControllerChanged);
      newController?.addListener(_handleControllerChanged);
      if (oldController != null && newController == null) {
        _controller = TextEditingController.fromValue(oldController.value);
      }
      if (newController != null) {
        setValue(newController.text);
        if (oldController == null) {
          _controller?.dispose();
          _controller = null;
        }
      }
    }
  }

  @override
  void dispose() {
    _field.config.controller?.removeListener(_handleControllerChanged);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChange(String? value) {
    super.didChange(value);
    if (_effectiveController.text != value) {
      _effectiveController.value = TextEditingValue(text: value ?? '');
    }
  }

  @override
  void reset() {
    _effectiveController.value = TextEditingValue(text: _initialValue ?? '');
    super.reset();
    _field.config.onChanged?.call(_effectiveController.text);
  }

  void _handleControllerChanged() {
    if (_effectiveController.text != value) {
      didChange(_effectiveController.text);
    }
  }
}

/// 布局上只占 [height] 高（宽度随子组件）、子组件按自身高度竖直居中绘制的盒子：
/// 让搜索胶囊尾部塞进来的标准尺寸图标按钮不再撑高定高输入行。
class _CappedHeightBox extends SingleChildRenderObjectWidget {
  const _CappedHeightBox({required this.height, required Widget super.child});

  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCappedHeightBox(height);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCappedHeightBox renderObject,
  ) {
    renderObject.cap = height;
  }
}

class _RenderCappedHeightBox extends RenderShiftedBox {
  _RenderCappedHeightBox(this._cap) : super(null);

  double _cap;
  set cap(double value) {
    if (value == _cap) return;
    _cap = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final RenderBox? box = child;
    if (box == null) {
      size = constraints.constrain(Size(0, _cap));
      return;
    }
    box.layout(
      BoxConstraints(maxWidth: constraints.maxWidth, maxHeight: 48),
      parentUsesSize: true,
    );
    size = constraints.constrain(
      Size(box.size.width, box.size.height < _cap ? box.size.height : _cap),
    );
    (box.parentData! as BoxParentData).offset = Offset(
      0,
      (size.height - box.size.height) / 2,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // 按钮本体比布局盒高：在按钮自身范围内的点按照样命中。
    final RenderBox? box = child;
    if (box == null) return false;
    final Offset offset = (box.parentData! as BoxParentData).offset;
    final bool hit = result.addWithPaintOffset(
      offset: offset,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) =>
          box.hitTest(result, position: transformed),
    );
    if (hit) result.add(BoxHitTestEntry(this, position));
    return hit;
  }
}
