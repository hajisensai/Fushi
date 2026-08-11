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
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: colors.errorContainer,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.error_outline,
          size: 18,
          color: colors.onErrorContainer,
        ),
      ),
    );
  }
}
