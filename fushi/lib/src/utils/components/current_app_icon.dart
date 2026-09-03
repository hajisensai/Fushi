import 'package:flutter/material.dart';

import 'package:fushi/src/utils/misc/app_icon_preferences.dart';

/// Renders the application icon selected in Settings and rebuilds as soon as a
/// the native switch succeeds (and normally after its preference is persisted).
class CurrentAppIcon extends StatelessWidget {
  const CurrentAppIcon({
    super.key,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.medium,
  });

  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppIconSelection>(
      valueListenable: currentAppIconSelection,
      builder:
          (BuildContext context, AppIconSelection selection, Widget? child) {
            return Image(
              key: ValueKey<int>(selection.revision),
              image: appIconImageProvider(selection),
              fit: fit,
              filterQuality: filterQuality,
              excludeFromSemantics: true,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stackTrace) {
                    return Image.asset(
                      presetIconAssets['default']!,
                      fit: fit,
                      filterQuality: filterQuality,
                      excludeFromSemantics: true,
                    );
                  },
            );
          },
    );
  }
}
