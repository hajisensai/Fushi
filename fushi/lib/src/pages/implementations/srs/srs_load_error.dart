/// 复习页面统一的加载失败态（本机库与已配对设备的远程库共用）：同一套文案映射 + 「重试」。
///
/// 远程复习（srs_remote_review_page.dart）的页面就是本机那套页面跑在远程库上，失败从同一个出口出来：
/// 连接层 / 主机报的错、回包不合契约（[SrsRemoteStoreError.badResponse]）都是 [InterconnectHostError]，
/// 按机读码出文案；本机库打开时的代际状态（要迁移 / 别的进程在迁移……）换成迁移页 / 恢复页（[SrsGenerationView]），
/// 新代还没接线的功能给明确的「暂不可用」；其余照原文。
library;

import 'package:fushi_engine/srs/srs_db_store.dart'
    show SrsProfileIdentityPending;
import 'package:fushi_engine/srs/srs_remote_store.dart'
    show SrsRemoteStoreError;
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_srs/fushi_srs.dart'
    show
        SrsCoreUnwiredException,
        SrsProfileUnboundException,
        SrsStoreOpenBlocked;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_generation_view.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart'
    show InterconnectHostError;
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 远程复习失败的提示文案（主机的机读码 / 连接层的码 / 回包不合契约）。
String srsRemoteReviewErrorText(InterconnectHostError e) => switch (e.message) {
  InterconnectHostError.unreachableCode ||
  InterconnectHostError.certificateMismatchCode =>
    t.srs_remote_review_error_unreachable,
  SrsRemoteStoreError.profileChanged =>
    t.srs_remote_review_error_profile_changed,
  SrsRemoteStoreError.unavailable => t.srs_remote_review_error_unavailable,
  SrsRemoteStoreError.stale => t.srs_remote_review_card_changed,
  SrsRemoteStoreError.badResponse => t.srs_remote_review_error_bad_response,
  SrsRemoteStoreError.upgradeRequired =>
    t.srs_remote_review_error_upgrade_required,
  SrsRemoteStoreError.migrating => t.srs_remote_review_error_host_migrating,
  SrsRemoteStoreError.migrationFailed =>
    t.srs_remote_review_error_host_migration_failed,
  _ => t.srs_remote_review_error_other(code: e.message),
};

/// 加载失败占位页的说明：远程失败按机读码出文案；辅助进程里 profile 还没有身份（[SrsProfileIdentityPending]，主进程
/// 打开时才建）与没有集合绑定（[SrsProfileUnboundException]，主进程打开时同样会建）给「先在主窗口打开复习」的等待
/// 说明；新代还没接线的功能（[SrsCoreUnwiredException]）给出明确的「暂不可用」；别的错误照原文。
String srsLoadErrorDetail(Object? error) {
  if (error is InterconnectHostError) return srsRemoteReviewErrorText(error);
  if (error is SrsProfileIdentityPending ||
      error is SrsProfileUnboundException) {
    return t.srs_gen4_profile_pending_primary;
  }
  if (error is SrsCoreUnwiredException) return t.srs_gen4_feature_unwired;
  return '$error';
}

/// 加载失败占位：「加载失败」+ 说明（[srsLoadErrorDetail]）+ 「重试」。[onRetry] 为 null 时不出按钮。
class SrsLoadErrorView extends StatelessWidget {
  const SrsLoadErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    this.retryKey,
  });

  final Object? error;
  final VoidCallback? onRetry;

  /// 重试按钮的 key（测试与焦点驱动按它找）。
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? retry = onRetry;
    final Object? error = this.error;
    // 库目录的代际状态 / 旧主库待搬：不是「加载失败」，换成迁移页 / 恢复页。
    if (error is SrsStoreOpenBlocked || error is SrsLegacyMainDatabasePending) {
      return SrsGenerationView(error: error!, onRetry: retry);
    }
    return SafeArea(
      bottom: false,
      child: Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.error,
          tone: FushiPlaceholderTone.error,
          message: t.error_load_failed,
          detail: error == null ? null : srsLoadErrorDetail(error),
          action: retry == null
              ? null
              : FushiFilledButton.tonalIcon(
                  key: retryKey,
                  onPressed: retry,
                  icon: const FushiIcon(FushiIcons.refresh),
                  label: Text(t.retry),
                ),
        ),
      ),
    );
  }
}
