/// 复习库换代迁移「没通过核对、已撤回」时的诊断报告（`srs4-migration-report.json`，只含 ID 与计数）怎么交到用户手里。
///
/// 报告落在库目录里（app 私有目录）：Android / iOS 上用户用文件管理器根本拿不到，页面上印一个
/// `/data/user/0/...` 路径等于没给。所以页面不再印路径，改成两个动作：
/// - 「把报告发给开发者」：直接打开反馈提交页，报告作样本文件自动附上（`openFeedbackComposeWith`），不用自己找文件；
/// - 「分享报告」（手机）/「保存报告」（桌面）：手机走系统分享面板（[FushiShare.shareFiles]，Android 由 FileProvider
///   给出 `content://`），桌面弹「另存为」。
///
/// 动作经 `srsGen4ReportActionsProvider`（在 `srs_generation_view.dart`）注入，页面测试换成假的（不碰反馈服务与平台
/// 通道）。打开反馈提交页的函数也由那里注入（[SrsGen4ReportActions.openFeedback]）：本文件不 import 反馈页面簇，
/// 否则会被拖进 import 大环（`test/build/import_cycle_guard_test.dart`）。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_prefill.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 报告的两个出口。
class SrsGen4ReportActions {
  const SrsGen4ReportActions({required this.openFeedback});

  /// 带着预填打开反馈提交页（生产上是 `openFeedbackComposeWith`）。
  final Future<void> Function(
    BuildContext context,
    FeedbackComposePrefill prefill,
  )
  openFeedback;

  /// 桌面没有系统分享面板这一说（Linux 根本没有），给「另存为」；手机给系统分享面板。
  bool get savesToFile => isDesktopPlatform;

  /// 打开反馈提交页，报告已附上（分类「问题」：日志默认带上，开发者能对上这次迁移的上下文）。
  Future<void> send(BuildContext context, String reportPath) => openFeedback(
    context,
    FeedbackComposePrefill(
      category: FeedbackCategory.bug,
      title: t.srs_gen4_report_feedback_title,
      body: t.srs_gen4_report_feedback_body,
      files: <File>[File(reportPath)],
    ),
  );

  /// 手机：系统分享面板；桌面：另存为。失败（面板没出来 / 写不进去）就地提示，原因进日志。
  Future<void> export(BuildContext context, String reportPath) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    void notify(String message) =>
        messenger?.showSnackBar(FushiSnackBar(content: Text(message)));
    try {
      if (savesToFile) {
        final String? dest = await FilePicker.platform.saveFile(
          dialogTitle: t.srs_gen4_report_save,
          fileName: SrsGen4Migration.reportFileName,
          type: FileType.custom,
          allowedExtensions: const <String>['json'],
        );
        if (dest == null || dest.trim().isEmpty) return;
        await File(reportPath).copy(dest);
        notify(t.srs_gen4_report_saved);
        return;
      }
      final bool shown = await FushiShare.shareFiles(<XFile>[
        XFile(reportPath, mimeType: 'application/json'),
      ], subject: t.srs_gen4_report_feedback_title);
      if (!shown) notify(t.srs_gen4_report_export_failed);
    } on Object catch (e, stack) {
      ErrorLogService.instance.log('SrsGen4Migration.exportReport', e, stack);
      notify(t.srs_gen4_report_export_failed);
    }
  }
}
