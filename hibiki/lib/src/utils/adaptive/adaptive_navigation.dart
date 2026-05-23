import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';

class AdaptiveNavItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  const AdaptiveNavItem({
    required this.icon,
    required this.label,
    this.selectedIcon,
  });
}

Widget adaptiveBottomBar({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
}) {
  if (isCupertinoPlatform(context)) {
    return CupertinoTabBar(
      currentIndex: currentIndex,
      onTap: onTap,
      items: items
          .map((AdaptiveNavItem e) => BottomNavigationBarItem(
                icon: Icon(e.icon),
                label: e.label,
              ))
          .toList(),
    );
  }
  return NavigationBar(
    selectedIndex: currentIndex,
    onDestinationSelected: onTap,
    destinations: items
        .map((AdaptiveNavItem e) => NavigationDestination(
              icon: Icon(e.icon),
              selectedIcon: Icon(e.selectedIcon ?? e.icon),
              label: e.label,
            ))
        .toList(),
  );
}

PreferredSizeWidget adaptiveAppBar({
  required BuildContext context,
  Widget? leading,
  Widget? title,
  List<Widget>? actions,
  double? titleSpacing,
  PreferredSizeWidget? bottom,
}) {
  if (isCupertinoPlatform(context)) {
    final navBar = CupertinoNavigationBar(
      leading: leading,
      middle: title,
      trailing: actions != null && actions.isNotEmpty
          ? Row(mainAxisSize: MainAxisSize.min, children: actions)
          : null,
    );
    if (bottom == null) return navBar;
    return _CupertinoAppBarWithBottom(navBar: navBar, bottom: bottom);
  }
  return AppBar(
    leading: leading,
    title: title,
    actions: actions,
    titleSpacing: titleSpacing,
    bottom: bottom,
  );
}

class _CupertinoAppBarWithBottom extends StatelessWidget
    implements PreferredSizeWidget {
  final CupertinoNavigationBar navBar;
  final PreferredSizeWidget bottom;

  const _CupertinoAppBarWithBottom(
      {required this.navBar, required this.bottom});

  @override
  Size get preferredSize => Size.fromHeight(
      navBar.preferredSize.height + bottom.preferredSize.height);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [navBar, bottom],
    );
  }
}
