import 'package:flutter/material.dart';
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
          side: BorderSide(color: borderColor ?? tokens.surfaces.outline),
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
