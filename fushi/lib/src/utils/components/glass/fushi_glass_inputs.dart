import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
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

Widget _cupertinoContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  return CupertinoAdaptiveTextSelectionToolbar.editableText(
    editableTextState: editableTextState,
  );
}

/// 装饰是不是「搜索框」：前缀图标是放大镜。iOS 上搜索框是全胶囊
/// （UISearchBar），普通输入框是圆角 10 的矩形——这是唯一能从调用点无侵入
/// 读出的信号。
bool _isSearchDecoration(InputDecoration decoration) {
  Widget? prefix = decoration.prefixIcon;
  // 调用点给放大镜自配留白（设置页 MD3 胶囊搜索栏的 `Padding(FushiIcon)`）时
  // 要看穿这层包装：认不出来就会把调用方写好的胶囊边框压成 12 圆角方框
  // （BUG-2958，Android 设置页搜索栏变成圆角矩形）。
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
  // ——MD3 退成 12 圆角方框、Apple 退成 48 高普通输入框（BUG-3045）。线框与
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
  final BorderRadius radius = BorderRadius.circular(search ? 999 : 12);
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
    return labelled && !search
        ? _FushiFilledFieldBorder(borderRadius: radius, borderSide: side)
        : OutlineInputBorder(borderRadius: radius, borderSide: side);
  }

  final EdgeInsetsGeometry? padding = search
      ? const EdgeInsets.symmetric(horizontal: 16, vertical: 10)
      : decoration.contentPadding;
  return decoration.copyWith(
    filled: true,
    fillColor: decoration.fillColor ?? cs.surfaceContainerHigh,
    // M3E 状态层：悬停 8% onSurface 叠在填充上（InputDecorator 把 hoverColor
    // 混进 fillColor），鼠标指上去看得见可输入。
    hoverColor:
        decoration.hoverColor ??
        cs.onSurface.withValues(alpha: kFushiFieldHoverStateOpacity),
    border: outline(),
    enabledBorder: outline(),
    disabledBorder: outline(),
    focusedBorder: outline(cs.primary, 2),
    errorBorder: outline(cs.error, 1.5),
    focusedErrorBorder: outline(cs.error, 2),
    hintStyle: decoration.hintStyle ?? TextStyle(color: cs.onSurfaceVariant),
    prefixIconColor: decoration.prefixIconColor ?? cs.onSurfaceVariant,
    suffixIconColor: decoration.suffixIconColor ?? cs.onSurfaceVariant,
    contentPadding: padding,
  );
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

/// MD3 填充式字段的边框：形状是全圆角矩形（填充按它裁），描边画一整圈，
/// 但 [isOutline] 为 false——InputDecorator 据此把浮起的标题放在填充块内部
/// 顶端（M3 filled text field），而不是骑在边框线上。见 [fushiMd3FieldDecoration]。
class _FushiFilledFieldBorder extends InputBorder {
  const _FushiFilledFieldBorder({
    required this.borderRadius,
    super.borderSide = BorderSide.none,
  });

  final BorderRadius borderRadius;

  @override
  bool get isOutline => false;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.width);

  @override
  _FushiFilledFieldBorder copyWith({BorderSide? borderSide}) =>
      _FushiFilledFieldBorder(
        borderRadius: borderRadius,
        borderSide: borderSide ?? this.borderSide,
      );

  @override
  ShapeBorder scale(double t) => _FushiFilledFieldBorder(
    borderRadius: borderRadius * t,
    borderSide: borderSide.scale(t),
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is _FushiFilledFieldBorder) {
      return _FushiFilledFieldBorder(
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
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
      );
    }
    return super.lerpTo(b, t);
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => Path()
    ..addRRect(
      borderRadius
          .resolve(textDirection)
          .toRRect(rect)
          .deflate(borderSide.width),
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
    if (borderSide.style == BorderStyle.none || borderSide.width == 0) return;
    final RRect outer = borderRadius.resolve(textDirection).toRRect(rect);
    canvas.drawRRect(outer.deflate(borderSide.width / 2), borderSide.toPaint());
  }

  @override
  bool operator ==(Object other) =>
      other is _FushiFilledFieldBorder &&
      other.borderSide == borderSide &&
      other.borderRadius == borderRadius;

  @override
  int get hashCode => Object.hash(borderSide, borderRadius);
}

