import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:macos_ui/macos_ui.dart'
    show MacosTextField, MacosIcon, OverlayVisibilityMode;
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/focus/page_scroll_registry.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_gamepad_keyboard.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_motion_tokens.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

class HibikiCard extends StatefulWidget {
  const HibikiCard({
    required this.child,
    super.key,
    this.padding,
    this.margin,
    this.color,
    this.borderColor,
    this.borderRadius,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.focusId,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final Color? borderColor;
  final BorderRadius? borderRadius;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 桌面端鼠标右键（secondary tap）触发，通常映射到与 [onLongPress] 相同的
  /// 上下文菜单。触摸/手柄设备没有 secondary tap，故配线全平台无副作用。
  final VoidCallback? onSecondaryTap;
  final HibikiFocusId? focusId;

  @override
  State<HibikiCard> createState() => _HibikiCardState();
}

class _HibikiCardState extends State<HibikiCard> {
  late final HibikiFocusId _fallbackFocusId = HibikiFocusId(
    'hibiki-card-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final Color effectiveColor = widget.color ??
        (widget.selected ? tokens.surfaces.selected : tokens.surfaces.card);
    final BorderRadius radius = widget.borderRadius ?? tokens.radii.cardRadius;
    // eink 把所有 surface container 塌缩为背景色（theme_notifier eink scheme），
    // 卡片没有边就与页面融为一体；主题层只给裸 Card 补了描边（CardThemeData），
    // HibikiCard 在这里自己补。选中态加粗到 2px——eink 下 selected 填充色同样
    // 塌缩，边宽是唯一可辨的选中信号。
    final BorderSide side = widget.borderColor != null
        ? BorderSide(color: widget.borderColor!)
        : (eink
            ? BorderSide(
                color: tokens.surfaces.outline,
                width: widget.selected ? 2 : 1,
              )
            : BorderSide.none);
    final Widget content = Padding(
      padding: widget.padding ?? EdgeInsets.all(tokens.spacing.card),
      child: widget.child,
    );
    final Widget card = Padding(
      padding: widget.margin ?? EdgeInsets.zero,
      child: AnimatedContainer(
        duration: einkSafeDuration(context, hibikiMd3StateDuration),
        curve: hibikiMd3StateCurve,
        decoration: ShapeDecoration(
          color: effectiveColor,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: side,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: widget.onTap == null &&
                  widget.onLongPress == null &&
                  widget.onSecondaryTap == null
              ? content
              : InkWell(
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  onSecondaryTap: widget.onSecondaryTap,
                  child: content,
                ),
        ),
      ),
    );
    if (widget.onTap == null) return card;
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return card;

    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: widget.focusId ?? _fallbackFocusId,
        child: card,
      ),
    );
  }
}

enum HibikiListDensity { standard, compact }

/// 选中态高亮形状：fill = 满宽方角（平铺列表），pill = 内缩圆角（导航列表）。
enum HibikiListItemSelectedShape { fill, pill }

class HibikiListItem extends StatefulWidget {
  const HibikiListItem({
    required this.title,
    super.key,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.selectedShape = HibikiListItemSelectedShape.fill,
    this.onTap,
    this.minHeight,
    this.density = HibikiListDensity.standard,
    this.padding,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 2,
    this.focusId,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final HibikiListItemSelectedShape selectedShape;
  final VoidCallback? onTap;
  final double? minHeight;
  final HibikiListDensity density;
  final EdgeInsetsGeometry? padding;

  /// 标题最多几行，默认 1。
  ///
  /// BUG-1177 调查记录：曾把默认值改成 2（因为列表项承载的正是书名、视频名、词典名
  /// 这类长文本，单行 ellipsis 在窄屏上只看得到开头几个字）。**该改动已回退**：
  /// 本组件自身行高虽只有 minHeight 下限，但相当多调用点把它放在固定高度的容器里
  /// （golden `list_tile_narrow` 即在 150×80 的盒子里复现出 overflow 红条），窄容器
  /// 里标题一换行就会撑破父容器。所以放宽必须逐调用点显式进行——只在父容器高度自由
  /// 的地方传 `titleMaxLines: 2`，而不是改默认值连带影响每一个既有调用点。
  final int titleMaxLines;
  final int subtitleMaxLines;
  final HibikiFocusId? focusId;

  @override
  State<HibikiListItem> createState() => _HibikiListItemState();
}

class _HibikiListItemState extends State<HibikiListItem> {
  late final HibikiFocusId _fallbackFocusId = HibikiFocusId(
    'hibiki-list-item-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color color =
        widget.selected ? tokens.surfaces.selected : Colors.transparent;
    final Color selectedForeground = tokens.surfaces.primary;
    final Color primaryForeground =
        widget.selected ? selectedForeground : tokens.surfaces.onSurface;
    final Color secondaryForeground =
        widget.selected ? selectedForeground : tokens.surfaces.onVariant;
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      color: primaryForeground,
      fontWeight:
          widget.selected ? FontWeight.w700 : tokens.type.listTitle.fontWeight,
    );
    final TextStyle subtitleStyle = tokens.type.listSubtitle.copyWith(
      color: secondaryForeground,
      fontWeight: widget.selected
          ? FontWeight.w600
          : tokens.type.listSubtitle.fontWeight,
    );
    final TextStyle metadataStyle = tokens.type.metadata.copyWith(
      color: secondaryForeground,
      fontWeight:
          widget.selected ? FontWeight.w700 : tokens.type.metadata.fontWeight,
    );
    final double resolvedMinHeight = widget.minHeight ??
        switch (widget.density) {
          HibikiListDensity.standard => tokens.density.listMinHeight,
          HibikiListDensity.compact => tokens.density.compactListMinHeight,
        };
    final Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: resolvedMinHeight),
      child: Padding(
        padding: widget.padding ??
            EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.rowVertical,
            ),
        child: Row(
          children: <Widget>[
            if (widget.leading != null) ...<Widget>[
              IconTheme.merge(
                data: IconThemeData(color: secondaryForeground),
                child: widget.leading!,
              ),
              SizedBox(width: tokens.spacing.gap + 4),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  DefaultTextStyle.merge(
                    style: titleStyle,
                    maxLines: widget.titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    child: widget.title,
                  ),
                  if (widget.subtitle != null)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.spacing.gap / 4),
                      child: DefaultTextStyle.merge(
                        style: subtitleStyle,
                        maxLines: widget.subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        child: widget.subtitle!,
                      ),
                    ),
                ],
              ),
            ),
            if (widget.trailing != null) ...<Widget>[
              SizedBox(width: tokens.spacing.gap + 4),
              DefaultTextStyle.merge(
                style: metadataStyle,
                child: IconTheme.merge(
                  data: IconThemeData(color: secondaryForeground),
                  child: widget.trailing!,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    final bool pill = widget.selectedShape == HibikiListItemSelectedShape.pill;
    final BorderRadius? highlightRadius =
        pill ? tokens.radii.groupRadius : null;
    final BoxBorder? pillBorder = widget.selected
        ? Border.all(
            color: tokens.surfaces.primary.withValues(alpha: 0.20),
          )
        : null;
    final Widget material = AnimatedContainer(
      duration: hibikiMd3StateDuration,
      curve: hibikiMd3StateCurve,
      margin: pill
          ? EdgeInsets.symmetric(horizontal: tokens.spacing.gap)
          : EdgeInsets.zero,
      color: pill ? null : color,
      decoration: pill
          ? BoxDecoration(
              color: color,
              borderRadius: highlightRadius,
              border: pillBorder,
            )
          : null,
      child: Material(
        type: MaterialType.transparency,
        child: widget.onTap == null
            ? content
            : InkWell(
                onTap: widget.onTap,
                borderRadius: highlightRadius,
                child: content,
              ),
      ),
    );
    if (widget.onTap == null) return material;

    final HibikiFocusId effectiveFocusId = widget.focusId ?? _fallbackFocusId;
    final Widget target = Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: effectiveFocusId,
        child: material,
      ),
    );
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return material;
    return target;
  }
}

class HibikiSearchField extends StatelessWidget {
  const HibikiSearchField({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
    required this.onSubmitted,
    super.key,
    this.fieldKey,
    this.clearButtonKey,
    this.focusId,
    this.onClear,
  });

  final Key? fieldKey;
  final Key? clearButtonKey;
  final HibikiFocusId? focusId;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget searchBar;
    if (isMacosPlatform(context)) {
      // macOS-native: MacosTextField maps the search field faithfully —
      // search-icon prefix, native clear button (clearButtonMode), and it keeps
      // onSubmitted (MacosSearchField drops it, which would break enter-to-search).
      searchBar = MacosTextField(
        key: fieldKey,
        controller: controller,
        focusNode: focusNode,
        placeholder: hintText,
        prefix: const Padding(
          padding: EdgeInsets.only(left: 6, right: 2),
          child: MacosIcon(CupertinoIcons.search),
        ),
        clearButtonMode: OverlayVisibilityMode.editing,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      );
    } else {
      searchBar = ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final Widget? inputSuffix = _hibikiTextFieldInputSuffix(
            context: context,
            controller: controller,
            onChanged: onChanged,
          );
          final List<Widget> trailing = <Widget>[
            if (onClear != null && value.text.isNotEmpty)
              HibikiIconButton(
                key: clearButtonKey,
                icon: Icons.close,
                tooltip: t.clear,
                onTap: () {
                  onClear?.call();
                  if (focusNode.canRequestFocus) {
                    focusNode.requestFocus();
                  }
                },
              ),
            if (inputSuffix != null) inputSuffix,
          ];
          return SearchBar(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            hintText: hintText,
            leading: const Icon(Icons.search),
            trailing: trailing.isEmpty ? null : trailing,
            elevation: const WidgetStatePropertyAll<double>(0),
            backgroundColor:
                WidgetStatePropertyAll<Color>(tokens.surfaces.search),
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(borderRadius: tokens.radii.controlRadius),
            ),
            textStyle: WidgetStatePropertyAll<TextStyle>(tokens.type.listTitle),
            hintStyle:
                WidgetStatePropertyAll<TextStyle>(tokens.type.listSubtitle),
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          );
        },
      );
    }
    if (focusId == null) return searchBar;
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return searchBar;
    return HibikiFocusRegistration(
      id: focusId!,
      focusNode: focusNode,
      child: searchBar,
    );
  }
}

