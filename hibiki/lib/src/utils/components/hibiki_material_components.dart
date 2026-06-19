import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/focus/page_scroll_registry.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/components/hibiki_gamepad_keyboard.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki/src/utils/components/hibiki_text_selection_controls.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_motion_tokens.dart';

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
    final Color effectiveColor = widget.color ??
        (widget.selected ? tokens.surfaces.selected : tokens.surfaces.card);
    final BorderRadius radius = widget.borderRadius ?? tokens.radii.cardRadius;
    final Widget content = Padding(
      padding: widget.padding ?? EdgeInsets.all(tokens.spacing.card),
      child: widget.child,
    );
    final Widget card = Padding(
      padding: widget.margin ?? EdgeInsets.zero,
      child: AnimatedContainer(
        duration: hibikiMd3StateDuration,
        curve: hibikiMd3StateCurve,
        decoration: ShapeDecoration(
          color: effectiveColor,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: widget.borderColor != null
                ? BorderSide(color: widget.borderColor!)
                : BorderSide.none,
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
    final Widget searchBar = ValueListenableBuilder<TextEditingValue>(
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
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? avatar;
  final IconData? leadingIcon;
  final String? tooltip;
  final HibikiFocusId? focusId;

  /// 默认 false：标签单行 + 省略号（标签筛选条等密集横排，宽度受限时优先省略）。
  /// 置 true：标签不省略、按固有宽度完整渲染（横滑分类条等空间充裕、标签必须可读的
  /// 场景，如视频设置顶部分类条 TODO-556）。Material [ChoiceChip] 给 label 的约束
  /// 上界由 chip 自身布局推导（即便在横向无界滚动里也是有限值），故单纯靠无界宽度无法
  /// 避免省略；改 [Text.overflow] 为 visible + softWrap:false 才能让 chip 随固有宽度撑开。
  final bool allowLabelOverflow;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color foreground =
        selected ? colors.onPrimaryContainer : tokens.surfaces.onSurface;
    final Widget? effectiveAvatar =
        avatar ?? (leadingIcon == null ? null : Icon(leadingIcon, size: 18));
    final ChoiceChip chip = ChoiceChip(
      avatar: effectiveAvatar,
      label: Text(
        label,
        maxLines: 1,
        softWrap: !allowLabelOverflow,
        overflow:
            allowLabelOverflow ? TextOverflow.visible : TextOverflow.ellipsis,
      ),
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
    final Widget withTooltip =
        tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
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

class HibikiDialogFrame extends StatelessWidget {
  const HibikiDialogFrame({
    required this.child,
    super.key,
    this.maxWidth = 420,
    this.maxHeightFactor = 0.82,
    this.insetPadding = const EdgeInsets.symmetric(
      horizontal: 40,
      vertical: 24,
    ),
    this.padding = EdgeInsets.zero,
    this.scrollable = true,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeightFactor;
  final EdgeInsets insetPadding;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final double screenHeight = MediaQuery.sizeOf(context).height;
    final Widget padded = Padding(
      padding: padding,
      child: child,
    );
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: insetPadding,
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
    this.overlay,
    this.label,
    this.textColor,
    this.borderColor,
  }) : assert(colors.length == 4, 'scheme swatch needs exactly 4 colours');

  /// `[text, background, button, menu]` — see [hibikiSchemeSwatchColors].
  final List<Color> colors;
  final double size;
  final bool selected;
  final VoidCallback? onTap;

  /// Centred badge icon for non-preset swatches (system = auto, custom = palette).
  final Widget? overlay;
  final String? label;
  final Color? textColor;
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
        child: CustomPaint(
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
    );
    return _buildSwatchInteractive(
      context,
      visual: visual,
      inkRadius: tokens.radii.chipRadius,
      selected: selected,
      onTap: onTap,
      label: label,
      textColor: textColor,
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
    final EdgeInsetsGeometry resolvedPadding = padding ??
        EdgeInsets.fromLTRB(
          tokens.spacing.page,
          compact ? tokens.spacing.gap : tokens.spacing.page + 8,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (leading != null) ...<Widget>[
                Padding(
                  padding: EdgeInsets.only(
                    top: tokens.spacing.gap / 2,
                    right: tokens.spacing.gap + 4,
                  ),
                  child: leading!,
                ),
              ],
              Expanded(
                child: Column(
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
              ),
              if (actions.isNotEmpty) ...<Widget>[
                SizedBox(width: tokens.spacing.gap),
                Align(
                  alignment: Alignment.topRight,
                  child: _buildActionRow(tokens),
                ),
              ],
            ],
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
                child: Row(
                  children: <Widget>[
                    if (effectiveLeading != null) ...<Widget>[
                      SizedBox.square(
                        dimension: 40,
                        child: effectiveLeading,
                      ),
                      SizedBox(width: tokens.spacing.gap / 2),
                    ],
                    Expanded(
                      child: _buildTitle(tokens),
                    ),
                    if (actions.isNotEmpty) ...<Widget>[
                      SizedBox(width: tokens.spacing.gap / 2),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.sizeOf(context).width * 0.48,
                        ),
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
  // BUG-119：日志正文用只读 TextField 而非 SingleChildScrollView+SelectableText。
  // 后者把整段 log 渲染成非滚动的 SelectableText（全高），外层 SingleChildScrollView
  // 提供滚动；鼠标拖拽选区时内层 EditableText 会对祖先 Scrollable 调 bringIntoView，
  // 把视口强行拉回选区 extent/caret，造成「按住选区往上滑就被拽回」。改用只读
  // TextField 让 EditableText 自己当唯一滚动器：选区拖拽的边缘自动滚动走它自己的
  // scroll controller，没有外层 SingleChildScrollView 来抢/拽，消除嵌套滚动冲突。
  late final TextEditingController _controller =
      TextEditingController(text: widget.log);
  late final _LogSelectionScrollController _scrollController =
      _LogSelectionScrollController();

  @override
  void didUpdateWidget(covariant HibikiLogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.log != widget.log) {
      _controller.text = widget.log;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: HibikiCard(
          padding: EdgeInsets.zero,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double viewportHeight = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : MediaQuery.sizeOf(context).height;
              return Listener(
                onPointerDown: (PointerDownEvent event) {
                  if (event.buttons & kPrimaryButton == 0) return;
                  _scrollController.beginPointerSelection(
                    pointerY: event.localPosition.dy,
                    viewportHeight: viewportHeight,
                  );
                },
                onPointerMove: (PointerMoveEvent event) {
                  if (event.buttons & kPrimaryButton == 0) {
                    _scrollController.endPointerSelection();
                    return;
                  }
                  _scrollController.updatePointerSelection(
                    pointerY: event.localPosition.dy,
                    viewportHeight: viewportHeight,
                  );
                },
                onPointerUp: (_) => _scrollController.endPointerSelection(),
                onPointerCancel: (_) => _scrollController.endPointerSelection(),
                child: TextField(
                  controller: _controller,
                  scrollController: _scrollController,
                  readOnly: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: tokens.type.metadata.copyWith(
                    color: tokens.surfaces.onSurface,
                    fontFamily: 'monospace',
                  ),
                  selectionControls: HibikiTextSelectionControls(
                    shareAction: widget.shareAction,
                    allowCopy: true,
                    allowCut: false,
                    allowPaste: false,
                    allowSelectAll: true,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.all(tokens.spacing.card),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LogSelectionScrollController extends ScrollController {
  _LogSelectionScrollController()
      : super(debugLabel: 'hibiki-log-selection-scroll');

  bool _pointerSelectionActive = false;
  bool _userScrolledDuringSelection = false;
  double? _pointerY;
  double? _viewportHeight;

  void beginPointerSelection({
    required double pointerY,
    required double viewportHeight,
  }) {
    _pointerSelectionActive = true;
    _userScrolledDuringSelection = false;
    updatePointerSelection(
      pointerY: pointerY,
      viewportHeight: viewportHeight,
    );
  }

  void updatePointerSelection({
    required double pointerY,
    required double viewportHeight,
  }) {
    _pointerY = pointerY;
    _viewportHeight = viewportHeight;
  }

  void endPointerSelection() {
    _pointerSelectionActive = false;
    _userScrolledDuringSelection = false;
    _pointerY = null;
    _viewportHeight = null;
  }

  void _markUserScroll(double oldPixels, double newPixels) {
    if (!_pointerSelectionActive) return;
    if ((newPixels - oldPixels).abs() <= 0.5) return;
    _userScrolledDuringSelection = true;
  }

  bool _allowProgrammaticScroll(double targetOffset) {
    if (!_pointerSelectionActive || !hasClients || positions.length != 1) {
      return true;
    }

    final double delta = targetOffset - position.pixels;
    if (delta.abs() <= 0.5) return true;

    final double? pointerY = _pointerY;
    final double? viewportHeight = _viewportHeight;
    if (pointerY != null && viewportHeight != null && viewportHeight > 0) {
      final double edgeBand = math.min(
        96.0,
        math.max(48.0, viewportHeight * 0.18),
      );
      final bool nearTop = pointerY <= edgeBand;
      final bool nearBottom = pointerY >= viewportHeight - edgeBand;

      if (nearTop || nearBottom) {
        final bool movesUp = delta < 0;
        final bool movesDown = delta > 0;
        return (nearTop && movesUp) || (nearBottom && movesDown);
      }
    }

    return !_userScrolledDuringSelection;
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
    if (!_allowProgrammaticScroll(offset)) {
      return Future<void>.value();
    }
    return super.animateTo(offset, duration: duration, curve: curve);
  }

  @override
  void jumpTo(double value) {
    if (!_allowProgrammaticScroll(value)) return;
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

  @override
  void applyUserOffset(double delta) {
    final double oldPixels = pixels;
    super.applyUserOffset(delta);
    controller._markUserScroll(oldPixels, pixels);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (!controller._allowProgrammaticScroll(to)) {
      return Future<void>.value();
    }
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void jumpTo(double value) {
    if (!controller._allowProgrammaticScroll(value)) return;
    super.jumpTo(value);
  }

  @override
  void pointerScroll(double delta) {
    final double oldPixels = pixels;
    super.pointerScroll(delta);
    controller._markUserScroll(oldPixels, pixels);
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
