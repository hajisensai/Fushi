import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/accent_logo_image.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:fushi/src/utils/misc/logo_accent_tint.dart';

/// Renders the application icon selected in Settings (the built-in mascot icon
/// follows the theme accent, see [appIconImageProvider]) and rebuilds as soon as a
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
            // 内置吉祥物图标跟随主题强调色（自定义图片不换色）；换主题时
            // 无缝切到新图，不闪空。
            return AccentLogoTintBuilder(
              accent: Theme.of(context).colorScheme.primary,
              builder: (BuildContext context, LogoAccentTint tint) => Image(
                key: ValueKey<int>(selection.revision),
                image: appIconImageProvider(selection, tint: tint),
                gaplessPlayback: true,
                fit: fit,
                filterQuality: filterQuality,
                excludeFromSemantics: true,
                errorBuilder:
                    (
                      BuildContext context,
                      Object error,
                      StackTrace? stackTrace,
                    ) {
                      return Image.asset(
                        presetIconAssets['default']!,
                        fit: fit,
                        filterQuality: filterQuality,
                        excludeFromSemantics: true,
                      );
                    },
              ),
            );
          },
    );
  }
}