class HibikiTextField extends StatefulWidget {
  const HibikiTextField({
    super.key,
    this.controller,
    this.initialValue,
    this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.obscureText = false,
    this.hintText,
    this.labelText,
    this.suffixText,
    this.keyboardType = TextInputType.text,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.suffixIcon,
    this.prefixIcon,
    this.maxLines = 1,
    this.minLines,
    this.expands = false,
    this.textAlignVertical,
    this.style,
    this.contentPadding,
    this.focusId,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool readOnly;
  final bool obscureText;
  final String? hintText;
  final String? labelText;
  final String? suffixText;
  final TextInputType keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffixIcon;
  final Widget? prefixIcon;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final TextAlignVertical? textAlignVertical;
  final TextStyle? style;
  final EdgeInsetsGeometry? contentPadding;
  final HibikiFocusId? focusId;

  @override
  State<HibikiTextField> createState() => _HibikiTextFieldState();
}

class _HibikiTextFieldState extends State<HibikiTextField> {
  late final FocusNode _ownedFocusNode = FocusNode(
    debugLabel: widget.hintText ?? widget.labelText ?? 'hibiki-text-field',
  );

  FocusNode get _effectiveFocusNode => widget.focusNode ?? _ownedFocusNode;

  @override
  void dispose() {
    _ownedFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget? effectiveSuffix = widget.suffixIcon ??
        _hibikiTextFieldInputSuffix(
          context: context,
          controller: widget.readOnly ? null : widget.controller,
          onChanged: widget.onChanged,
        );
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: tokens.radii.cardRadius,
      borderSide: BorderSide(color: tokens.surfaces.outline),
    );
    final TextFormField textField = TextFormField(
      controller: widget.controller,
      initialValue: widget.initialValue,
      focusNode: _effectiveFocusNode,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      maxLines: widget.expands ? null : widget.maxLines,
      minLines: widget.minLines,
      expands: widget.expands,
      textAlignVertical: widget.textAlignVertical,
      style: widget.style ?? tokens.type.listTitle,
      decoration: InputDecoration(
        hintText: widget.hintText,
        labelText: widget.labelText,
        suffixText: widget.suffixText,
        hintStyle: tokens.type.listSubtitle,
        labelStyle: tokens.type.metadata,
        floatingLabelStyle: tokens.type.sectionLabel,
        filled: true,
        fillColor: tokens.surfaces.search,
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: tokens.surfaces.primary, width: 2),
        ),
        contentPadding: widget.contentPadding ??
            EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.rowVertical,
            ),
        suffixIcon: effectiveSuffix,
        prefixIcon: widget.prefixIcon,
      ),
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
    );
    if (widget.focusId == null) return textField;
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return textField;
    return HibikiFocusRegistration(
      id: widget.focusId!,
      focusNode: _effectiveFocusNode,
      child: textField,
    );
  }
}

/// The input-assist suffix icon for a text field. On desktop (no system IME) it
/// opens the on-screen [showGamepadKeyboard]; on mobile it offers one-tap
/// clipboard paste (the system IME types, but paste otherwise needs a
/// long-press). [onChanged] is forwarded so a programmatic edit (on-screen
/// keyboard input or paste) still updates reactive fields — Flutter does not
/// fire `onChanged` on programmatic controller mutations.
Widget? _hibikiTextFieldInputSuffix({
  required BuildContext context,
  required TextEditingController? controller,
  ValueChanged<String>? onChanged,
}) {
  if (controller == null) return null;
  final TargetPlatform platform = Theme.of(context).platform;
  final bool isDesktop = platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux ||
      platform == TargetPlatform.macOS;
  if (isDesktop) {
    return HibikiIconButton(
      icon: Icons.keyboard_outlined,
      tooltip: t.on_screen_keyboard,
      onTap: () =>
          showGamepadKeyboard(context, controller, onChanged: onChanged),
    );
  }
  return HibikiIconButton(
    icon: Icons.content_paste_outlined,
    tooltip: t.paste,
    onTap: () async {
      if (await gamepadKeyboardPaste(controller)) {
        onChanged?.call(controller.text);
      }
    },
  );
}

class HibikiSelectableChip extends StatelessWidget {
  const HibikiSelectableChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
    this.avatar,
    this.leadingIcon,
    this.tooltip,
    this.focusId,
    this.allowLabelOverflow = false,
    this.iconOnly = false,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? avatar;
  final IconData? leadingIcon;
  final String? tooltip;
  final HibikiFocusId? focusId;

  /// 仅图标模式（TODO-640）：置 true 时 chip 只渲染 [leadingIcon]、不显示文字标签，
  /// 把横排「图标 + 文字」压成紧凑「纯图标」（解决顶栏挤不下 / 显示不全）。文字说明
  /// 通过 hover / 长按 [Tooltip] 呈现：未显式传 [tooltip] 时回退用 [label] 作 tooltip，
  /// 保证图标语义可读。需要 [leadingIcon] 非空（否则退化为普通文字 chip）。

  /// 默认 false：标签单行 + 省略号（标签筛选条等密集横排，宽度受限时优先省略）。
  /// 置 true：标签不省略、按固有宽度完整渲染（横滑分类条等空间充裕、标签必须可读的
  /// 场景，如视频设置顶部分类条 TODO-556）。Material [ChoiceChip] 给 label 的约束
  /// 上界由 chip 自身布局推导（即便在横向无界滚动里也是有限值），故单纯靠无界宽度无法
  /// 避免省略；改 [Text.overflow] 为 visible + softWrap:false 才能让 chip 随固有宽度撑开。
  final bool allowLabelOverflow;

  /// 见构造器：仅图标模式（TODO-640），需 [leadingIcon] 非空才生效。
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color foreground =
        selected ? colors.onPrimaryContainer : tokens.surfaces.onSurface;
    // 仅图标模式（TODO-640）：图标当作 chip 的 label（不再放进 avatar + 文字），
    // chip 收成正方裸图标；需 leadingIcon 非空才生效，否则退化为普通文字 chip。
    final bool effectiveIconOnly = iconOnly && leadingIcon != null;
    final Widget? effectiveAvatar = effectiveIconOnly
        ? null
        : (avatar ??
            (leadingIcon == null ? null : Icon(leadingIcon, size: 18)));
    final Widget labelWidget = effectiveIconOnly
        ? Icon(leadingIcon, size: 18, color: foreground)
        : Text(
            label,
            maxLines: 1,
            softWrap: !allowLabelOverflow,
            overflow: allowLabelOverflow
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
          );
    final ChoiceChip chip = ChoiceChip(
      avatar: effectiveAvatar,
      label: labelWidget,
      // 仅图标模式下 label 是 Icon，去掉 ChoiceChip 默认 label padding 让图标居中收紧。
      labelPadding: effectiveIconOnly ? EdgeInsets.zero : null,
      selected: selected,
      showCheckmark: false,
      selectedColor: colors.primaryContainer,
      backgroundColor: Colors.transparent,
      labelStyle: tokens.type.controlLabel.copyWith(color: foreground),
      side: BorderSide(
        color: selected ? colors.primaryContainer : colors.outlineVariant,
      ),
      shape: RoundedRectangleBorder(borderRadius: tokens.radii.chipRadius),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: onSelected,
    );
    // 仅图标模式默认用 label 作 tooltip（图标语义靠 hover / 长按文字说明），
    // 显式 tooltip 优先。普通模式仍按传入 tooltip（null 则不包 Tooltip）。
    final String? effectiveTooltip =
        tooltip ?? (effectiveIconOnly ? label : null);
    final Widget withTooltip = effectiveTooltip == null
        ? chip
        : Tooltip(message: effectiveTooltip, child: chip);
    if (focusId == null) return withTooltip;
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return withTooltip;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onSelected?.call(!selected);
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: focusId!,
        enabled: onSelected != null,
        child: withTooltip,
      ),
    );
  }
}

class HibikiActionChip extends StatelessWidget {
  const HibikiActionChip({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
    this.focusId,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final HibikiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final OutlinedButton button = OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.primary,
        side: BorderSide(color: colors.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: tokens.radii.chipRadius),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.type.controlLabel,
      ),
    );
    if (focusId == null) return button;
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return button;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: focusId!,
        child: button,
      ),
    );
  }
}

enum HibikiTagChipTone { filled, surface }

class HibikiTagChip extends StatefulWidget {
  const HibikiTagChip({
    required this.label,
    super.key,
    this.color,
    this.selected = false,
    this.dimmed = false,
    this.tone = HibikiTagChipTone.filled,
    this.onTap,
    this.onDeleted,
    this.focusId,
  });

  final String label;
  final Color? color;
  final bool selected;
  final bool dimmed;
  final HibikiTagChipTone tone;
  final VoidCallback? onTap;
  final VoidCallback? onDeleted;
  final HibikiFocusId? focusId;

  @override
  State<HibikiTagChip> createState() => _HibikiTagChipState();
}

