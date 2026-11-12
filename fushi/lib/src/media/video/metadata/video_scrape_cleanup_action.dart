import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_cleanup_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';

bool _videoScrapeCleanupRunning = false;

/// 确认框里「同时删除 Fushi 生成的 NFO 与图片」勾选行的 key（测试 / 焦点驱动定位）。
const Key videoScrapeClearAllDeleteFilesCheckboxKey = ValueKey<String>(
  'video_scrape_clear_all_delete_files',
);

/// 清理事务成功提交后的进程内广播。
///
/// 视频来源页是保活页；只刷新触发按钮所在的 widget 会让隐藏的来源页继续显示
/// 已删除的「上次刮削」摘要。来源页监听此 revision 后从数据库重读。
final ValueNotifier<int> videoScrapeCleanupRevision = ValueNotifier<int>(0);

Future<VideoScrapeCleanupResult> _clearAllCommitted(
  FushiDatabase database,
  VideoScrapeCleanupMode mode,
) async {
  final VideoScrapeCleanupResult result = await VideoScrapeCleanupService(
    database: database,
  ).clearAll(mode: mode);
  videoScrapeCleanupRevision.value += 1;
  // 取证：用户反馈「清理后 NFO 还在」（Feedback 7NBVwW-6Qc）时，日志里要能分清是
  // 选了只清记录、文件被保护（改过 / 路径不安全），还是 ledger 记的路径已不存在。
  ErrorLogService.instance.logDiagnostic(
    'video.scrape.clearAll',
    result.diagnosticSummary,
  );
  return result;
}

/// 确认框勾选态 → 清理方式。勾上「同时删除 Fushi 生成的 NFO 与图片」才删文件。
VideoScrapeCleanupMode videoScrapeCleanupModeFor({
  required bool deleteGeneratedFiles,
}) => deleteGeneratedFiles
    ? VideoScrapeCleanupMode.recordsAndGeneratedFiles
    : VideoScrapeCleanupMode.recordsOnly;

/// 完成提示：只清记录时明说文件已保留；删文件时有被保护的文件再单独说明。
String videoScrapeCleanupCompletedMessage(VideoScrapeCleanupResult result) {
  if (result.mode == VideoScrapeCleanupMode.recordsOnly) {
    return t.video_source_scrape_clear_all_completed_files_kept;
  }
  return result.preservedFiles
      ? t.video_source_scrape_clear_all_completed_protected
      : t.video_source_scrape_clear_all_completed;
}

/// 无界面版本（控制通道 `fushi_cli config run video.library.scrape_records_clear_all
/// --yes`）：确认由调用方给出，其余与 [showClearAllVideoScrapeRecordsAction] 同一条
/// single-flight 与完成广播。已有清理在跑时抛 [StateError]；清理事务本身忙时
/// 原样抛 [VideoScrapeCleanupBusyException]。
Future<VideoScrapeCleanupResult> clearAllVideoScrapeRecords(
  FushiDatabase database, {
  required VideoScrapeCleanupMode mode,
}) async {
  if (_videoScrapeCleanupRunning) {
    throw StateError(t.video_source_scrape_clear_all_in_progress);
  }
  _videoScrapeCleanupRunning = true;
  try {
    return await _clearAllCommitted(database, mode);
  } finally {
    _videoScrapeCleanupRunning = false;
  }
}

/// 展示统一确认框并清理全部视频刮削记录。
///
/// 确认框带一个勾选行「同时删除 Fushi 生成的 NFO 与图片」，默认勾上（保持此前
/// 的清理范围）；取消勾选即「只清记录」，磁盘上的文件一个不动。
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
                message: t.video_source_scrape_clear_all_records_body,
                confirmLabel: t.video_source_scrape_clear_all_confirm_action,
                leadingIcon: FushiIcons.deleteSweep,
                checkboxLabel: t.video_source_scrape_clear_all_delete_files,
                checkboxInitialValue: true,
                checkedNote: t.video_source_scrape_clear_all_delete_files_note,
                checkboxKey: videoScrapeClearAllDeleteFilesCheckboxKey,
              ),
        );
    if (confirmed == null || !context.mounted) return false;

    final VideoScrapeCleanupResult result = await _clearAllCommitted(
      database,
      videoScrapeCleanupModeFor(deleteGeneratedFiles: confirmed.checked),
    );
    if (!context.mounted) return true;

    onCompleted?.call();
    _showVideoScrapeCleanupSnackBar(
      context,
      videoScrapeCleanupCompletedMessage(result),
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
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(FushiSnackBar(content: Text(message)));
}
