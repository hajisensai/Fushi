import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';

/// A clickable MD3-style tag used in dictionary entries.
class HibikiTag extends StatelessWidget {
  const HibikiTag({
    required this.text,
    required this.backgroundColor,
    this.message,
    this.trailingText,
    this.icon,
    this.foregroundColor,
    this.iconSize,
    this.style,
    super.key,
  });

  final IconData? icon;
  final String text;
  final String? message;
  final String? trailingText;
  final Color backgroundColor;
  final Color? foregroundColor;
  final double? iconSize;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color effectiveForeground =
        foregroundColor ?? scheme.onSecondaryContainer;
    final TextStyle effectiveStyle = style ??
        Theme.of(context).textTheme.labelSmall?.copyWith(
              color: effectiveForeground,
            ) ??
        TextStyle(color: effectiveForeground);

    return Padding(
      padding: EdgeInsetsDirectional.only(end: tokens.spacing.gap / 2),
      child: Material(
        color: backgroundColor,
        shape: RoundedRectangleBorder(borderRadius: tokens.radii.chipRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: message == null
              ? null
              : () {
                  HibikiToast.show(
                    backgroundColor: backgroundColor,
                    textColor: effectiveForeground,
                    msg: message!,
                    toastLength: Toast.LENGTH_SHORT,
                    gravity: ToastGravity.BOTTOM,
                  );
                },
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.gap,
              vertical: tokens.spacing.gap / 2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    color: effectiveForeground,
                    size: iconSize ??
                        Theme.of(context).textTheme.labelSmall?.fontSize,
                  ),
                  SizedBox(width: tokens.spacing.gap / 2),
                ],
                Flexible(
                  child: Text(
                    text,
                    style: effectiveStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailingText != null) ...[
                  SizedBox(width: tokens.spacing.gap / 2),
                  Flexible(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer,
                        borderRadius: tokens.radii.chipRadius,
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: tokens.spacing.gap / 2,
                          vertical: tokens.spacing.gap / 4,
                        ),
                        child: Text(
                          trailingText!,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: scheme.onTertiaryContainer),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
