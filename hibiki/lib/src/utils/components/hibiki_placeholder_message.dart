import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// Used to show information or error messages across the application.
/// For example, this is used for the empty placeholder messages on the home
/// tabs when there are no media item entries in them.
class HibikiPlaceholderMessage extends StatelessWidget {
  /// Instantiate a decorative information/error message with an icon.
  const HibikiPlaceholderMessage({
    required this.icon,
    required this.message,
    this.color,
    this.iconSize,
    this.messageStyle,
    super.key,
  });

  /// Decorative icon that is appropriate to relay the message even
  /// if a user may not understand the message.
  final IconData icon;

  /// A message to be shown below the icon that briefly explains the
  /// information or error to be relayed to the user.
  final String message;

  /// The color to be used for the icon and the message, if null,
  /// this is the unselected widget color defined by the app theme.
  final Color? color;

  /// The size of the icon in logical pixels.
  final double? iconSize;

  /// The text style to be used to display the message below the icon.
  final TextStyle? messageStyle;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color foreground = color ?? tokens.surfaces.onVariant;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaces.group,
            borderRadius: tokens.radii.cardRadius,
          ),
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: iconSize ??
                      Theme.of(context).textTheme.headlineMedium?.fontSize,
                  color: foreground,
                ),
                SizedBox(height: tokens.spacing.gap),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: messageStyle ??
                      Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: foreground,
                          ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