class _HibikiTagChipState extends State<HibikiTagChip> {
  /// Stable derived id so a tappable chip is a gamepad/keyboard focus target by
  /// default — Stateful (not Stateless) so identityHashCode is stable across
  /// rebuilds. Mirrors HibikiCard / HibikiListItem.
  late final HibikiFocusId _fallbackFocusId =
      HibikiFocusId('hibiki-tag-chip-${identityHashCode(this)}');

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color tagColor = widget.color ?? colors.primary;
    final Color baseColor = widget.color ??
        (widget.selected ? colors.primaryContainer : tokens.surfaces.overlay);
    final Color background = switch (widget.tone) {
      HibikiTagChipTone.filled => widget.dimmed
          ? baseColor.withValues(alpha: 0.44)
          : baseColor.withValues(alpha: widget.color == null ? 1 : 0.88),
      HibikiTagChipTone.surface => widget.selected
          ? tagColor.withValues(alpha: widget.dimmed ? 0.12 : 0.2)
          : tokens.surfaces.overlay.withValues(alpha: widget.dimmed ? 0.44 : 1),
    };
    final Color foreground = switch (widget.tone) {
      HibikiTagChipTone.filled => _foregroundFor(background),
      HibikiTagChipTone.surface => widget.dimmed
          ? colors.onSurface.withValues(alpha: 0.4)
          : colors.onSurface,
    };
    final BoxBorder? border = widget.selected
        ? Border.all(
            color: widget.tone == HibikiTagChipTone.surface
                ? tagColor
                : colors.primary,
          )
        : null;
    final Text labelText = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: tokens.type.metadata.copyWith(
        color: foreground,
        fontWeight: FontWeight.w600,
      ),
    );
    final List<Widget> contentChildren = <Widget>[
      if (widget.tone == HibikiTagChipTone.surface &&
          widget.color != null) ...<Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
          child: const SizedBox(width: 10, height: 10),
        ),
        SizedBox(width: tokens.spacing.gap * 0.625),
      ],
      Flexible(child: labelText),
      if (widget.onDeleted != null) ...<Widget>[
        SizedBox(width: tokens.spacing.gap * 0.375),
        InkWell(
          borderRadius: tokens.radii.chipRadius,
          onTap: widget.onDeleted,
          child: Icon(
            Icons.close,
            size: 14,
            color: foreground,
          ),
        ),
      ],
    ];
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: contentChildren,
    );
    final Widget chip = AnimatedContainer(
      duration: hibikiMd3StateDuration,
      curve: hibikiMd3StateCurve,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.gap,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: tokens.radii.chipRadius,
        border: border,
      ),
      child: content,
    );
    final Widget surface = widget.onTap == null
        ? chip
        : Material(
            type: MaterialType.transparency,
            borderRadius: tokens.radii.chipRadius,
            child: InkWell(
              borderRadius: tokens.radii.chipRadius,
              onTap: widget.onTap,
              child: chip,
            ),
          );
    if (widget.onTap == null && widget.onDeleted == null) return surface;
    // Outside a HibikiFocusRoot stay a bare tappable chip (zero overhead).
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return surface;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) {
            if (intent.button != GamepadButton.x || widget.onDeleted == null) {
              return false;
            }
            widget.onDeleted!();
            return true;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: widget.focusId ?? _fallbackFocusId,
        child: surface,
      ),
    );
  }

  static Color _foregroundFor(Color background) {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black;
  }
}

class HibikiBadge extends StatelessWidget {
  const HibikiBadge({
    required this.icon,
    super.key,
    this.background,
    this.foreground,
    this.size = 14,
    this.padding,
  });

  final IconData icon;
  final Color? background;
  final Color? foreground;
  final double size;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: padding ?? EdgeInsets.all(tokens.spacing.gap / 2),
      decoration: BoxDecoration(
        color: background ?? colors.primaryContainer,
        borderRadius: tokens.radii.chipRadius,
      ),
      child: Icon(
        icon,
        size: size,
        color: foreground ?? colors.onPrimaryContainer,
      ),
    );
  }
}

class HibikiModalSheetFrame extends StatelessWidget {
  const HibikiModalSheetFrame({
    required this.body,
    super.key,
    this.title,
    this.subtitle,
    this.leadingIcon,
    this.footer,
    this.maxHeightFactor,
    this.bodyPadding,
    this.footerPadding,
    this.scrollable = false,
  });

  final Widget body;
  final String? title;
  final String? subtitle;
  final IconData? leadingIcon;
  final Widget? footer;
  final double? maxHeightFactor;
  final EdgeInsetsGeometry? bodyPadding;
  final EdgeInsetsGeometry? footerPadding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<Widget> children = <Widget>[
      if (_hasHeader) _buildHeader(tokens, colors),
      _buildBody(tokens),
      if (footer != null) ...<Widget>[
        Divider(height: 1, thickness: 1, color: tokens.surfaces.outline),
        Padding(
          padding: footerPadding ??
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                0,
                tokens.spacing.page,
                tokens.spacing.page,
              ),
          child: footer!,
        ),
      ],
    ];

    final Widget sheet = SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
    final double? heightFactor = maxHeightFactor;
    if (heightFactor == null) return sheet;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * heightFactor,
      ),
      child: sheet,
    );
  }

  bool get _hasHeader =>
      title != null || subtitle != null || leadingIcon != null;

  Widget _buildHeader(HibikiDesignTokens tokens, ColorScheme colors) {
    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (title != null)
          Text(
            title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.listTitle.copyWith(fontWeight: FontWeight.w600),
          ),
        if (subtitle != null)
          Padding(
            padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
            child: Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listSubtitle,
            ),
          ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.page,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          if (leadingIcon != null) ...<Widget>[
            Container(
              padding: EdgeInsets.all(tokens.spacing.gap),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: tokens.radii.controlRadius,
              ),
              child: Icon(
                leadingIcon,
                color: colors.onPrimaryContainer,
                size: 20,
              ),
            ),
            SizedBox(width: tokens.spacing.gap + 4),
          ],
          Expanded(child: text),
        ],
      ),
    );
  }

  Widget _buildBody(HibikiDesignTokens tokens) {
    final Widget padded = Padding(
      padding: bodyPadding ?? EdgeInsets.zero,
      child: body,
    );
    // The body is always [Flexible] so it is bounded by the sheet's height
    // constraint rather than overflowing the Column. The only difference is who
    // provides the scroll viewport: with [scrollable] the frame wraps it in a
    // SingleChildScrollView; without it the caller supplies its own scroller
    // (ListView/SingleChildScrollView) which then scrolls within the bound.
    // Returning a non-flexible body here let a caller-scroller take its full
    // intrinsic height and overflow on short screens (HBK-AUDIT, switch dialog).
    return Flexible(
      child: scrollable ? SingleChildScrollView(child: padded) : padded,
    );
  }
}

/// 一个可以在窄屏上被折进溢出菜单的 AppBar 动作。
///
/// [label] 既是宽屏 [IconButton] 的 tooltip，也是窄屏菜单项的文案——同一句话，
/// 不需要为「折叠版」另造 i18n key。[onPressed] 为 null 时该项禁用（菜单项同样
/// 置灰），语义与 [IconButton.onPressed] 一致。
class HibikiAppBarAction {
  const HibikiAppBarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// 窄屏下把次要 AppBar 动作折进「更多」溢出菜单，把宽度让回给标题。
///
/// BUG-1177：合集详情、网格详情、texthooker 这些页面的 AppBar 各挂了 4~5 个动作。
/// Material 的 AppBar 先满足 actions 的固有宽度，再把剩下的给 title——320dp 上
/// 5 个动作 + 返回键就吃掉约 296px，标题只剩二十几像素，合集名/书名彻底看不见
/// （不报错，就是没了）。动作数量本身是合理的，错的是「无论屏多窄都全部平铺」。
///
/// [alwaysVisible] 放最高频、必须一眼可点的动作（如排序）；[collapsible] 里的
/// 在宽屏逐个平铺，窄屏收进一个 [PopupMenuButton]。折叠后动作一个都没少，只是
/// 多一次点击——比标题消失划算得多。
List<Widget> narrowAwareAppBarActions(
  BuildContext context, {
  required List<HibikiAppBarAction> collapsible,
  List<Widget> alwaysVisible = const <Widget>[],
  double narrowWidth = 480,
}) {
  final double width = MediaQuery.sizeOf(context).width;
  final bool narrow = width.isFinite && width < narrowWidth;
  if (!narrow || collapsible.length < 2) {
    return <Widget>[
      ...alwaysVisible,
      for (final HibikiAppBarAction action in collapsible)
        IconButton(
          tooltip: action.label,
          icon: Icon(action.icon),
          onPressed: action.onPressed,
        ),
    ];
  }
  return <Widget>[
    ...alwaysVisible,
    PopupMenuButton<int>(
      tooltip: t.common_more_actions,
      icon: const Icon(Icons.more_vert),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        for (int i = 0; i < collapsible.length; i++)
          PopupMenuItem<int>(
            value: i,
            enabled: collapsible[i].onPressed != null,
            child: Row(
              children: <Widget>[
                Icon(collapsible[i].icon, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(collapsible[i].label)),
              ],
            ),
          ),
      ],
      onSelected: (int index) => collapsible[index].onPressed?.call(),
    ),
  ];
}

class HibikiDialogFrame extends StatelessWidget {
  const HibikiDialogFrame({
    required this.child,
    super.key,
    this.maxWidth = 420,
    this.maxHeightFactor = 0.82,
    this.insetPadding,
    this.padding = EdgeInsets.zero,
    this.scrollable = true,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeightFactor;

  /// 对话框与屏幕边缘的留白。null = 按屏宽自适应（见 [_resolveInsetPadding]）。
  ///
  /// BUG-1177：此前默认硬编码 `horizontal: 40`。窄屏上这 80px 是纯损失——320dp 的
  /// 手机上对话框正文只剩 240px，再扣掉 [HibikiModalSheetFrame] 的头部内边距和
  /// 52px 的图标徽标，标题只剩约 144px，于是几乎所有对话框标题都被省略成「…」。
  /// 40 这个值只对宽屏合理（且宽屏本来就被 [maxWidth] 420 兜住，边距几乎不起作用），
  /// 真正需要它自适应的恰恰是窄屏。少数已经手动传 `tokens.spacing.card` 绕开该默认
  /// 值的调用点即是佐证——现在默认值自己就做对了，不必每处再记得覆盖。
  final EdgeInsets? insetPadding;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  /// 屏幕越窄，边距越小：320dp 上取 16（与卡片内边距同级），随屏宽线性放大到宽屏
  /// 的 40 为止。用比例而非断点，避免在某个宽度上突然跳变。
  EdgeInsets _resolveInsetPadding(double screenWidth) {
    if (insetPadding != null) return insetPadding!;
    final double horizontal =
        screenWidth.isFinite ? (screenWidth * 0.05).clamp(16.0, 40.0) : 40.0;
    return EdgeInsets.symmetric(horizontal: horizontal, vertical: 24);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Size screenSize = MediaQuery.sizeOf(context);
    final double screenHeight = screenSize.height;
    final Widget padded = Padding(
      padding: padding,
      child: child,
    );
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: _resolveInsetPadding(screenSize.width),
      shape: RoundedRectangleBorder(borderRadius: tokens.radii.dialogRadius),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: screenHeight * maxHeightFactor,
        ),
        child: scrollable ? SingleChildScrollView(child: padded) : padded,
      ),
    );
  }
}

enum HibikiColorSwatchShape { block, dot }

class HibikiColorSwatch extends StatelessWidget {
  const HibikiColorSwatch({
    required this.color,
    super.key,
    this.size = 20,
    this.width,
    this.height,
    this.shape = HibikiColorSwatchShape.block,
    this.selected = false,
    this.onTap,
    this.label,
    this.textColor,
    this.borderColor,
    this.overlay,
  });

