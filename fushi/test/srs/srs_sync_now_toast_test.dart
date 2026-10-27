import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_import_entry.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress_ui.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/utils.dart';

/// 牌组列表「立即同步」的提示：配置了但这轮失败，不能说成「还没有配置同步服务」
/// （iOS 互联客户端曾因此被误导去找已经配好的设置）。
void main() {
  test('没有任何目录、也没有失败：提示没配置', () {
    final ({String msg, ToastSeverity severity}) toast = srsSyncNowToast(
      const SrsSyncNowResult(ran: 0),
    );
    expect(toast.msg, t.srs_sync_no_backend);
    expect(toast.severity, ToastSeverity.info);
  });

  test('通道抛错：提示同步失败并带上原因，不提示没配置', () {
    final ({String msg, ToastSeverity severity}) toast = srsSyncNowToast(
      SrsSyncNowResult(ran: 0, errors: <Object>[Exception('host unreachable')]),
    );
    expect(toast.msg, isNot(t.srs_sync_no_backend));
    expect(toast.msg, contains('host unreachable'));
    expect(toast.severity, ToastSeverity.error);
  });

  test('部分目录失败：仍按失败提示', () {
    final ({String msg, ToastSeverity severity}) toast = srsSyncNowToast(
      const SrsSyncNowResult(
        ran: 1,
        errors: <Object>[SrsSyncReportError(kSrsSyncServerTimeUnavailable)],
      ),
    );
    expect(
      toast.msg,
      t.srs_sync_failed(reason: t.srs_sync_backend_unsupported),
    );
    expect(toast.severity, ToastSeverity.error);
  });

  test('目录身份拿不到：给人话原因', () {
    expect(
      srsSyncErrorReason(
        const SrsSyncReportError(kSrsSyncDirectoryIdentityUnavailable),
      ),
      t.srs_sync_directory_unidentified,
    );
  });

  test('本机 SRS 副本打不开：给人话原因', () {
    expect(
      srsSyncErrorReason(const SrsSyncReportError(kSrsSyncStoreUnavailable)),
      t.srs_sync_store_unavailable,
    );
  });

  test('全部成功：提示已同步', () {
    final ({String msg, ToastSeverity severity}) toast = srsSyncNowToast(
      const SrsSyncNowResult(ran: 2),
    );
    expect(toast.msg, t.srs_sync_done);
    expect(toast.severity, ToastSeverity.success);
  });

  test('「立即同步」点下：没在跑 → 立刻说开始同步', () {
    expect(srsSyncNowStartToast(null), t.srs_sync_now_started);
  });

  test('「立即同步」点下：已有一轮在跑 → 立刻说正在同步并带进度，不静默排队', () {
    const SrsSyncProgress running = SrsSyncProgress(
      stage: SrsSyncStage.downloading,
      done: 123,
      total: 2048,
    );
    final String msg = srsSyncNowStartToast(running);
    expect(msg, t.srs_sync_now_busy(progress: srsSyncProgressLine(running)));
    expect(msg, contains('123'));
    expect(msg, contains('2048'));
  });
}
