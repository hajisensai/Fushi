import 'package:flutter/material.dart';

/// 远端书/视频卡片下载进行中时，盖在下载按钮位置的进度徽章。
///
/// [progress] 为 0..1 时显示确定进度环；为 null（收到首个 onProgress 前）显示
/// 不确定进度环。视频/书架卡片共用同一观感（#3：远端下载全程有进行中反馈）。
class RemoteDownloadProgressBadge extends StatelessWidget {
  const RemoteDownloadProgressBadge({
    required this.progress,
    required this.tooltip,
    super.key,
  });

  final double? progress;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: colors.secondaryContainer,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            value: progress,
            color: colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
