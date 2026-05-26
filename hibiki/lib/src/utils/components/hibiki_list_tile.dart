import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/utils.dart';

/// Used for various dialogs, such as the dictionary, profiles and enhancements
/// menus. Used for listing, selecting and reordering items.
class HibikiListTile extends StatelessWidget {
  /// Initialise this widget.
  const HibikiListTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    this.foregroundColor,
    this.onTap,
    this.trailing,
    super.key,
  });

  /// Whether or not this title is currently selected.
  final bool selected;

  /// The primary text of this tile.
  final String title;

  /// The secondary text of this tile.
  final String subtitle;

  /// The icon to show as the leading content of this tile.
  final IconData icon;

  /// The foreground color affecting the text and icon of this tile.
  final Color? foregroundColor;

  /// The action to perform if this tile is tapped.
  final Function()? onTap;

  /// Widget shown at the end of the tile. Shown only when selected.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return HibikiListItem(
      selected: selected,
      onTap: onTap,
      leading: Icon(
        icon,
        color: foregroundColor,
      ),
      title: HibikiMarquee(
        text: title,
        style:
            foregroundColor == null ? null : TextStyle(color: foregroundColor),
      ),
      subtitle: HibikiMarquee(
        text: subtitle,
        style:
            foregroundColor == null ? null : TextStyle(color: foregroundColor),
      ),
      trailing: trailing != null && selected
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                trailing!,
                const Space.semiSmall(),
              ],
            )
          : const Space.semiSmall(),
    );
  }
}
