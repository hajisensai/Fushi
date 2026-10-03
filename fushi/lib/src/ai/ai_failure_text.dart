/// AI 调用失败短码 → 界面文案的唯一映射。
library;

import 'package:fushi/utils.dart';

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
    'network_error' => t.ai_error_network,
    'bad_response' => t.ai_error_bad_response,
    'empty_response' => t.ai_error_empty_response,
    'provider_not_configured' => t.ai_error_not_configured,
    _ => code,
  };
}
