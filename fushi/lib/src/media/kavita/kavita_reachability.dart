/// Kavita 服务器「不可达」的判型与进程内记忆，漫画（`kavita_manga_sync.dart`）与
/// EPUB（`kavita_epub_sync.dart`）两条进度同步共用：服务器断开后开书 / 开章不再
/// 每次把拉取超时等满，推送失败的诊断每次断开只记一条。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 开章拉取的失败是不是「服务器不可达」：连不上 / 超时 / 连接中断，或者答话的只是
/// Kavita 前面的反向代理（502 / 503 / 504，Kavita 本体停了）。区别于 Kavita 自己
/// 答了非 2xx 或响应解析不了。
bool isKavitaUnreachableError(Object error) =>
    error is TimeoutException ||
    error is KavitaTransportException ||
    error is IOException ||
    (error is KavitaApiException && error.isGatewayUnavailable);

/// 进程内记住哪些 Kavita 服务器在开章拉取预算内答不上来。
///
/// 没有这份记忆时，服务器断开后每次开章、换章都要把
/// 开章 / 开书拉取超时 等满，读已下载的章也一样。记住之后
/// `attach` 不再等拉取（请求照发、只当探针）。
///
/// 标记不靠谁来「清」：记下的是那一刻协议层的 [KavitaApi.answerCount]，之后这台
/// 服务器对**任何**请求（探针、作品页刷新、浏览、取页图）在预算内答上话，计数一动
/// 标记就失效，下一次开章恢复完整对账。连接参数变了（协议层换了实例）同样失效。
/// 只存在内存里（进程一退就没了），不落盘。
class KavitaReachability {
  /// 生产用的进程级实例。
  static final KavitaReachability session = KavitaReachability();

  final Map<String, ({KavitaApi api, int answerCount})> _unreachable =
      <String, ({KavitaApi api, int answerCount})>{};

  /// [serverId] 是否仍按不可达处理。[api] 是这台服务器当前的协议层，[within] 是
  /// 开章拉取预算：记下之后有一次答话且用时不超过预算才算恢复（一直慢过预算的
  /// 服务器等了也用不上结果，继续不等）。
  bool isUnreachable(
    String serverId,
    KavitaApi api, {
    required Duration within,
  }) {
    final ({KavitaApi api, int answerCount})? mark = _unreachable[serverId];
    if (mark == null) return false;
    final Duration? latency = api.lastAnswerLatency;
    final bool answeredSince =
        api.answerCount != mark.answerCount &&
        latency != null &&
        latency <= within;
    if (!identical(mark.api, api) || answeredSince) {
      _unreachable.remove(serverId);
      return false;
    }
    if (api.answerCount != mark.answerCount) {
      // 答了但慢过预算：把基线挪到现在，等下一次答话再比。
      _unreachable[serverId] = (api: api, answerCount: api.answerCount);
    }
    return true;
  }

  /// 记为不可达；返回是否是这次才记上（调用方据此每次断开只记一条日志）。
  bool markUnreachable(String serverId, KavitaApi api) {
    final bool added = !_unreachable.containsKey(serverId);
    _unreachable[serverId] = (api: api, answerCount: api.answerCount);
    return added;
  }
}

/// 同步路径上被吞掉的失败（推送 / 拉取）留一条可查的记录：不可达类（离线是常态）
/// 记为 [reachability] 里的不可达，每次断开只记一条诊断；其余（Kavita 自己答了
/// 非 2xx、响应解析不了）每次都记错误。文本过 `redactCredentialsInText`（Kavita 的
/// 图片 URL 带 apiKey，异常文本里可能带出整条 URL）。
void reportKavitaSyncFailure({
  required String source,
  required Object error,
  required StackTrace stack,
  required KavitaReachability reachability,
  required String serverId,
  required KavitaApi api,
}) {
  if (isKavitaUnreachableError(error)) {
    if (reachability.markUnreachable(serverId, api)) {
      ErrorLogService.instance.logDiagnostic(
        source,
        'server unreachable: ${redactCredentialsInText('$error')}',
      );
    }
    return;
  }
  ErrorLogService.instance.log(
    source,
    redactCredentialsInText('$error'),
    stack,
  );
}
