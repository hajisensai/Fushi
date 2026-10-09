import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// App navigation chrome for an authored disc menu. Narrow surfaces keep only
/// the three accessible icons, leaving the disc's own buttons visible.
class BlurayDiscMenuBar extends StatelessWidget {
  const BlurayDiscMenuBar({
    required this.backLabel,
    required this.topMenuLabel,
    required this.popupMenuLabel,
    required this.onBack,
    required this.onTopMenu,
    required this.onPopupMenu,
    this.navigationEnabled = true,
    super.key,
  });

  final String backLabel;
  final String topMenuLabel;
  final String popupMenuLabel;
  final bool navigationEnabled;
  final VoidCallback onBack;
  final VoidCallback onTopMenu;
  final VoidCallback onPopupMenu;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final bool compact = constraints.maxWidth < 400 * textScale;
      Widget menuButton(
        String key,
        String label,
        IconData icon,
        VoidCallback? onPressed,
      ) {
        if (compact) {
          return FushiIconButtonControl(
            key: ValueKey<String>(key),
            tooltip: label,
            icon: FushiIcon(
              icon,
              color: onPressed == null ? Colors.white38 : Colors.white,
            ),
            onPressed: onPressed,
          );
        }
        return Flexible(
          child: FushiTooltip(
            message: label,
            child: FushiTextButton.icon(
              key: ValueKey<String>(key),
              icon: FushiIcon(icon),
              label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: onPressed,
            ),
          ),
        );
      }

      final List<Widget> buttons = <Widget>[
        FushiIconButtonControl(
          key: const ValueKey<String>('bluray-menu-exit'),
          tooltip: backLabel,
          icon: const FushiIcon(FushiIcons.back, color: Colors.white),
          onPressed: onBack,
        ),
        menuButton(
          'bluray-menu-top',
          topMenuLabel,
          FushiIcons.toc,
          navigationEnabled ? onTopMenu : null,
        ),
        menuButton(
          'bluray-menu-popup',
          popupMenuLabel,
          FushiIcons.menu,
          navigationEnabled ? onPopupMenu : null,
        ),
      ];
      return Align(
        alignment: Alignment.topLeft,
        child: Material(
          color: Colors.black87,
          borderRadius: FushiBorderRadius.control,
          child: compact
              ? Wrap(children: buttons)
              : Row(mainAxisSize: MainAxisSize.min, children: buttons),
        ),
      );
    },
  );
}
