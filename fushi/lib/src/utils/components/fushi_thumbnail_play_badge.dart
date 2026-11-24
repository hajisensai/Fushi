import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show FushiAppleFloatingSurface;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 缩略图正中的「可播放」角标（预告 / 花絮卡等，只示意、不接点击——点按由外层
/// 卡片负责）。
///
/// - MD3：[CircleAvatar] 主色容器圆 + 播放图标（与原先页面里直接写的一字不差）。
/// - Apple：iOS / macOS 视频缩略图上的浮动材质圆（[FushiAppleFloatingSurface]，
///   随「玻璃画质」档位：玻璃或实色系统材质），内放 label 色 play.fill 实心字形。
class FushiThumbnailPlayBadge extends StatelessWidget {
  const FushiThumbnailPlayBadge({super.key, this.size = 40});

  /// 圆的直径（MD3 [CircleAvatar] 默认半径 20 → 40）。
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return CircleAvatar(
        radius: size / 2,
        child: const FushiIcon(FushiIcons.play),
      );
    }
    return SizedBox.square(
      key: const ValueKey<String>('fushi-thumbnail-play-badge-apple'),
      dimension: size,
      child: FushiAppleFloatingSurface(
        shape: const CircleBorder(),
        child: Center(
          child: FushiIcon(
            FushiIcons.filled(FushiIcons.play),
            size: size * 0.5,
            color: appleColorsOf(context).label,
          ),
        ),
      ),
    );
  }
}
