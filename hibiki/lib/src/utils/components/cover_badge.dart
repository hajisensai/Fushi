import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';

/// 封面角标：压在封面图上的半透明黑胶囊（图标 + 可选文字）。
///
/// 统一书架/视频/游戏卡上「字幕/云端/播放列表/有声书」等角标的观感——此前
/// 同款胶囊在 home_video_page / remote.part 等处至少复制三份且 alpha 各异
/// （0.55~0.62）。封面上的角标底色**有意**固定深色而非跟随主题：它压在任意
/// 亮度的封面图上，跟随 colorScheme 反而在浅色主题下失去对比。
///
/// eink：半透明黑在墨水屏上合成抖动中间灰，改纯黑实底（前景仍是纯白）。
class CoverBadge extends StatelessWidget {
  const CoverBadge({
    required this.icon,
    this.label,
    this.iconSize = 14,
    super.key,
  });

  /// 角标图标（14px 白色，与既有视频卡角标同规格）。
  final IconData icon;

  /// 可选文字（如播放列表集数「12」）；null 时为纯图标胶囊。
  final String? label;

  /// 图标尺寸，默认 14。
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: eink ? Colors.black : Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: iconSize, color: Colors.white),
          if (label != null) ...[
            const SizedBox(width: 4),
            Text(
              label!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}
