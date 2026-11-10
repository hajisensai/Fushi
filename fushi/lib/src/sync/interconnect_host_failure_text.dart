/// 互联能力探测失败原因 → 界面文案的唯一映射（UI 侧）。
///
/// [InterconnectHostFailure] 是传输层与界面之间的契约，入口（AI 下视频、下载执行
/// 设备、发现页下载 / 订阅）都经这里说出具体原因：重新配对、证书变了、版本旧、
/// 连不上，而不是笼统的「没有可用主机」。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';

/// 一条原因的文案；[statusCode] 只在 [InterconnectHostFailure.httpError] 时用。
String interconnectHostFailureText(
  InterconnectHostFailure failure, {
  int? statusCode,
}) => switch (failure) {
  InterconnectHostFailure.notPaired => t.interconnect_host_failure_not_paired,
  InterconnectHostFailure.unreachable =>
    t.interconnect_host_failure_unreachable,
  InterconnectHostFailure.authRejected =>
    t.interconnect_host_failure_auth_rejected,
  InterconnectHostFailure.certificateMismatch =>
    t.interconnect_host_failure_certificate_mismatch,
  InterconnectHostFailure.unsupported =>
    t.interconnect_host_failure_unsupported,
  InterconnectHostFailure.httpError => t.interconnect_host_failure_http(
    code: statusCode?.toString() ?? '?',
  ),
};

/// 带设备名的一行：`<device>：<原因>`，用于 toast（设备名由
/// [interconnectHostLabel] 给）。
String interconnectHostFailureLine(
  InterconnectHostFailure failure, {
  required String device,
  int? statusCode,
}) => t.interconnect_host_failure_line(
  device: device,
  reason: interconnectHostFailureText(failure, statusCode: statusCode),
);

/// 「探不到可用 host」时该不该把原因说出来：凭据 / 证书 / 能力 / 配对这类用户能
/// 动手解决的说；单纯连不上与 HTTP 错误维持原来的笼统提示。
bool interconnectHostFailureWorthTelling(InterconnectHostFailure failure) =>
    switch (failure) {
      InterconnectHostFailure.authRejected ||
      InterconnectHostFailure.certificateMismatch ||
      InterconnectHostFailure.unsupported ||
      InterconnectHostFailure.notPaired => true,
      InterconnectHostFailure.unreachable ||
      InterconnectHostFailure.httpError => false,
    };

/// 全部探测结局里第一条值得说的失败（见 [interconnectHostFailureWorthTelling]），
/// 拼成带设备名的一行；没有 → null（调用方沿用原提示）。
String? interconnectFirstTellableFailureLine<T>(
  Iterable<InterconnectCapabilityOutcome<T>> outcomes,
) {
  for (final InterconnectCapabilityOutcome<T> o in outcomes) {
    if (o is InterconnectCapabilityUnavailable<T> &&
        interconnectHostFailureWorthTelling(o.failure)) {
      return interconnectHostFailureLine(
        o.failure,
        device: o.label,
        statusCode: o.statusCode,
      );
    }
  }
  return null;
}

/// 发现页下载 / 订阅这类「本机或远端都能跑」的入口，打开前要不要先说一句远端为
/// 什么用不了：只在本机跑不了（[localRunnable] 为 false，远端是唯一出路）且一台
/// 可用 host 都没有时，取第一条值得说的原因（[interconnectFirstTellableFailureLine]）。
/// 本机能跑时，已配对 host 不提供这项功能 / 没配好不是用户此刻要处理的事 → null。
String? interconnectRemoteOnlyFailureNotice<T>(
  Iterable<InterconnectCapabilityOutcome<T>> outcomes, {
  required bool localRunnable,
}) {
  if (localRunnable) return null;
  if (outcomes.any(
    (InterconnectCapabilityOutcome<T> o) =>
        o is InterconnectCapabilityAvailable<T>,
  )) {
    return null;
  }
  return interconnectFirstTellableFailureLine<T>(outcomes);
}