  final Color color;
  final double size;
  final double? width;
  final double? height;
  final HibikiColorSwatchShape shape;
  final bool selected;
  final VoidCallback? onTap;
  final String? label;
  final Color? textColor;
  final Color? borderColor;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool isDot = shape == HibikiColorSwatchShape.dot;
    final double resolvedWidth = width ?? size;
    final double resolvedHeight = height ?? size;
    final BorderRadius inkRadius = isDot
        ? BorderRadius.circular(resolvedHeight / 2)
        : tokens.radii.chipRadius;
    final BorderSide borderSide = BorderSide(
      color: selected ? colors.primary : borderColor ?? colors.outlineVariant,
      width: selected ? 3 : 1,
    );
    final Color foreground = _swatchForegroundFor(color);
    final Widget? swatchOverlay =
        selected ? Icon(Icons.check, color: foreground, size: 20) : overlay;
    final Widget swatch = SizedBox(
      width: resolvedWidth,
      height: resolvedHeight,
      child: AnimatedContainer(
        duration: hibikiMd3StateDuration,
        curve: hibikiMd3StateCurve,
        decoration: BoxDecoration(
          color: color,
          shape: isDot ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: isDot ? null : tokens.radii.chipRadius,
          border: Border.fromBorderSide(borderSide),
        ),
        child: swatchOverlay == null
            ? null
            : Center(
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground, size: 20),
                  child: swatchOverlay,
                ),
              ),
      ),
    );
    return _buildSwatchInteractive(
      context,
      visual: swatch,
      inkRadius: inkRadius,
      selected: selected,
      onTap: onTap,
      label: label,
      textColor: textColor,
    );
  }
}

/// Shared interactive wrapper for swatch widgets: InkWell ripple + a single
/// gamepad/keyboard focus stop + selection semantics + optional caption label.
///
/// [visual] is the bare painted swatch (it owns its own size/shape/border).
/// [inkRadius] clips the ripple. Factored out of [HibikiColorSwatch] so
/// [HibikiSchemeSwatch] inherits the EXACT focus-stop behaviour: under a
/// [HibikiFocusRoot] the directional controller navigates ONLY between
/// registered HibikiFocusTargets — a bare InkWell makes its own (unregistered)
/// Focus node, so gamepad/keyboard navigation skips the whole swatch row (the
/// theme picker was unreachable: "到不了主题的位置"). We register each swatch as a
/// single focus stop (A/Enter activates onTap), keeping the InkWell for
/// mouse/touch ripple but barring it from grabbing a competing focus node.
/// Off-root (mobile touch) the InkWell is unchanged.
Widget _buildSwatchInteractive(
  BuildContext context, {
  required Widget visual,
  required BorderRadius inkRadius,
  required bool selected,
  required VoidCallback? onTap,
  VoidCallback? onLongPress,
  String? label,
  Color? textColor,
}) {
  final Widget interactiveSwatch;
  if (onTap == null) {
    interactiveSwatch = visual;
  } else {
    final bool underFocusRoot =
        HibikiFocusRoot.maybeControllerOf(context) != null;
    final Widget inkSwatch = Material(
      color: Colors.transparent,
      borderRadius: inkRadius,
      child: InkWell(
        borderRadius: inkRadius,
        onTap: onTap,
        // TODO-928: 长按是鼠标/触摸语义；手柄/焦点路径走下面的
        // HibikiActivatableFocusTarget（只有 onTap），长按在那里不生效，符合现状无障碍。
        onLongPress: onLongPress,
        canRequestFocus: !underFocusRoot,
        child: visual,
      ),
    );
    interactiveSwatch = underFocusRoot
        ? HibikiActivatableFocusTarget(
            focusIdPrefix: 'color-swatch',
            onTap: onTap,
            child: inkSwatch,
          )
        : inkSwatch;
  }
  final Widget semanticSwatch = Semantics(
    button: onTap != null,
    selected: selected,
    child: interactiveSwatch,
  );
  if (label == null) return semanticSwatch;
  final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      semanticSwatch,
      SizedBox(height: tokens.spacing.gap / 2),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: tokens.type.metadata.copyWith(
          color: textColor ?? tokens.surfaces.onSurface,
        ),
      ),
    ],
  );
}

/// Registers [child] as a single gamepad/keyboard focus stop whose A/Enter
/// ([ActivateIntent]) fires [onTap]. The [Actions] sits ABOVE the
/// [HibikiFocusTarget] on purpose: the gamepad A path dispatches the intent at
/// the focused node's context (gamepad_service `_dispatchButton`), which finds
/// an Actions handler only by walking UP — so a handler placed *inside*
/// HibikiFocusTarget (as [HibikiFocusable] does) would never fire. Use this for
/// a discrete tap target whose own visual (e.g. an InkWell with
/// `canRequestFocus: false`) must stay mouse/touch-tappable without grabbing a
/// competing, unregistered focus node. Only meaningful under a [HibikiFocusRoot].
class HibikiActivatableFocusTarget extends StatefulWidget {
  const HibikiActivatableFocusTarget({
    required this.onTap,
    required this.child,
    super.key,
    this.focusIdPrefix = 'tap-stop',
  });

  final VoidCallback onTap;
  final Widget child;
  final String focusIdPrefix;

  @override
  State<HibikiActivatableFocusTarget> createState() =>
      _HibikiActivatableFocusTargetState();
}

class _HibikiActivatableFocusTargetState
    extends State<HibikiActivatableFocusTarget> {
  late final HibikiFocusId _focusId = HibikiFocusId(
    '${widget.focusIdPrefix}-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: _focusId,
        child: widget.child,
      ),
    );
  }
}

Color _swatchForegroundFor(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

/// The four colours a [HibikiSchemeSwatch] previews for a generated
/// [ColorScheme], in the order the swatch paints them:
/// `[text, background, button, menu]` =
/// `[onSurface, surface, primary, surfaceContainerHigh]`.
///
/// This answers "what does this theme actually look like?" the way a user
/// reads a UI: the **text colour** sitting on the **page background** (top-left
/// triangle, shown as a 「文」glyph) and the **button/accent colour** dropped on
/// a **popup-menu surface** (bottom-right triangle, shown as a dot). Surface vs
/// surfaceContainerHigh also keeps light/dark presets that share one seed
/// distinct (their backgrounds differ), and makes the three dark presets
/// readable apart at a glance instead of three near-identical dark circles.
List<Color> hibikiSchemeSwatchColors(ColorScheme scheme) => <Color>[
      scheme.onSurface,
      scheme.surface,
      scheme.primary,
      scheme.surfaceContainerHigh,
    ];

/// A rounded-square swatch split on the diagonal to preview the four real
/// generated scheme colours instead of a single seed colour. The top-left
/// triangle paints the **page background** with the **text colour** as a 「文」
/// glyph (text-on-background contrast); the bottom-right triangle paints the
/// **popup-menu surface** with the **button/accent colour** as a dot
/// (button-on-menu). Used by the theme picker so each swatch accurately
/// predicts the applied theme; a single-colour seed swatch could not (e.g.
/// light/dark presets share one seed, the three dark presets look identical).
/// Single-colour swatches (tag colour, custom-colour preview) keep using
/// [HibikiColorSwatch].
class HibikiSchemeSwatch extends StatelessWidget {
  const HibikiSchemeSwatch({
    required this.colors,
    super.key,
    this.size = 48,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.overlay,
    this.borderColor,
  }) : assert(colors.length == 4, 'scheme swatch needs exactly 4 colours');

  /// `[text, background, button, menu]` — see [hibikiSchemeSwatchColors].
  final List<Color> colors;
  final double size;
  final bool selected;
  final VoidCallback? onTap;

  /// TODO-928: 长按动作（鼠标/触摸语义）。自定义 swatch 用它「长按进编辑页」，
  /// 而单击统一为「切换主题」。手柄/焦点路径无长按（见 [_buildSwatchInteractive]），
  /// 故焦点用户的编辑入口另由可达的「编辑」图标按钮提供，不靠此回调。
  final VoidCallback? onLongPress;

  /// Centred badge icon for non-preset swatches (system = auto, custom = palette).
  final Widget? overlay;
  // TODO-1320: 主题卡片一律不带 caption 文字（无 label/textColor）——系统/预设/自定义
  // 所有 swatch 统一只显示完整对角预览、无底部多余文字。带文字标签的单色 swatch 仍走
  // HibikiColorSwatch（它保留 label/textColor）。
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color textRole = colors[0];
    final Color backgroundRole = colors[1];
    final Color menuRole = colors[3];
    final BorderSide borderSide = BorderSide(
      color: selected ? cs.primary : borderColor ?? cs.outlineVariant,
      width: selected ? 3 : 1,
    );
    final Widget? badgeChild =
        selected ? const Icon(Icons.check, size: 10) : overlay;
    // TODO-138: every swatch — including system (= auto) and custom (= palette) —
    // now shows the FULL diagonal preview (「文」 glyph + accent dot). The badge is
    // no longer a centred disc that hid that preview; it is a small corner marker
    // in the bottom-left (the menu triangle, clear of the top-left 「文」 at 30% and
    // the bottom-right accent dot at 68%), so system/custom previews read exactly
    // like the presets, just with an extra hint icon.
    final Widget? badge = badgeChild == null
        ? null
        : Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: menuRole,
              shape: BoxShape.circle,
              border: Border.all(color: cs.outlineVariant, width: 0.5),
            ),
            child: IconTheme.merge(
              // BUG-212: contrast the badge icon against the badge's OWN
              // background (`menuRole` = the previewed scheme's
              // surfaceContainerHigh), not the app theme's `cs.onSurface`.
              // Borrowing `cs.onSurface` made the icon track a different
              // colorScheme than the disc behind it: under a dark app theme a
              // light custom scheme gave a light icon on a light disc → the
              // palette/auto glyph vanished. Mirrors `HibikiColorSwatch`'s
              // `_swatchForegroundFor(color)` so the badge foreground always
              // reads on its own background, in every theme combination.
              data: IconThemeData(
                color: _swatchForegroundFor(menuRole),
                size: 10,
              ),
              child: badgeChild,
            ),
          );
    // Rounded-square card painted by [SchemeDiagonalPainter]: top-left triangle
    // = page background with a text-coloured 「文」 (text-on-background); bottom-
    // right triangle = popup-menu surface with a button-coloured dot
    // (button-on-menu). The selection ring rides the card border via `decoration`
    // (the painter clips to a rounded rect inside the border, so it never paints
    // over the ring).
    final Widget visual = AnimatedContainer(
      duration: hibikiMd3StateDuration,
      curve: hibikiMd3StateCurve,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: backgroundRole,
        borderRadius: tokens.radii.chipRadius,
        border: Border.fromBorderSide(borderSide),
      ),
      child: ClipRRect(
        borderRadius: tokens.radii.chipRadius,
        // 滚动性能：色卡常摆在非懒的 Wrap/Column（如阅读设置抽屉的主题选择器、
        // buildThemeSelector 的 Wrap）里。父级 SingleChildScrollView 滚动时会重绘
        // 整棵子树，令 SchemeDiagonalPainter.paint() 每帧重跑 → 掉帧。给画布包一层
        // RepaintBoundary，让每张色卡各自栅格化进缓存层，滚动只合成、不重绘。
        child: RepaintBoundary(
          child: CustomPaint(
            // TODO-1320: pin the painting surface to the card size. A childless
            // CustomPaint with the default `size: Size.zero` collapses to zero
            // under the LOOSE constraints the parent AnimatedContainer hands down
            // (its `alignment: Alignment.center` loosens child constraints). So an
            // unselected preset swatch — which has no badge child (badge is only
            // the selection check or the system/custom overlay) — painted onto a
            // 0x0 canvas and rendered as a blank rounded card. Selected / system /
            // custom swatches escaped this only because their badge/overlay gave
            // CustomPaint a non-null child that sized it. Sizing the canvas
            // explicitly makes EVERY swatch paint the full diagonal preview,
            // selected or not (the earlier `showGlyph: true` was a no-op on a
            // zero-size canvas).
            size: Size.square(size),
            painter: SchemeDiagonalPainter(
              textColor: textRole,
              backgroundColor: backgroundRole,
              buttonColor: colors[2],
              menuColor: menuRole,
              // TODO-138: always paint the full preview — the 「文」 glyph and the
              // accent dot — for EVERY swatch. The badge (if any) sits in the corner
              // and no longer replaces the glyph, so system/custom show a complete
              // preview, not just a base colour behind a centred badge.
              showGlyph: true,
              textDirection: Directionality.of(context),
            ),
            child: badge == null
                ? null
                : Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: badge,
                    ),
                  ),
          ),
        ),
      ),
    );
    return _buildSwatchInteractive(
      context,
      visual: visual,
      inkRadius: tokens.radii.chipRadius,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// Paints the diagonal scheme preview: the canvas is split corner-to-corner
/// (top-right -> bottom-left) into a top-left triangle filled with
/// [backgroundColor] (carrying a [textColor] 「文」 glyph) and a bottom-right
/// triangle filled with [menuColor] (carrying a [buttonColor] dot). This mirrors
/// how a user reads a theme: text on the page vs a button on a popup menu.
@visibleForTesting
class SchemeDiagonalPainter extends CustomPainter {
  const SchemeDiagonalPainter({
    required this.textColor,
    required this.backgroundColor,
    required this.buttonColor,
    required this.menuColor,
    required this.showGlyph,
    required this.textDirection,
  });

  final Color textColor;
  final Color backgroundColor;
  final Color buttonColor;
  final Color menuColor;
  final bool showGlyph;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..style = PaintingStyle.fill;
    // Top-left triangle = page background (the card decoration already fills it,
    // but paint it explicitly so the painter is self-contained / testable).
    paint.color = backgroundColor;
    final Path topLeft = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(topLeft, paint);
    // Bottom-right triangle = popup-menu surface.
    paint.color = menuColor;
    final Path bottomRight = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(bottomRight, paint);

    // Button/accent dot in the bottom-right triangle's centroid.
    final double dotRadius = size.shortestSide * 0.13;
    final Offset dotCenter = Offset(size.width * 0.68, size.height * 0.68);
    paint.color = buttonColor;
    canvas.drawCircle(dotCenter, dotRadius, paint);

    if (!showGlyph) return;
    // 「文」 glyph in the top-left triangle, in the text role, to show the real
    // text-on-background contrast of this theme.
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: '文',
        style: TextStyle(
          color: textColor,
          fontSize: size.shortestSide * 0.34,
          height: 1,
        ),
      ),
      textDirection: textDirection,
    )..layout();
    tp.paint(
      canvas,
      Offset(
          size.width * 0.30 - tp.width / 2, size.height * 0.30 - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(SchemeDiagonalPainter oldDelegate) =>
      oldDelegate.textColor != textColor ||
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.buttonColor != buttonColor ||
      oldDelegate.menuColor != menuColor ||
      oldDelegate.showGlyph != showGlyph ||
      oldDelegate.textDirection != textDirection;
}

class HibikiPreviewSwitch extends StatelessWidget {
  const HibikiPreviewSwitch({
    required this.trackColor,
    required this.thumbColor,
    super.key,
  });

  final Color trackColor;
  final Color thumbColor;

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: true,
      onChanged: null,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: WidgetStatePropertyAll<Color>(thumbColor),
      trackColor: WidgetStatePropertyAll<Color>(trackColor),
    );
  }
}

