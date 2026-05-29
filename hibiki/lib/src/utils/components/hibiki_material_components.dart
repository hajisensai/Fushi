import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/components/hibiki_text_selection_controls.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

class HibikiCard extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color effectiveColor =
        color ?? (selected ? tokens.surfaces.selected : tokens.surfaces.card);
    final BorderRadius radius = borderRadius ?? tokens.radii.cardRadius;
    final Widget content = Padding(
      padding: padding ?? EdgeInsets.all(tokens.spacing.card),
      child: child,
    );
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        color: effectiveColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: borderColor != null
              ? BorderSide(color: borderColor!)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: onTap == null && onLongPress == null
            ? content
            : InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: content,
              ),
      ),
    );
  }
}

class HibikiListItem extends StatelessWidget {
  const HibikiListItem({
    required this.title,
    super.key,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.minHeight = 56,
    this.padding,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 2,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final double minHeight;
  final EdgeInsetsGeometry? padding;
  final int titleMaxLines;
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color color =
        selected ? tokens.surfaces.selected : Colors.transparent;
    final Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: padding ??
            EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.rowVertical,
            ),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              IconTheme.merge(
                data: IconThemeData(color: tokens.surfaces.onVariant),
                child: leading!,
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
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    child: title,
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.spacing.gap / 4),
                      child: DefaultTextStyle.merge(
                        style: tokens.type.listSubtitle,
                        maxLines: subtitleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        child: subtitle!,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              SizedBox(width: tokens.spacing.gap + 4),
              DefaultTextStyle.merge(
                style: tokens.type.metadata,
                child: IconTheme.merge(
                  data: IconThemeData(color: tokens.surfaces.onVariant),
                  child: trailing!,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Material(
      color: color,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              child: content,
            ),
    );
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
  });

  final Key? fieldKey;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return SearchBar(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      hintText: hintText,
      leading: const Icon(Icons.search),
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
  }
}

class HibikiTextField extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: tokens.radii.cardRadius,
      borderSide: BorderSide(color: tokens.surfaces.outline),
    );
    return TextFormField(
      controller: controller,
      initialValue: initialValue,
      focusNode: focusNode,
      autofocus: autofocus,
      readOnly: readOnly,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      maxLines: expands ? null : maxLines,
      minLines: minLines,
      expands: expands,
      textAlignVertical: textAlignVertical,
      style: style ?? tokens.type.listTitle,
      decoration: InputDecoration(
        hintText: hintText,
        labelText: labelText,
        suffixText: suffixText,
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
        contentPadding: contentPadding ??
            EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal,
              vertical: tokens.spacing.rowVertical,
            ),
        suffixIcon: suffixIcon,
        prefixIcon: prefixIcon,
      ),
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
    );
  }
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
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final Widget? avatar;
  final IconData? leadingIcon;
  final String? tooltip;

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
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}

class HibikiActionChip extends StatelessWidget {
  const HibikiActionChip({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
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
  }
}

enum HibikiTagChipTone { filled, surface }

class HibikiTagChip extends StatelessWidget {
  const HibikiTagChip({
    required this.label,
    super.key,
    this.color,
    this.selected = false,
    this.dimmed = false,
    this.tone = HibikiTagChipTone.filled,
    this.onTap,
  });

  final String label;
  final Color? color;
  final bool selected;
  final bool dimmed;
  final HibikiTagChipTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color tagColor = color ?? colors.primary;
    final Color baseColor =
        color ?? (selected ? colors.primaryContainer : tokens.surfaces.overlay);
    final Color background = switch (tone) {
      HibikiTagChipTone.filled => dimmed
          ? baseColor.withValues(alpha: 0.44)
          : baseColor.withValues(alpha: color == null ? 1 : 0.88),
      HibikiTagChipTone.surface => selected
          ? tagColor.withValues(alpha: dimmed ? 0.12 : 0.2)
          : tokens.surfaces.overlay.withValues(alpha: dimmed ? 0.44 : 1),
    };
    final Color foreground = switch (tone) {
      HibikiTagChipTone.filled => _foregroundFor(background),
      HibikiTagChipTone.surface =>
        dimmed ? colors.onSurface.withValues(alpha: 0.4) : colors.onSurface,
    };
    final BoxBorder? border = selected
        ? Border.all(
            color:
                tone == HibikiTagChipTone.surface ? tagColor : colors.primary,
          )
        : null;
    final Text labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: tokens.type.metadata.copyWith(
        color: foreground,
        fontWeight: FontWeight.w600,
      ),
    );
    final Widget content = tone == HibikiTagChipTone.surface && color != null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox(width: 10, height: 10),
              ),
              SizedBox(width: tokens.spacing.gap * 0.625),
              labelText,
            ],
          )
        : labelText;
    final Widget chip = Container(
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
    if (onTap == null) return chip;
    return InkWell(
      borderRadius: tokens.radii.chipRadius,
      onTap: onTap,
      child: chip,
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
    final Widget swatch = Container(
      width: resolvedWidth,
      height: resolvedHeight,
      decoration: BoxDecoration(
        color: color,
        shape: isDot ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isDot ? null : tokens.radii.chipRadius,
        border: Border.fromBorderSide(borderSide),
      ),
    );
    final Widget interactiveSwatch = onTap == null
        ? swatch
        : InkWell(
            borderRadius: inkRadius,
            onTap: onTap,
            child: swatch,
          );
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

class HibikiPageScaffold extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.surfaces.page,
      appBar: showAppBar
          ? AppBar(
              leading: leading,
              title: const SizedBox.shrink(),
              backgroundColor: tokens.surfaces.page,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
            )
          : null,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        top: !showAppBar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            HibikiPageHeader(
              title: title,
              subtitle: subtitle,
              leading: showAppBar ? null : leading,
              actions: actions,
              bottom: headerBottom,
              compact: headerCompact ?? showAppBar,
            ),
            Expanded(child: body),
          ],
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
    return IconButton(
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const Icon(Icons.arrow_back),
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      onPressed: () => Navigator.of(context).maybePop(),
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

class HibikiOverflowMenu<T> extends StatelessWidget {
  const HibikiOverflowMenu({
    required this.items,
    required this.onSelected,
    super.key,
    this.icon = Icons.more_vert,
    this.iconWidget,
    this.tooltip,
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
    this.splashRadius,
  });

  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final IconData icon;
  final Widget? iconWidget;
  final String? tooltip;
  final double? iconSize;
  final EdgeInsetsGeometry padding;
  final double? splashRadius;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return PopupMenuButton<T>(
      tooltip: tooltip,
      icon: iconWidget ?? Icon(icon, size: iconSize),
      shape: RoundedRectangleBorder(borderRadius: tokens.radii.menuRadius),
      color: tokens.surfaces.overlay,
      padding: padding,
      splashRadius: splashRadius,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => items,
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
              style: TextStyle(
                color: tokens.surfaces.onSurface,
                fontFamily: 'monospace',
                fontSize: 12,
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
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: tokens.type.listSubtitle.copyWith(
            color: tokens.surfaces.onSurface,
            fontFamily: 'monospace',
            fontSize: 12,
          ),
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.all(tokens.spacing.card),
          ),
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
      child: IconButton(
        icon: Icon(icon, color: tokens.surfaces.onVariant, size: 20),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}
