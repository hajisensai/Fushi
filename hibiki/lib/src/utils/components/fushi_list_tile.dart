import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:fushi/utils.dart';

/// Used for various dialogs, such as the dictionary, profiles and enhancements
/// menus. Used for listing, selecting and reordering items.
class FushiListTile extends StatelessWidget {
  /// Initialise this widget.
  const FushiListTile({
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
    return FushiListItem(
      selected: selected,
      onTap: onTap,
      leading: Icon(
        icon,
        color: foregroundColor,
      ),
      title: FushiMarquee(
        text: title,
        style:
            foregroundColor == null ? null : TextStyle(color: foregroundColor),
      ),
      subtitle: FushiMarquee(
        text: subtitle,
        style:
            foregroundColor == null ? null : TextStyle(color: foregroundColor),
      ),
      trailing: trailing != null && selected
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                trailing!,
                const Gap(6),
              ],
            )
          : const Gap(6),
    );
  }
}