class HibikiPageHeader extends StatelessWidget {
  const HibikiPageHeader({
    required this.title,
    super.key,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
    this.padding,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final EdgeInsetsGeometry? padding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    // TODO-667: 顶部留白分三档。
    // - [compact] 模式（上方已有 AppBar，由 [HibikiPageScaffold] 传入）顶距最小，
    //   只留一个 gap，标题紧贴 AppBar 下沿。
    // - 非 compact 但窗口是手机竖屏 / 窄窗（[WindowSizeClass.compact]，宽 < 600）：
    //   页头本身就是顶部锚点，外层 [SafeArea] 已让出状态栏 / 刘海，再叠
    //   `page + 8 = 24` 会让标题离顶部空出一行（用户反馈「和摄像头差一行」）。
    //   收到普通 `page = 16`，保留必要呼吸又不顶到摄像头。
    // - 非 compact 的中 / 宽窗（桌面 / 平板，宽 >= 600）：窗口顶部无系统栏遮挡、
    //   内容区另有左右留白，`page + 8 = 24` 的标题区呼吸感合适，保持不变。
    // BUG-401: classify on the real physical width. HibikiPageHeader renders
    // inside HibikiAppUiScale, so MediaQuery.sizeOf here is the inflated
    // logical width; multiply by the net app UI scale to recover the real
    // viewport width before applying the compact breakpoint.
    final bool narrowWindow = windowSizeClassReal(
          MediaQuery.sizeOf(context).width,
          HibikiAppUiScale.of(context),
        ) ==
        WindowSizeClass.compact;
    final double resolvedTop = compact
        ? tokens.spacing.gap
        : (narrowWindow ? tokens.spacing.page : tokens.spacing.page + 8);
    final EdgeInsetsGeometry resolvedPadding = padding ??
        EdgeInsets.fromLTRB(
          tokens.spacing.page,
          resolvedTop,
          tokens.spacing.page,
          bottom == null ? tokens.spacing.gap + 4 : tokens.spacing.gap,
        );
    final String? resolvedSubtitle =
        subtitle == null || subtitle!.trim().isEmpty ? null : subtitle;

    return Padding(
      padding: resolvedPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _HibikiPageHeaderRow(
            tokens: tokens,
            leading: leading,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.pageTitle,
                ),
                if (resolvedSubtitle != null)
                  Padding(
                    padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
                    child: Text(
                      resolvedSubtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.listSubtitle,
                    ),
                  ),
              ],
            ),
            actions: actions.isEmpty ? null : _buildActionRow(tokens),
          ),
          if (bottom != null)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap + 4),
              child: bottom!,
            ),
        ],
      ),
    );
  }

  Widget _buildActionRow(HibikiDesignTokens tokens) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int index = 0; index < actions.length; index++) ...<Widget>[
          if (index > 0) SizedBox(width: tokens.spacing.gap / 2),
          actions[index],
        ],
      ],
    );
  }
}

/// TODO-1126 / BUG-541: [HibikiPageHeader] 的标题 + 动作行。
///
/// 根因：旧实现（7ce19740c + 3df631aaf）标题 [Expanded](flex:1) 与动作区
/// [Flexible](flex:1) **均分**剩余宽，动作格恒占页头右半幅（与图标实际总宽无关），
/// 再套 [Align](centerRight) 把按钮推到右半幅右缘才勉强靠右。窄窗时 4 个图标自然宽
/// 超过右半幅视口，内层 [SingleChildScrollView](reverse:true) 把最左侧 [Icons.add]
/// 裁到视口外（用户看到像个「-」）。
///
/// 修法：标题 [Expanded]（tight）吃满剩余，动作区作为**非弹性**子项按自身自然宽落在
/// 页头最右侧——不再与标题 flex 均分，宽窗行为零变化。用 [LayoutBuilder] 拿到整行可用
/// 宽，给动作区套 [ConstrainedBox]（maxWidth = 整行宽 − 动作前 gap，title 允许被压到
/// 0）：放得下时约束不触发、动作区取自然宽、所有图标可见且靠右；仅当动作总宽超过该
/// 上界（极端窄窗，如 master-detail 208px 左栏）时约束触发，内层横向
/// [SingleChildScrollView] 收缩 + 可横滚兜底，消除 RenderFlex overflow，滚动起始边在
/// 左、最左侧动作（回归态被裁的 [Icons.add]）默认可见。三个 home tab（视频/书架/词典）
/// 页头均无 leading + actions 并存，故不必为 leading 额外预留。
class _HibikiPageHeaderRow extends StatelessWidget {
  const _HibikiPageHeaderRow({
    required this.tokens,
    required this.title,
    required this.leading,
    required this.actions,
  });

  final HibikiDesignTokens tokens;
  final Widget title;
  final Widget? leading;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final double leadingGap = tokens.spacing.gap + 4;
    final double actionsGap = tokens.spacing.gap;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget titleChild = Expanded(child: title);

