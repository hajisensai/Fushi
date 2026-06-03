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
          child: widget.onTap == null && widget.onLongPress == null
              ? content
              : InkWell(
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
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
                data: IconThemeData(color: tokens.surfaces.onVariant),
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
                    style: tokens.type.listTitle,
                    maxLines: widget.titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    child: widget.title,
                  ),
                  if (widget.subtitle != null)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.spacing.gap / 4),
                      child: DefaultTextStyle.merge(
                        style: tokens.type.listSubtitle,
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
                style: tokens.type.metadata,
                child: IconTheme.merge(
                  data: IconThemeData(color: tokens.surfaces.onVariant),
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
    final Widget material = AnimatedContainer(
      duration: hibikiMd3StateDuration,
      curve: hibikiMd3StateCurve,
      margin: pill
          ? EdgeInsets.symmetric(horizontal: tokens.spacing.gap)
          : EdgeInsets.zero,
      color: pill ? null : color,
      decoration: pill
          ? BoxDecoration(color: color, borderRadius: highlightRadius)
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
    this.focusId,
  });

  final Key? fieldKey;
  final HibikiFocusId? focusId;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Widget? trailing = _hibikiTextFieldInputSuffix(
      context: context,
      controller: controller,
      onChanged: onChanged,
    );
    final SearchBar searchBar = SearchBar(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      hintText: hintText,
      leading: const Icon(Icons.search),
      trailing: trailing == null ? null : <Widget>[trailing],
      elevation: const WidgetStatePropertyAll<double>(0),
      backgroundColor: WidgetStatePropertyAll<Color>(tokens.surfaces.search),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: tokens.radii.controlRadius),
      ),
      textStyle: WidgetStatePropertyAll<TextStyle>(tokens.type.listTitle),
      hintStyle: WidgetStatePropertyAll<TextStyle>(tokens.type.listSubtitle),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
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
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? avatar;
  final IconData? leadingIcon;
  final String? tooltip;
  final HibikiFocusId? focusId;

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
        overflow: TextOverflow.ellipsis,
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
    final Widget interactiveSwatch;
    if (onTap == null) {
      interactiveSwatch = swatch;
    } else {
      // Under a HibikiFocusRoot the directional focus controller navigates ONLY
      // between registered HibikiFocusTargets — a bare InkWell makes its own
      // (unregistered) Focus node, so gamepad/keyboard navigation skips the
      // whole swatch row (the theme picker was unreachable: "到不了主题的位置").
      // Register each swatch as a single focus stop (A/Enter activates onTap),
      // keeping the InkWell for mouse/touch ripple but barring it from grabbing
      // a competing focus node. Off-root (mobile touch) the InkWell is unchanged.
      final bool underFocusRoot =
          HibikiFocusRoot.maybeControllerOf(context) != null;
      final Widget inkSwatch = Material(
        color: Colors.transparent,
        borderRadius: inkRadius,
        child: InkWell(
          borderRadius: inkRadius,
          onTap: onTap,
          canRequestFocus: !underFocusRoot,
          child: swatch,
        ),
      );
      interactiveSwatch = underFocusRoot
          ? HibikiActivatableFocusTarget(
              focusIdPrefix: 'color-swatch',
              onTap: onTap!,
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        semanticSwatch,
        SizedBox(height: tokens.spacing.gap / 2),
        Text(
          label!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tokens.type.metadata.copyWith(
            color: textColor ?? tokens.surfaces.onSurface,
          ),
        ),
      ],
    );
  }
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
                Flexible(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Wrap(
                      spacing: tokens.spacing.gap / 2,
                      runSpacing: tokens.spacing.gap / 2,
                      alignment: WrapAlignment.end,
                      children: actions,
                    ),
                  ),
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

class HibikiLogPanel extends StatelessWidget {
  const HibikiLogPanel({
    required this.log,
    required this.shareAction,
    super.key,
  });

  final String log;
  final ValueChanged<String> shareAction;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: HibikiCard(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: SingleChildScrollView(
            child: SelectableText(
              log,
              style: tokens.type.metadata.copyWith(
                color: tokens.surfaces.onSurface,
                fontFamily: 'monospace',
              ),
              selectionControls: HibikiTextSelectionControls(
                shareAction: shareAction,
                allowCopy: true,
                allowCut: false,
                allowPaste: false,
                allowSelectAll: true,
              ),
            ),
          ),
        ),
      ),
    );
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
