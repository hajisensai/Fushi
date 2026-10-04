import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi/src/utils/components/fushi_download_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 远端书 / 视频 / 合集 / 集卡片下载进行中时**铺满封面**的下载态：半透明压暗 +
/// 居中进度环 + 百分比（共享 [FushiDownloadCoverOverlay]，MD3 Expressive 波浪环 /
/// Apple iOS 细圆环，下满 100% 淡出）。
///
/// [progress] 为 0..1 时是确定进度；为 null（收到首个 onProgress 前）且有
/// [receivedBytes] / [totalBytes] 时按字节推，仍推不出则显示不定态加载指示 +
/// 已下载字节。视频/书架卡片共用同一观感（#3：远端下载全程有进行中反馈）。
///
/// 自身撑满父级：封面 Stack 里用 [positionRemoteDownloadBadge] 落位（进度态
/// `Positioned.fill`、失败角标留在角上）。不拦截点击，点按仍落到卡片本体。
class RemoteDownloadProgressBadge extends StatelessWidget {
  const RemoteDownloadProgressBadge({
    required this.progress,
    required this.tooltip,
    this.receivedBytes,
    this.totalBytes,
    super.key,
  });

  final double? progress;

  /// 读屏标签（「下载中」）；值读百分比 / 已下载字节。
  final String tooltip;

  final int? receivedBytes;
  final int? totalBytes;

  @override
  Widget build(BuildContext context) {
    return FushiDownloadCoverOverlay(
      value: progress,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
      semanticsLabel: tooltip,
    );
  }
}

/// 下载态角标在封面 Stack 里的落位：进度态（[RemoteDownloadProgressBadge]）铺满
/// 封面，其它角标（失败等）交给 [corner] 放回原来的角。
Widget positionRemoteDownloadBadge(
  Widget badge, {
  required Widget Function(Widget badge) corner,
}) {
  if (badge is RemoteDownloadProgressBadge) {
    return Positioned.fill(child: badge);
  }
  return corner(badge);
}

/// 远端下载**失败**角标（BUG-1561）。
///
/// 下载任务活在 app 级 [InterconnectDownloadManager] 里、与页面生命周期无关，所以
/// 失败很可能发生在用户已经离开该页之后——那条 SnackBar 根本没人看得见。占位卡上
/// 的这个角标是失败态唯一恒定的出口：重进页面照样看得到，tooltip 给出真实错误文本，
/// 再点一次下载即可重试（重试会把上一轮的失败态顶掉）。
class RemoteDownloadFailedBadge extends StatelessWidget {
  const RemoteDownloadFailedBadge({
    required this.tooltip,
    super.key,
  });

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiTooltip(
      message: tooltip,
      child: Container(
        width: 32,
        height: 32,
        // 失败只体现在图标颜色上（CoverBadge 状态色口径），圆盘本身是封面
        // 角标的统一底色。
        decoration: BoxDecoration(
          color: coverBadgeScrim(context),
          shape: BoxShape.circle,
          // eink：errorContainer == 页面底色，圆盘压在封面上没有边；图标本身
          // 已表达「失败」，描边只为把角标体画出来。
          border:
              isEinkTheme(context) ? Border.all(color: colors.outline) : null,
        ),
        alignment: Alignment.center,
        child: FushiIcon(
          Icons.error_outline,
          size: 18,
          color: coverBadgeStatusColor(context, error: true),
        ),
      ),
    );
  }
}
