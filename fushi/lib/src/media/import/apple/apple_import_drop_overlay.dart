/// Apple 导入页（方案 A）的拖放态覆盖层：文件拖进窗口时才出现——整块内容区罩
/// 一圈强调色描边 + 淡强调色底，正中一张玻璃提示卡「松手导入」（拍板第 3 条：
/// 不常驻拖放区）。不拦指针（落点在外层 `FushiFileDropTarget`）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/apple/apple_radii.dart';

class AppleImportDropOverlay extends StatelessWidget {
  const AppleImportDropOverlay({required this.visible, super.key});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    return IgnorePointer(
      child: AnimatedOpacity(
        key: const ValueKey<String>('import-drop-overlay'),
        opacity: visible ? 1 : 0,
        duration: duration,
        curve: FushiMotion.standard,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: FushiAppleRadii.of(context).groupRadius,
              border: Border.all(color: colors.accent, width: 2.5),
            ),
            child: Center(
              child: AnimatedScale(
                scale: visible ? 1 : 0.94,
                duration: fushiMotionDuration(context, FushiMotion.medium),
                curve: FushiMotion.enter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: FushiGlassSurface(
                    borderRadius: FushiAppleRadii.of(context).popoverRadius,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.accent,
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox.square(
                              dimension: 64,
                              child: Center(
                                child: FushiIcon(
                                  FushiIcons.libraryAdd,
                                  size: 32,
                                  color: colors.onAccent,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t.import_drop_release_title,
                            textAlign: TextAlign.center,
                            style: context.fushiType.titleLargeEmphasized
                                .copyWith(color: colors.label),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            t.import_drop_release_hint,
                            textAlign: TextAlign.center,
                            style: metrics.subtitleStyle(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
