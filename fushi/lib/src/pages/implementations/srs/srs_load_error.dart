/// 复习页面统一的加载失败态（本机库与已配对设备的远程库共用）：同一套文案映射 + 「重试」。
///
/// 远程复习（srs_remote_review_page.dart）的页面就是本机那套页面跑在远程库上，失败从同一个出口出来：
/// 连接层 / 主机报的错、回包不合契约（[SrsRemoteStoreError.badResponse]）都是 [InterconnectHostError]，
/// 按机读码出文案；本机库的已知失败（升级空间不够）给可读说明；其余照原文。
library;

import 'package:fushi_engine/srs/srs_remote_store.dart'
    show SrsRemoteStoreError;
import 'package:fushi_srs/fushi_srs.dart' show SrsUpgradeNoSpaceException;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart'
    show InterconnectHostError;
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';

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
  _ => t.srs_remote_review_error_other(code: e.message),
};

/// 加载失败占位页的说明：远程失败按机读码出文案；升级格式空间不够（[SrsUpgradeNoSpaceException]）给出可读的
/// 「还要腾出多少」；别的错误照原文。
String srsLoadErrorDetail(Object? error) {
  if (error is InterconnectHostError) return srsRemoteReviewErrorText(error);
  if (error is SrsUpgradeNoSpaceException) {
    final int short = error.neededBytes - error.freeBytes;
    return t.srs_storage_upgrade_no_space(
      size: FushiByteFormat.bytes(short > 0 ? short : error.neededBytes),
    );
  }
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