        final List<Widget> children = <Widget>[];
        if (leading != null) {
          children.add(
            Padding(
              padding: EdgeInsets.only(
                top: tokens.spacing.gap / 2,
                right: leadingGap,
              ),
              child: leading,
            ),
          );
        }
        children.add(titleChild);
        if (actions != null) {
          // 动作区可用宽上界：整行宽减去动作前 gap，**再减去留给标题的保底宽**。
          // leading（含右 gap）作为非弹性子项另行占位，不计入此上界——它在 Row 里已被
          // 独立扣除；这里只需保证「gap + 动作区」不超过整行宽即可避免 overflow。
          //
          // BUG-1177：原先只保证不 overflow，标题作为 [Expanded] 被允许压到 0。窄屏上
          // 4~5 个动作按钮就能把标题吃干净——不报错，但页面标题（合集名、书名）彻底
          // 消失，用户只看到一排图标。动作区本就套着横向滚动视图，被限宽后是「滚动」
          // 而不是「丢失」；标题被压到 0 才是真的丢失。所以保底给标题留几个字的宽度，
          // 超出的动作让它滚。保底值随文字缩放走，并且不超过行宽的三分之一，免得动作
          // 很少时反而挤到按钮。
          final double titleFloor = constraints.maxWidth.isFinite
              ? math.min(
                  96.0 * MediaQuery.textScalerOf(context).scale(1),
                  constraints.maxWidth / 3,
                )
              : 0.0;
          final double maxActionsWidth = constraints.maxWidth.isFinite
              ? (constraints.maxWidth - actionsGap - titleFloor)
                  .clamp(0.0, double.infinity)
              : double.infinity;
          // 带 label 的动作是否展开成药丸：按**页头本地可用宽**（而非整窗宽）判定，经
          // UI 缩放还原真实宽后仅 expanded（≥840）才展开。桌面带导航栏 / 分栏时整窗
          // ≥840 但本地宽更窄，若按整窗判定会误展开、把 [Expanded] 标题挤到贴按钮/折行
          // （用户反馈「已经重叠了还没降级成无字」）。经 [HibikiHeaderLabelScope] 下发。
          final bool expandLabels = constraints.maxWidth.isFinite &&
              windowSizeClassReal(
                    constraints.maxWidth,
                    HibikiAppUiScale.of(context),
                  ) ==
                  WindowSizeClass.expanded;
          children
            ..add(SizedBox(width: actionsGap))
            ..add(
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxActionsWidth),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: HibikiHeaderLabelScope(
                    expandLabels: expandLabels,
                    child: actions!,
                  ),
                ),
              ),
            );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}

class HibikiPageScaffold extends StatefulWidget {
  const HibikiPageScaffold({
    required this.title,
    required this.body,
    super.key,
    this.subtitle,
    this.actions = const <Widget>[],
    this.leading,
    this.showAppBar = true,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.headerBottom,
    this.bottomNavigationBar,
    this.headerCompact,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final Widget? leading;
  final bool showAppBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? headerBottom;
  final Widget? bottomNavigationBar;
  final bool? headerCompact;

  @override
  State<HibikiPageScaffold> createState() => _HibikiPageScaffoldState();
}

class _HibikiPageScaffoldState extends State<HibikiPageScaffold> {
  // Owns a PrimaryScrollController so a [body] built from a primary ScrollView
  // (CustomScrollView/ListView with no explicit controller) attaches here. The
  // gamepad LB/RB page-scroll fallback reaches it via
  // PrimaryScrollController.maybeOf even on pure-display pages with no focus
  // geometry (e.g. reading statistics), where D-pad edge takeover can't help.
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Register as the active page scroll controller so the gamepad LB/RB
    // page-scroll fallback can reach this page's body even when focus rests on
    // the top-level fallback node (a pure-display page with nothing focusable),
    // which is an ancestor of this controller and thus invisible to
    // PrimaryScrollController.maybeOf.
    PageScrollRegistry.push(_scrollController);
  }

  @override
  void dispose() {
    PageScrollRegistry.pop(_scrollController);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return PrimaryScrollController(
      controller: _scrollController,
      // Inherit on EVERY platform. The default is mobile-only, which would
      // leave the body's primary ScrollView UNATTACHED on desktop (and, worse,
      // shadow this controller with PrimaryScrollController.none) — but the
      // gamepad LB/RB page-scroll fallback that reaches this controller is a
      // desktop feature. All-platform inherit makes the body scroll reachable
      // everywhere.
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: Scaffold(
        backgroundColor: tokens.surfaces.page,
        appBar: widget.showAppBar
            ? AppBar(
                leading: widget.leading,
                title: const SizedBox.shrink(),
                backgroundColor: tokens.surfaces.page,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
              )
            : null,
        floatingActionButton: widget.floatingActionButton,
        floatingActionButtonLocation: widget.floatingActionButtonLocation,
        bottomNavigationBar: widget.bottomNavigationBar,
        body: SafeArea(
          top: !widget.showAppBar,
          // stretch (not start) so every page body receives a tight full-width
          // constraint. Under start the cross axis stays loose, and any body
          // that shrink-wraps its width (e.g. a vertical SingleChildScrollView
          // like HibikiLogPanel) collapses into a tall, content-width column on
          // the left instead of filling the page. The header left-aligns its
          // own content internally, so it is unaffected by stretch.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              HibikiPageHeader(
                title: widget.title,
                subtitle: widget.subtitle,
                leading: widget.showAppBar ? null : widget.leading,
                actions: widget.actions,
                bottom: widget.headerBottom,
                compact: widget.headerCompact ?? widget.showAppBar,
              ),
              Expanded(child: widget.body),
            ],
          ),
        ),
      ),
    );
  }
}

class HibikiToolScaffold extends StatelessWidget {
  const HibikiToolScaffold({
    required this.title,
    required this.body,
    super.key,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
    this.bottomNavigationBar,
    this.backgroundColor,
  }) : titleWidget = null;

  const HibikiToolScaffold.customTitle({
    required Widget title,
    required this.body,
    super.key,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
    this.bottomNavigationBar,
    this.backgroundColor,
  })  : title = null,
        titleWidget = title;

  final String? title;
  final Widget? titleWidget;
  final Widget body;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final Widget? bottomNavigationBar;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget? effectiveLeading = leading ?? _defaultLeading(context);

    return Scaffold(
      backgroundColor: backgroundColor ?? tokens.surfaces.page,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.gap,
                4,
                tokens.spacing.gap,
                2,
              ),
              child: SizedBox(
                height: 44,
                // BUG-1177：动作区上界原先取 `MediaQuery.sizeOf(context).width * 0.48`
                // ——**整窗宽**。这个脚手架并不总是占满窗口（嵌在分栏/对话框/受限宽面板
                // 里时更常见），此时 0.48×整窗可以超过本行的真实可用宽，Row 直接右溢出。
                // 与 [_HibikiPageHeaderRow] 同一类错误，那边已按本地约束修过；这里改用
                // LayoutBuilder 的局部约束，并同样给标题留保底宽，超出的动作横向滚动。
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double gapHalf = tokens.spacing.gap / 2;
                    final double leadingWidth =
                        effectiveLeading != null ? 40 + gapHalf : 0;
                    final double titleFloor = constraints.maxWidth.isFinite
                        ? math.min(
                            96.0 * MediaQuery.textScalerOf(context).scale(1),
                            constraints.maxWidth / 3,
                          )
                        : 0.0;
                    final double maxActionsWidth = constraints.maxWidth.isFinite
                        ? (constraints.maxWidth -
                                leadingWidth -
                                gapHalf -
                                titleFloor)
                            .clamp(0.0, double.infinity)
                        : double.infinity;
                    return Row(
                      children: <Widget>[
                        if (effectiveLeading != null) ...<Widget>[
                          SizedBox.square(
                            dimension: 40,
                            child: effectiveLeading,
                          ),
                          SizedBox(width: gapHalf),
                        ],
                        Expanded(
                          child: _buildTitle(tokens),
                        ),
                        if (actions.isNotEmpty) ...<Widget>[
                          SizedBox(width: gapHalf),
                          ConstrainedBox(
                            constraints:
                                BoxConstraints(maxWidth: maxActionsWidth),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              reverse: true,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: actions,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
            if (bottom != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.gap,
                  0,
                  tokens.spacing.gap,
                  tokens.spacing.gap / 2,
                ),
                child: bottom!,
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget? _defaultLeading(BuildContext context) {
    if (!Navigator.of(context).canPop()) return null;
    return HibikiIconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: Icons.arrow_back,
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).maybePop(),
    );
  }

  Widget _buildTitle(HibikiDesignTokens tokens) {
    final TextStyle titleStyle = tokens.type.listTitle.copyWith(
      color: tokens.surfaces.onSurface,
    );
    final Widget? customTitle = titleWidget;
    if (customTitle != null) {
      return DefaultTextStyle.merge(
        style: titleStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: customTitle,
      );
    }
    return Text(
      title!,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: titleStyle,
    );
  }
}

class HibikiTransientScaffold extends StatelessWidget {
  const HibikiTransientScaffold({
    required this.body,
    super.key,
    this.backgroundColor,
    this.safeArea = true,
  });

  final Widget body;
  final Color? backgroundColor;
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget content = safeArea ? SafeArea(child: body) : body;
    return Scaffold(
      backgroundColor: backgroundColor ?? tokens.surfaces.page,
      body: content,
    );
  }
}

class HibikiOverlayScaffold extends StatelessWidget {
  const HibikiOverlayScaffold({
    required this.body,
    super.key,
    this.safeArea = true,
  });

  final Widget body;
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final Widget content = safeArea ? SafeArea(child: body) : body;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: content,
    );
  }
}

class HibikiFilePickerRow extends StatelessWidget {
  const HibikiFilePickerRow({
    required this.title,
    required this.icon,
    super.key,
    this.subtitle,
    this.actions = const <Widget>[],
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Widget> actions;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color foreground = enabled
        ? tokens.surfaces.onVariant
        : tokens.surfaces.onVariant.withValues(alpha: 0.38);
    return HibikiListItem(
      onTap: enabled ? onTap : null,
      minHeight: 60,
      leading: Icon(icon, size: 22, color: foreground),
      title: Text(title),
      subtitle: subtitle == null || subtitle!.isEmpty ? null : Text(subtitle!),
      trailing: actions.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: actions,
            ),
    );
  }
}

class HibikiOverflowMenu<T> extends StatefulWidget {
  const HibikiOverflowMenu({
    required this.items,
    required this.onSelected,
    super.key,
    this.icon = Icons.more_vert,
    this.iconWidget,
    this.child,
    this.tooltip,
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
    this.splashRadius,
  });

  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final IconData icon;
  final Widget? iconWidget;
  final Widget? child;
  final String? tooltip;
  final double? iconSize;
  final EdgeInsetsGeometry padding;
  final double? splashRadius;

  @override
  State<HibikiOverflowMenu<T>> createState() => _HibikiOverflowMenuState<T>();
}

