/// 「开始一次下载」的结果：是否已交给下载 / 入库，以及要告诉用户的话。
///
/// 下载入口（发现页「下载」、「AI 下载」各后端）只**产出**结果、不自己弹 toast；
/// 页面用 [showDownloadStartNotices] 显示，桌面控制通道把同一份文字回给 CLI——
/// 两边看到的失败原因是同一个来源，CLI 不再只拿到一个 bool。
library;

import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 一条要告诉用户的话（页面上就是一条 toast）。
class DownloadStartNotice {
  const DownloadStartNotice(this.message, this.severity);

  const DownloadStartNotice.success(this.message)
    : severity = ToastSeverity.success;

  const DownloadStartNotice.info(this.message) : severity = ToastSeverity.info;

  const DownloadStartNotice.error(this.message)
    : severity = ToastSeverity.error;

  final String message;
  final ToastSeverity severity;
}

class DownloadStartResult {
  const DownloadStartResult({
    required this.started,
    this.notices = const <DownloadStartNotice>[],
    this.declinedReason,
  });

  /// 已交给下载 / 入库。
  const DownloadStartResult.started([
    this.notices = const <DownloadStartNotice>[],
  ]) : started = true,
       declinedReason = null;

  /// 没开始，原因要告诉用户（页面显示 [notices]）。
  const DownloadStartResult.failed(this.notices)
    : started = false,
      declinedReason = null;

  /// 没开始，且页面上本来就不需要提示（用户在确认框里点了取消、已在队列里…）。
  /// [reason] 只给不在现场的调用方（CLI）看。
  const DownloadStartResult.declined(String reason)
    : started = false,
      notices = const <DownloadStartNotice>[],
      declinedReason = reason;

  final bool started;
  final List<DownloadStartNotice> notices;
  final String? declinedReason;

  /// 全部提示拼成一句（CLI 展示用）；没有提示时为 null。
  String? get summary => notices.isEmpty
      ? null
      : notices.map((DownloadStartNotice n) => n.message).join('；');

  /// 没开始时的原因（有提示用提示，否则用 [declinedReason]）；开始了为 null。
  String? get failureReason => started ? null : (summary ?? declinedReason);
}

/// 页面显示一次下载结果的提示（每条一个 toast，按各自的严重度着色）。
void showDownloadStartNotices(DownloadStartResult result) {
  for (final DownloadStartNotice notice in result.notices) {
    FushiToast.show(msg: notice.message, severity: notice.severity);
  }
}
