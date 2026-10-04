import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

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
  final Widget? prefix = decoration.prefixIcon;
  if (prefix is! Icon) return false;
  final IconData? icon = prefix.icon;
  return icon == Icons.search ||
      icon == Icons.search_rounded ||
      icon == Icons.search_outlined ||
      icon == CupertinoIcons.search;
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
      decoration: decoration,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textAlignVertical: textAlignVertical,
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

    final TextStyle style = (tt.bodyLarge ?? const TextStyle())
        .copyWith(color: enabled ? apple.label : apple.tertiaryLabel)
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
      search ? const FushiIcon(CupertinoIcons.search) : decoration.prefixIcon,
    );
    final Widget? suffixIcon = iconSlot(decoration.suffixIcon);
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
    // 无描边（iOS 26 的 roundedRect 文本框）；搜索框是高 36 的全胶囊
    // （UISearchBar 的 searchTextField，systemFill 底）。**不是玻璃**——玻璃
    // 只给浮在内容上的导航与控件层。调用方显式 filled + fillColor 时尊重它。
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
    final Color fill = customFill != null && customFill.a > 0
        ? customFill
        : (search ? apple.fill : apple.tertiaryFill);
    final bool capsule = search && !multiline;
    // 聚焦本身在 iOS 上没有描边；这里只给一圈极淡的强调色光圈，作为键盘 /
    // 手柄导航落到输入框时的焦点指示。错误态用 1px destructive 描边。
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
        borderRadius: BorderRadius.circular(capsule ? 18 : 10),
        border: enabled && hasError
            ? Border.all(color: apple.destructive)
            : null,
        boxShadow: enabled && focused && !hasError
            ? <BoxShadow>[
                BoxShadow(
                  color: apple.accent.withValues(alpha: 0.28),
                  spreadRadius: 3,
                ),
              ]
            : const <BoxShadow>[],
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

    Widget content = Column(
      mainAxisSize: _c.expands ? MainAxisSize.max : MainAxisSize.min,
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
      decoration: decoration,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      textInputAction: textInputAction,
      style: style,
      strutStyle: strutStyle,
      textDirection: textDirection,
      textAlign: textAlign,
      textAlignVertical: textAlignVertical,
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