class _HibikiOverflowMenuState<T> extends State<HibikiOverflowMenu<T>> {
  final GlobalKey<PopupMenuButtonState<T>> _menuKey =
      GlobalKey<PopupMenuButtonState<T>>();
  late final HibikiFocusId _fallbackFocusId =
      HibikiFocusId('hibiki-overflow-menu-${identityHashCode(this)}');

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final PopupMenuButton<T> menu = PopupMenuButton<T>(
      key: _menuKey,
      tooltip: widget.tooltip,
      icon: widget.child == null
          ? widget.iconWidget ?? Icon(widget.icon, size: widget.iconSize)
          : null,
      shape: RoundedRectangleBorder(borderRadius: tokens.radii.menuRadius),
      color: tokens.surfaces.overlay,
      surfaceTintColor: Colors.transparent,
      menuPadding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
      padding: widget.padding,
      splashRadius: widget.splashRadius,
      position: PopupMenuPosition.under,
      popUpAnimationStyle: hibikiMd3MenuAnimationStyle,
      onSelected: widget.onSelected,
      itemBuilder: (BuildContext context) => widget.items,
      child: widget.child,
    );
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return menu;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _menuKey.currentState?.showButtonMenu();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: _fallbackFocusId,
        child: menu,
      ),
    );
  }
}

class HibikiPopupMenuItem<T> extends PopupMenuItem<T> {
  HibikiPopupMenuItem({
    required String label,
    required T value,
    super.key,
    IconData? icon,
    Color? color,
    bool selected = false,
    bool enabled = true,
  }) : super(
          value: value,
          enabled: enabled,
          height: 48,
          child: _HibikiPopupMenuItemContent(
            label: label,
            icon: icon,
            color: color,
            selected: selected,
          ),
        );
}

class _HibikiPopupMenuItemContent extends StatelessWidget {
  const _HibikiPopupMenuItemContent({
    required this.label,
    this.icon,
    this.color,
    this.selected = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color foreground = color ??
        (selected ? tokens.surfaces.primary : tokens.surfaces.onSurface);
    final TextStyle textStyle = tokens.type.listTitle.copyWith(
      color: foreground,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 20, color: foreground),
            SizedBox(width: tokens.spacing.gap + 4),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
          if (selected) ...<Widget>[
            SizedBox(width: tokens.spacing.gap + 4),
            Icon(Icons.check, size: 20, color: foreground),
          ],
        ],
      ),
    );
  }
}

class HibikiLogPanel extends StatefulWidget {
  const HibikiLogPanel({
    required this.log,
    required this.shareAction,
    super.key,
  });

  final String log;
  final ValueChanged<String> shareAction;

  @override
  State<HibikiLogPanel> createState() => _HibikiLogPanelState();
}

class _HibikiLogPanelState extends State<HibikiLogPanel> {
  // TODO-762：日志正文从「单个 `TextField`（maxLines:null, expands:true）全量渲染」
  // 改为按行 `ListView.builder` 懒加载。错误/调试日志最大 ~512KB、数万行
  // monospace，旧实现把整段一次性在 UI 线程做 `TextPainter.layout`（无行虚拟化），
  // 首帧 layout 几百 ms~数秒 → 打开「错误日志」卡顿。改为 ListView.builder 后只对
  // 视口内行做 layout，首帧恒定。选区/复制改由 `SelectionArea` 跨行提供。
  //
  // BUG-119 不回归（最高风险点）：旧实现之所以用 TextField，是为了让 EditableText
  // 当唯一滚动器，避免拖拽选区时被祖先 Scrollable 的 bringIntoView「拽回」。这里
  // 保留同一道防线——把 [_LogSelectionScrollController] 接到 ListView 的 controller：
  // 拖拽选区期间，除「指针贴边 + 朝外侧」的合法边缘自动滚动外，一律拦掉程序化
  // `jumpTo`/`animateTo`（选区把视口往光标/extent 拽回的来源），手动滚动不受影响。
  // SelectionArea 套纯 Text（无 EditableText caret）本就没有旧的 caret bringIntoView
  // 来源，此 gate 作为纵深防御守住不变式。守卫 `log_panel_scroll_select_guard_test`。
  late final _LogSelectionScrollController _scrollController =
      _LogSelectionScrollController();

  // 整段 log 按行预切一次（不在 build 里反复 split），仅 widget.log 变化时重切。
  // ListView.builder 按 [_lines] 索引懒构造每行，只渲染视口内行。
  late List<String> _lines = _splitLines(widget.log);

  static List<String> _splitLines(String log) => log.split('\n');

  // TODO-1380/BUG-694：右键/长按菜单的自持锚点——面板内最近一次 pointer down 的
  // 全局坐标。框架的 SelectableRegionState.contextMenuAnchors 只在首帧用「右键
  // 位置」当锚点（用一次即清空），之后每次 toolbar 重建（选区几何变化 →
  // SelectionOverlay.markNeedsBuild → overlay entry 重建）都退回 glyph 路径，对
  // startSelectionPoint/endSelectionPoint 做空断言；而本面板是懒加载 ListView +
  // 持续追加的日志流，端点所在行可被滚动回收 / 内容更新 detach（框架
  // getSelectionGeometry 明说 detached/off-screen 时端点可为 null）→ 菜单重建
  // 即崩（Null check operator，崩溃栈见 docs/bugs/BUG-694）。菜单只能由面板内
  // 的一次 pointer down（右键 / 长按）召出，外层 Listener 先于 SelectionArea
  // 看到它；自持该坐标让每次重建都锚在召出位置，幂等且完全不依赖选区几何。
  Offset? _lastPointerDownGlobalPosition;

