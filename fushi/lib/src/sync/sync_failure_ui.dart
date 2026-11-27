/// 同步失败在后台任务面板里的呈现（反馈 L60rttoC0U）。
///
/// 输入是结构化的 [SyncFailure]（维度 / 原因），输出是给用户看的行：原因走
/// [friendlySyncErrorDetail] 的本地化文案，互联维度用本地化维度名，同一个原因的多条
/// 合成一行（「配对设备无法连接……（7 项）」），而不是把日志行
/// `tags live sync: SyncBackendError: …` 逐条原样上屏。日志里的原文不受影响。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_error_messages.dart'
    show friendlySyncErrorDetail;
import 'package:fushi/src/sync/sync_failure.dart';
import 'package:fushi/src/sync/sync_peer_gap.dart';
import 'package:fushi/src/sync/sync_peer_gap_ui.dart';

/// 失败「哪一项」的显示名：互联维度换成本地化名，其余用原标签。
String? syncFailureSubject(SyncFailure failure) {
  final String? label = failure.label;
  if (label == null) return null;
  for (final SyncPeerGapDimension d in SyncPeerGapDimension.values) {
    if (d.label == label) return syncPeerGapDimensionLabel(d);
  }
  return label;
}

/// 一组失败在面板里的行，按首次出现的顺序。
///
/// - 「对端缺能力」→ 该维度的本地化说明；
/// - 带原因的 → 本地化原因；同一原因只出一行，多于一条时带条数、不再列各项名；
/// - 只有原文的（没有结构可依）→ 原样（能还原成「对端缺能力」原句的照旧还原）。
List<String> syncFailureLines(Iterable<SyncFailure> failures) {
  // 每个输出位置要么是现成的一行，要么是一个原因分组的键。
  final List<Object> order = <Object>[];
  final Map<String, List<SyncFailure>> byReason = <String, List<SyncFailure>>{};
  for (final SyncFailure f in failures) {
    final SyncPeerGap? gap = f.peerGap;
    final Object? cause = f.cause;
    if (gap != null) {
      order.add(syncPeerGapLine(gap));
    } else if (cause == null) {
      order.add(localizedSyncTaskError(f.message));
    } else {
      final String reason = friendlySyncErrorDetail(cause);
      final List<SyncFailure>? group = byReason[reason];
      if (group == null) {
        byReason[reason] = <SyncFailure>[f];
        order.add(_ReasonKey(reason));
      } else {
        group.add(f);
      }
    }
  }
  return <String>[
    for (final Object o in order)
      if (o is _ReasonKey)
        _reasonLine(o.reason, byReason[o.reason]!)
      else
        o as String,
  ];
}

String _reasonLine(String reason, List<SyncFailure> group) {
  if (group.length > 1) {
    return t.sync_task_errors_same_reason(reason: reason, count: group.length);
  }
  final String? subject = syncFailureSubject(group.single);
  return subject == null ? reason : '$subject: $reason';
}

/// 分组键（与现成的行区分开：原因文本本身也是 String）。
class _ReasonKey {
  const _ReasonKey(this.reason);
  final String reason;
}