/// [TextField] 的设计系统分派版。
class FushiTextFieldControl extends StatelessWidget {
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
    return TextField(
      groupId: groupId,
      controller: controller,
      focusNode: focusNode,
      undoController: undoController,
      decoration: fushiMd3FieldDecoration(context, decoration),
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      style: style,
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

  Widget _buildEditable(BuildContext context, TextStyle style, bool hasError) {
    final FushiAppleColors apple = appleColorsOf(context);
    final InputDecoration? decoration = _c.decoration;
    // 占位符与正文同字号、secondaryLabel 色（iOS placeholder）。
    final TextStyle hintStyle = style
        .copyWith(color: apple.secondaryLabel)
        .merge(decoration?.hintStyle);
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
      placeholder: decoration?.hintText,
      placeholderStyle: hintStyle,
      keyboardType: _c.keyboardType,
      textInputAction: _c.textInputAction,
      textCapitalization: _c.textCapitalization,
      style: style,
      strutStyle: _c.strutStyle,
      textAlign: _c.textAlign,
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

    // 桌面（macOS 尺度）正文 15，移动端 iOS 17。
    final TextStyle style =
        ((fushiAppleCompact(context) ? tt.bodyMedium : tt.bodyLarge) ??
                const TextStyle())
            .copyWith(
              color: enabled ? apple.label : apple.tertiaryLabel,
              // 单行框：正文主题行高 1.5 的行距按字体 ascent/descent 比例分配，
              // CJK 字体多分在下方，文字明显低于放大镜 / 胶囊中线。收紧行高并
              // 上下均分，文字与占位符落在框的光学中线上。
              height: _c.maxLines == 1 ? 1.25 : null,
              leadingDistribution: _c.maxLines == 1
                  ? TextLeadingDistribution.even
                  : null,
            )
            .merge(_c.style);

    final Widget editable = _buildEditable(context, style, hasError);

    // decoration: null 在 Material 下是「只有文字、没有任何装饰」；玻璃形态
    // 同样不加壳，保持调用方的布局意图（常见于自绘容器里的内嵌输入）。
    if (decoration == null) return editable;

    final bool dense = decoration.isDense ?? false;
    final bool search = _isSearchDecoration(decoration);
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
          size: search ? 17 : (dense ? 18 : 20),
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
    // 搜索胶囊定高 36：调用方常把标准图标按钮（40–48 高）塞进 suffixIcon 当
    // 清除钮，它会把输入行撑高、在定高父级里溢出，文字随之偏离竖直中线（用户
    // 2026-10-04「搜索框文字没有垂直居中」）。布局上只给尾部图标 28 高，按钮
    // 本体照原尺寸居中绘制在上面（OverflowBox），点按区不变小。
    Widget? suffixIcon = iconSlot(decoration.suffixIcon);
    if (search && suffixIcon != null && _c.maxLines == 1) {
      suffixIcon = _CappedHeightBox(height: 28, child: suffixIcon);
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
          SizedBox(width: search ? 6 : (dense ? 8 : 10)),
        ],
        if (prefix != null) prefix,
        Expanded(child: editable),
        if (suffix != null) suffix,
        if (suffixIcon != null) ...<Widget>[
          SizedBox(width: dense ? 6 : 8),
          suffixIcon,
        ],
      ],
    );
    if (multiline && !_c.expands) {
      row = Align(alignment: AlignmentDirectional.topStart, child: row);
    }

    // iOS 输入框是内容层控件：实色 tertiarySystemFill 底、圆角 10、无下划线
    // 无描边（iOS 26 的 roundedRect 文本框）；搜索框是高 36 的全胶囊（控件层，
    // 无色透明玻璃，见下）。调用方显式 filled + fillColor 时尊重它。
    final EdgeInsetsGeometry padding =
        decoration.contentPadding ??
        (search
            ? const EdgeInsets.symmetric(horizontal: 10)
            : EdgeInsets.symmetric(
                horizontal: dense ? 10 : 12,
                vertical: dense ? 7 : 11,
              ));
    final Color? customFill = (decoration.filled ?? false)
        ? decoration.fillColor
        : null;
    final bool capsule = search && !multiline;
    // 搜索胶囊是控件层（macOS 26 工具栏 / 侧栏顶的搜索框、iOS 26 的搜索
    // 胶囊）：无色透明液态玻璃，不铺 systemFill 灰底；普通输入框仍是内容层
    // 实色字段。调用方显式给了填充色时照旧实色。
    final bool glassSearch =
        capsule && !(customFill != null && customFill.a > 0);
    final bool dark = theme.colorScheme.brightness == Brightness.dark;
    // 深色下的玻璃搜索胶囊：无色透明玻璃（深色配方是黑 14%）压在纯黑分组底上
    // 等于隐形——只剩一枚放大镜飘着。静止态在玻璃里自绘一层 tertiarySystemFill
    // （iOS 深色 UISearchTextField 的底）+ 0.5px 低 alpha 细描边给出轮廓，文字
    // 始终在这层之上；浅色玻璃本身是白 62% 雾面 + 投影，轮廓清楚，不再叠灰。
    final Color fill = customFill != null && customFill.a > 0
        ? customFill
        : (glassSearch
              ? (dark ? apple.tertiaryFill : Colors.transparent)
              : apple.tertiaryFill);
    final BorderRadius shellRadius = BorderRadius.circular(capsule ? 18 : 10);
    // 聚焦本身在 iOS 上没有描边；这里只给一圈细的强调色内环（1.5px、画在框内），
    // 作为键盘 / 手柄导航落到输入框时的焦点指示。以前是 3px 外扩的 BoxShadow：
    // 单色强调色在深色下是白色，外扩一圈就是一道厚白边；搜索胶囊外面还包着
    // 玻璃，外扩部分被玻璃形状裁掉，而 BoxShadow 又会透过近乎透明的填充把整个
    // 胶囊染成一块灰 / 白（浅色聚焦时整枚胶囊变成灰块）。错误态 1px destructive。
    final Border? restingBorder = enabled && hasError
        ? Border.all(color: apple.destructive)
        : (glassSearch && dark
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 0.5,
                )
              : null);
    Widget shell = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: padding,
      // 搜索胶囊定高 36（文字更高时随文字长高），内容竖直居中。
      constraints: capsule
          ? const BoxConstraints(minHeight: 36)
          : const BoxConstraints(),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: shellRadius,
        border: restingBorder,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: shellRadius,
        border: enabled && focused && !hasError
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
    if (glassSearch) {
      shell = fushiClearGlassBezel(context, radius: 18, child: shell);
    }
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
}

/// [TextFormField] 的设计系统分派版。
class FushiTextFormFieldControl extends StatelessWidget {
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
    return TextFormField(
      groupId: groupId,
      controller: controller,
      initialValue: initialValue,
      focusNode: focusNode,
      forceErrorText: forceErrorText,
      decoration: fushiMd3FieldDecoration(context, decoration),
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      textInputAction: textInputAction,
      style: style,
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