  @override
  void didUpdateWidget(covariant HibikiLogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.log != widget.log) {
      _lines = _splitLines(widget.log);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // 「复制全部」不走 SelectionArea：ListView.builder 不构造视口外行，
  // SelectionArea 拿不到视口外行的 Selectable，「全选→复制」只能拿到当前
  // 视口内的几十行（TODO-762 回归，复核 af417805 实测 5000 行只复制到 38 行）。
  // 错误/调试日志页「复制整段去排障」是核心用途，所以「复制全部」直走
  // [widget.log] 全量、绕开 SelectionArea 的视口限制，保证一定拿到整段日志。
  Future<void> _copyAllToClipboard() async {
    // BUG-925：Windows 平台通道偶发把剪贴板 setData 抛成 PlatformException（剪贴板被
    // 其它进程独占 / 通道竞态）。这是「复制全部」的兜底入口，绝不能让一次复制失败把
    // 异常逃逸到 framework 顶层（与崩溃签名混淆）。失败时降级 debugPrint，不打断 UI。
    try {
      await Clipboard.setData(ClipboardData(text: widget.log));
    } catch (e) {
      debugPrint('[HibikiLogPanel] copy-all to clipboard failed: $e');
    }
  }

  // 上下文菜单：覆盖框架默认的「复制」（只拿视口选区）语义。保留默认
  // 项里「全选」之外的那些行为不变，但额外提供两个走全量 [widget.log] 的入口：
  // 「复制全部」（复制整段日志）与「分享」（分享整段日志）。拖拽部分视口
  // 选区的默认「复制」仍可用（对可见内容有效）；但「全选语义」必须给全量。
  Widget _buildContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
      // 增加「复制全部」入口：复制 widget.log 全量，不受视口限制。
      ContextMenuButtonItem(
        label: t.log_copy_all,
        onPressed: () {
          selectableRegionState.hideToolbar();
          _copyAllToClipboard();
        },
      ),
      ...selectableRegionState.contextMenuButtonItems,
      // 分享也用全量（错误/调试日志「分享整段去排障」是核心用途）。
      ContextMenuButtonItem(
        label: t.share,
        onPressed: () {
          selectableRegionState.hideToolbar();
          if (widget.log.isNotEmpty) widget.shareAction(widget.log);
        },
      ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      // TODO-1380/BUG-694：锚点自持（[_lastPointerDownGlobalPosition]），不读
      // selectableRegionState.contextMenuAnchors——其 glyph 回退路径对选区端点
      // 空断言，toolbar 重建即崩。null 分支不可达（菜单必由面板内 pointer down
      // 召出），仅作类型收口。
      anchors: TextSelectionToolbarAnchors(
        primaryAnchor: _lastPointerDownGlobalPosition ?? Offset.zero,
      ),
      buttonItems: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final TextStyle lineStyle = tokens.type.metadata.copyWith(
      color: tokens.surfaces.onSurface,
      fontFamily: 'monospace',
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: HibikiCard(
          padding: EdgeInsets.zero,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Stack(
                children: <Widget>[
                  Listener(
                    onPointerDown: (PointerDownEvent event) {
                      // TODO-1380：先记全局坐标当菜单锚点（右键/长按也走这里，
                      // 见 [_lastPointerDownGlobalPosition]），再做主键判定。
                      _lastPointerDownGlobalPosition = event.position;
                      if (event.buttons & kPrimaryButton == 0) return;
                      _scrollController.beginPointerSelection();
                    },
                    onPointerMove: (PointerMoveEvent event) {
                      // 主键松开（拖拽选区结束）→ 解除拦截，恢复程序化滚动。
                      // TODO-822 后拖拽期间不再追踪指针几何，move 只需观测主键状态。
                      if (event.buttons & kPrimaryButton == 0) {
                        _scrollController.endPointerSelection();
                      }
                    },
                    onPointerUp: (_) => _scrollController.endPointerSelection(),
                    onPointerCancel: (_) =>
                        _scrollController.endPointerSelection(),
                    child: SelectionArea(
                      contextMenuBuilder: _buildContextMenu,
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: EdgeInsets.all(tokens.spacing.card),
                        itemCount: _lines.length,
                        itemBuilder: (BuildContext context, int index) {
                          // TODO-806/TODO-822：单行不换行（softWrap:false）。
                          // 换行会把一行日志拆成多视觉行 → SelectionArea 的单行
                          // 选区命中要对每段 wrap 后的子矩形逐一求交，命中成本随
                          // 行长放大（TODO-806 框选坐标错位、TODO-822 拖拽卡顿的
                          // 放大器）。日志是 monospace，超视口宽的长行在屏幕右侧
                          // 裁切（本列表只纵向滚动、无横向滚动层），看全整段走
                          // 下方常驻「复制全部」（拿 widget.log 未裁剪全量）。
                          //
                          // BUG-925：仅 softWrap:false 时，行 Text 的布局宽度 =
                          // 整行无界单行宽（ListView 只纵向滚动，水平方向没有约束
                          // 收口它）。SelectionArea 对这种无界宽度的 Selectable 做
                          // 命中测试 / getBoxesForSelection 时（单击 / 框选触发），
                          // 会对超出视口的极端横坐标求交，触发越界（与 BUG-413/423
                          // 同族坐标错位）→ 点一下调试日志文字就崩。把每行 Text 的
                          // 布局宽度钉死在视口可用宽度内（ConstrainedBox + ClipRect），
                          // Selectable 的矩形不再越界，同时保留逐行选择能力——超视口
                          // 的长行仍按原设计在右侧裁切（看全整段走「复制全部」）。
                          return ClipRect(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth,
                              ),
                              child: Text(
                                _lines[index],
                                style: lineStyle,
                                softWrap: false,
                                overflow: TextOverflow.clip,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  // 始终可见的「复制全部」入口：复制 widget.log 全量、绕开
                  // SelectionArea 的视口限制，保证用户一定能拿到整段日志（不会
                  // 退化成只复制视口内的几十行）。
                  Positioned(
                    top: tokens.spacing.card,
                    right: tokens.spacing.card,
                    child: Tooltip(
                      message: t.log_copy_all,
                      child: FilledButton.tonalIcon(
                        onPressed: _copyAllToClipboard,
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        label: Text(t.log_copy_all),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// BUG-119 拽回判据的纯函数核心：在拖拽选区期间，决定是否放行一次程序化滚动
/// （`jumpTo` / `animateTo`）。从 [_LogSelectionScrollController._allowProgrammaticScroll]
/// 抽出，便于在 widget 渲染之外单测——把不变式钉死，防止有人把拦截逻辑掏空后
/// 结构守卫仍全绿（复核 ③ 指出旧守卫名存实亡）。
///
/// 规则（TODO-934——按滚动 API 区分边缘自动滚动 vs 键盘拽回）：
/// * 选区拖拽未激活 → 一律放行（非选区期的滚动不受影响）。
/// * 位移可忽略（<=0.5px）→ 放行（无实质滚动）。
/// * 选区拖拽激活 + 有实质位移 + 动画滚动（`animateTo`，[animated]=true）→ 放行：
///   这是 `EdgeDraggingAutoScroller` 的边缘自动滚动（拖到边区继续滚动延伸选区），
///   每帧步长被 SDK 钳在 ≤20px，不是一次跳到底。
/// * 选区拖拽激活 + 有实质位移 + 瞬跳滚动（`jumpTo`，[animated]=false）→ 拦截：
///   纯 SelectionArea + Text 结构下，拖拽框选期间唯一会瞬跳的程序化滚动是
///   `_ScrollableSelectionContainerDelegate._jumpToEdge`（键盘 granular/directional
///   扩展选区把视口往 extent 拽回，BUG-119 同源），拖拽期间一律拦掉。
///
/// TODO-934（调试日志框选拖到边区不响应）的根因修复：
/// BUG-423 当时一刀切「拖拽期一律拦掉程序化滚动」止住了卡死，代价是边缘自动滚动
/// 也被拦——拖到边区不再滚动延伸选区。但 BUG-423 把「Selectable 集合单调膨胀」当
/// 根因其实不准确：`ListView.builder` 离屏行会被回收（其 `Selectable` 从
/// `SelectionContainer` `remove()` 掉），`selectables` 大小被钉在「视口 + cacheExtent」
/// 内有界，不随滚动距离膨胀。真正的卡死放大器是 `softWrap:true` 长行——其
/// `RenderParagraph.getBoxesForSelection` 成本随该行换行成的视觉行数 O(N) 放大，
/// 而边缘自动滚动每帧持续重算选区几何。BUG-423 的 `softWrap:false` + BUG-448 的
/// `ConstrainedBox`+`ClipRect`（把每行布局宽度钉死在视口内）已经把每帧几何成本压成
/// O(视口可见内容)、与滚动距离无关——卡死链路已从根上断掉。因此可以安全恢复边缘
/// 自动滚动：放行 `animateTo`（有界一小步），仅保留拦掉 `jumpTo`（键盘拽回，纵深防御）。
///
/// 手动滚动（applyUserOffset / pointerScroll）不经本判据，不受影响。
bool logSelectionScrollDecision({
  required bool pointerSelectionActive,
  required double delta,
  required bool animated,
}) {
  if (!pointerSelectionActive) return true;
  if (delta.abs() <= 0.5) return true;
  // 动画滚动 = 边缘自动滚动（有界一小步），放行以延伸选区；
  // 瞬跳滚动 = 键盘拽回（_jumpToEdge），拖拽期一律拦。
  return animated;
}

class _LogSelectionScrollController extends ScrollController {
  _LogSelectionScrollController()
      : super(debugLabel: 'hibiki-log-selection-scroll');

  // 拖拽选区是否激活。这是 [logSelectionScrollDecision] 唯一需要的状态——
  // TODO-822 简化判据后不再追踪指针几何 / 手动滚动标志（边缘自动滚动整条拿掉，
  // 不存在按指针位置/方向区分的特殊情况）。
  bool _pointerSelectionActive = false;

  void beginPointerSelection() {
    _pointerSelectionActive = true;
  }

  void endPointerSelection() {
    _pointerSelectionActive = false;
  }

  // [animated]=true 表示来自 animateTo（边缘自动滚动），false 表示来自 jumpTo
  // （键盘拽回）。判据据此放行边缘自动滚动、仅拦掉拽回（TODO-934）。
  bool _allowProgrammaticScroll(double targetOffset, {required bool animated}) {
    // 仅当当前确实附着了唯一 ScrollPosition 时才有「当前像素」可比对；否则
    // 无可拦截的拽回，直接放行（纯判据下沉到 [logSelectionScrollDecision]）。
    if (!hasClients || positions.length != 1) return true;
    return logSelectionScrollDecision(
      pointerSelectionActive: _pointerSelectionActive,
      delta: targetOffset - position.pixels,
      animated: animated,
    );
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _LogSelectionScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      controller: this,
    );
  }

  @override
  Future<void> animateTo(
    double offset, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!_allowProgrammaticScroll(offset, animated: true)) {
      return Future<void>.value();
    }
    return super.animateTo(offset, duration: duration, curve: curve);
  }

  @override
  void jumpTo(double value) {
    if (!_allowProgrammaticScroll(value, animated: false)) return;
    super.jumpTo(value);
  }
}

class _LogSelectionScrollPosition extends ScrollPositionWithSingleContext {
  _LogSelectionScrollPosition({
    required super.physics,
    required super.context,
    required super.oldPosition,
    required super.debugLabel,
    required this.controller,
  });

  final _LogSelectionScrollController controller;

  // 手动滚动（applyUserOffset / pointerScroll）不 override：它们是用户拖滚动条 /
  // 滚轮的入口，本就该照常生效，不经拦截判据。程序化滚动按 API 区分（TODO-934）：
  // animateTo = 边缘自动滚动（EdgeDraggingAutoScroller，放行以拖到边区延伸选区）、
  // jumpTo = 键盘 granular/directional 扩展的 _jumpToEdge 拽回（拖拽期拦掉）。
  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!controller._allowProgrammaticScroll(to, animated: true)) {
      return Future<void>.value();
    }
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void jumpTo(double value) {
    if (!controller._allowProgrammaticScroll(value, animated: false)) return;
    super.jumpTo(value);
  }
}

class HibikiEditorPanel extends StatelessWidget {
  const HibikiEditorPanel({
    required this.controller,
    super.key,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.page),
      child: HibikiCard(
        padding: EdgeInsets.zero,
        child: Stack(
          children: <Widget>[
            TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: tokens.type.listSubtitle.copyWith(
                color: tokens.surfaces.onSurface,
                fontFamily: 'monospace',
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.all(tokens.spacing.card),
              ),
            ),
            Positioned(
              top: tokens.spacing.gap,
              right: tokens.spacing.gap,
              child: _hibikiTextFieldInputSuffix(
                    context: context,
                    controller: controller,
                  ) ??
                  const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class HibikiPopupSurface extends StatelessWidget {
  const HibikiPopupSurface({
    required this.child,
    super.key,
    this.color,
    this.padding = EdgeInsets.zero,
    this.elevation = 0,
    this.showBorder = true,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final double elevation;
  final bool showBorder;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Material(
      color: color ?? tokens.surfaces.card,
      elevation: elevation,
      shape: RoundedRectangleBorder(
        borderRadius: tokens.radii.cardRadius,
        side: showBorder
            ? BorderSide(color: tokens.surfaces.outline)
            : BorderSide.none,
      ),
      clipBehavior: clipBehavior,
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}

class HibikiCompactSearchRow extends StatelessWidget {
  const HibikiCompactSearchRow({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onSubmit,
    super.key,
    this.onClose,
    this.fieldKey,
    this.closeButtonKey,
    this.searchButtonKey,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onSubmit;
  final VoidCallback? onClose;
  final Key? fieldKey;
  final Key? closeButtonKey;
  final Key? searchButtonKey;

  void _submit() {
    final String query = controller.text.trim();
    if (query.isEmpty) return;
    onSubmit(query);
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String closeTooltip =
        MaterialLocalizations.of(context).closeButtonTooltip;
    final Widget? keyboardSuffix = _hibikiTextFieldInputSuffix(
      context: context,
      controller: controller,
    );
    return HibikiCard(
      color: tokens.surfaces.search,
      borderRadius: tokens.radii.controlRadius,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: 44,
        child: Row(
          children: <Widget>[
            if (onClose != null)
              _CompactSearchIconButton(
                key: closeButtonKey,
                icon: Icons.close,
                tooltip: closeTooltip,
                onPressed: onClose!,
              ),
            Expanded(
              child: TextField(
                key: fieldKey,
                controller: controller,
                focusNode: focusNode,
                style: tokens.type.listTitle,
                decoration: InputDecoration(
                  hintText: hintText,
                  hintStyle: tokens.type.listSubtitle,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submit(),
              ),
            ),
            if (keyboardSuffix != null) keyboardSuffix,
            _CompactSearchIconButton(
              key: searchButtonKey,
              icon: Icons.search,
              tooltip: MaterialLocalizations.of(context).searchFieldLabel,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactSearchIconButton extends StatelessWidget {
  const _CompactSearchIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return SizedBox(
      width: 36,
      height: 36,
      child: HibikiIconButton(
        icon: icon,
        enabledColor: tokens.surfaces.onVariant,
        size: 20,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onTap: onPressed,
      ),
    );
  }
}
