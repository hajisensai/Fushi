import 'package:flutter/material.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_cleanup_service.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

bool _videoScrapeCleanupRunning = false;

/// 清理事务成功提交后的进程内广播。
///
/// 视频来源页是保活页；只刷新触发按钮所在的 widget 会让隐藏的来源页继续显示
/// 已删除的「上次刮削」摘要。来源页监听此 revision 后从数据库重读。
final ValueNotifier<int> videoScrapeCleanupRevision = ValueNotifier<int>(0);

/// 展示统一确认框并清理全部视频刮削记录。
///
/// 设置页与视频「导入」页共用这一入口，避免两个按钮各自维护确认、single-flight、
/// 错误提示和完成刷新语义。返回 true 表示清理事务已经成功提交。
Future<bool> showClearAllVideoScrapeRecordsAction({
  required BuildContext context,
  required FushiDatabase database,
  VoidCallback? onCompleted,
}) async {
  if (_videoScrapeCleanupRunning) {
    _showVideoScrapeCleanupSnackBar(
      context,
      t.video_source_scrape_clear_all_in_progress,
    );
    return false;
  }

  // 在弹确认框前占住 single-flight，快速双击或从两个入口同时触发都只会出现一个
  // 确认框，也不会在稍后重复执行清理事务。
  _videoScrapeCleanupRunning = true;
  try {
    final FushiDestructiveConfirmResult? confirmed =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext dialogContext) =>
              FushiDestructiveConfirmDialog(
                title: t.video_source_scrape_clear_all_confirm_title,
                message: t.video_source_scrape_clear_all_confirm_body,
                confirmLabel: t.video_source_scrape_clear_all_confirm_action,
                leadingIcon: Icons.delete_sweep_outlined,
              ),
        );
    if (confirmed == null || !context.mounted) return false;

    final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
      database: database,
    ).clearAll();
    videoScrapeCleanupRevision.value += 1;
    if (!context.mounted) return true;

    onCompleted?.call();
    _showVideoScrapeCleanupSnackBar(
      context,
      result.preservedFiles
          ? t.video_source_scrape_clear_all_completed_protected
          : t.video_source_scrape_clear_all_completed,
    );
    return true;
  } on VideoScrapeCleanupBusyException {
    _showVideoScrapeCleanupSnackBar(
      context,
      t.video_source_scrape_clear_all_busy,
    );
    return false;
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('video.scrape.clearAll', error, stack);
    _showVideoScrapeCleanupSnackBar(
      context,
      t.video_source_scrape_clear_all_failed,
    );
    return false;
  } finally {
    _videoScrapeCleanupRunning = false;
  }
}

void _showVideoScrapeCleanupSnackBar(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
