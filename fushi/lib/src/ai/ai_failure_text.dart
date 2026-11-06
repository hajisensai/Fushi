/// AI 调用失败短码 → 界面文案的唯一映射。
library;

import 'package:fushi/i18n/strings.g.dart';

/// 把 `AiChatFailure.message` 的脱敏短码映射成界面文案。
///
/// 短码是调用层与 UI 之间的唯一契约（见 `ai_chat_client.dart`），别在别处再各自
/// 解释一遍。认不出的码原样返回（刮削运行记录里也可能是异常类型名）。
String aiFailureText(String code) {
  if (code.startsWith('http_')) {
    return t.ai_error_http(code: code.substring(5));
  }
  return switch (code) {
    'unauthorized' => t.ai_error_unauthorized,
    'rate_limited' => t.ai_error_rate_limited,
    'quota_exhausted' => t.ai_error_quota_exhausted,
    'network_error' => t.ai_error_network,
    'bad_response' => t.ai_error_bad_response,
    'empty_response' => t.ai_error_empty_response,
    // `kAiEndpointErrorCode`：服务端 2xx 回了一份错误体（多半是接口地址不对）。
    'endpoint_error' => t.ai_error_endpoint,
    'provider_not_configured' => t.ai_error_not_configured,
    // `kAiContextOverflowCode`：请求超出模型上下文窗口（反馈 GewyVIt5oo）。
    'context_overflow' => t.ai_error_context_overflow,
    // `kAiTranscriptionUnsupportedProtocol`：云端转录只认 OpenAI 兼容协议。
    'unsupported_protocol' => t.ai_error_unsupported_protocol,
    // 「互联主机」提供商（`ai_relay.dart` 的 `kAiRelay*`）。
    'relay_unavailable' => t.ai_error_relay_unavailable,
    'relay_host_not_paired' => t.ai_error_relay_host_not_paired,
    'relay_host_unreachable' => t.ai_error_relay_host_unreachable,
    'relay_certificate_mismatch' => t.ai_error_relay_certificate_mismatch,
    'relay_auth_rejected' => t.ai_error_relay_auth_rejected,
    'relay_host_unsupported' => t.ai_error_relay_host_unsupported,
    'relay_disabled' => t.ai_error_relay_disabled,
    'relay_no_provider' => t.ai_error_relay_no_provider,
    'relay_bad_request' => t.ai_error_relay_bad_request,
    'relay_operation_unsupported' => t.ai_error_relay_operation_unsupported,
    _ => code,
  };
}
