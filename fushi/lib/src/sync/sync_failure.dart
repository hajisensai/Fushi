/// 同步报告里一条失败的**结构化**形态（反馈 L60rttoC0U）。
///
/// `SyncRunReport.errors` 是给日志看的字符串（`'<维度/条目>: <异常>'`，一字不变便于
/// 检索）；任务面板以前拿到的也只是这串字符串，只能原样上屏——用户看到的是
/// `tags live sync: SyncBackendError: No reachable Fushi server address` 这种调试句。
/// 这里把「哪一项」「因为什么」留成数据，跨编排器 → 任务表 → 面板三层活下来，面板据此
/// 用本地化文案渲染、把同因的多条合成一行；日志照旧用 [message]。
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi/src/sync/sync_peer_gap.dart';

@immutable
class SyncFailure {
  /// 只有一句原文、没有结构可依的失败（直接 `errors.add` 进来的行）。
  const SyncFailure.raw(String message)
    : _message = message,
      label = null,
      cause = null,
      peerGap = null;

  /// `<label>: <cause>`：某个维度 / 条目因 [cause] 失败。
  const SyncFailure.of(String this.label, Object this.cause)
    : _message = null,
      peerGap = null;

  /// 「对端缺能力」（[SyncPeerGap]）。
  const SyncFailure.peerGap(SyncPeerGap this.peerGap)
    : _message = null,
      label = null,
      cause = null;

  /// 已经是给用户看的一句（通道级失败，调用方已本地化），[cause] 留给面板合并同因。
  const SyncFailure.presented({
    required String message,
    required String this.label,
    required Object this.cause,
  }) : _message = message,
       peerGap = null;

  final String? _message;

  /// 写进报告 / 日志的那一行原文。
  String get message => _message ?? peerGap?.message ?? '$label: $cause';

  /// 出错的维度 / 条目标签（null = 没有结构）。
  final String? label;

  /// 失败的原因（异常对象，或子流程给出的原因字符串）。null = 没有结构。
  final Object? cause;

  /// 「对端缺能力」那一类的类型化形态。
  final SyncPeerGap? peerGap;

  @override
  bool operator ==(Object other) =>
      other is SyncFailure &&
      other.message == message &&
      other.label == label &&
      other.cause == cause &&
      other.peerGap == peerGap;

  @override
  int get hashCode => Object.hash(message, label, peerGap);
}
