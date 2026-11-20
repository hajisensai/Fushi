/// AI 助手通用联网搜索（`web.search` / `web.read`）的判据：可用性、首次确认状态、
/// 给人看的后端名。路由（`ops/ctl_web_search_routes.dart`）、操作描述与助手页的确认卡
/// 共用这一份；本文件只依赖引擎的 [WebSearchConfig] 与偏好键常量，不读 AppModel
/// （助手页 import 它不会把操作目录拖进 import 大环）。
library;

import 'package:fushi_cli/fushi_cli.dart' show OpAvailability;
import 'package:fushi_engine/ai/web_search.dart';

import 'package:fushi/src/models/preference_keys.dart'
    show kAiAgentWebSearchAllow, kAiAgentWebSearchOff;

/// 两条操作此刻能不能用：后端没配全 → `no_search_backend`；用户在设置里关了 →
/// `web_search_off`。还没同意不算不可用（第一次用时出确认卡）。
OpAvailability agentWebSearchAvailability(
  WebSearchConfig? config,
  String consent,
) {
  if (config == null || !config.isUsable) {
    return const OpAvailability.unavailable(
      'no_search_backend',
      'No web search backend is configured. The user can set one up in '
          'Settings › AI › Web search.',
    );
  }
  if (consent == kAiAgentWebSearchOff) {
    return const OpAvailability.unavailable(
      'web_search_off',
      'The user turned off web search for the assistant in Settings › AI › '
          'Web search.',
    );
  }
  return const OpAvailability.available();
}

/// 偏好值是否表示用户已同意（首次确认点过同意）。
bool agentWebSearchConsentGranted(String consent) =>
    consent == kAiAgentWebSearchAllow;

/// 给人看的后端名（确认卡、拒绝消息用）：Brave 写 `Brave Search`；SearXNG 带实例
/// 主机名（搜索词实际去的是那台机器）。
String webSearchBackendLabel(WebSearchConfig config) => switch (config.kind) {
  WebSearchKind.brave => 'Brave Search',
  WebSearchKind.searxng => switch (config.searxngBase?.host) {
    final String host when host.isNotEmpty => 'SearXNG ($host)',
    _ => 'SearXNG',
  },
};

/// 助手页确认卡按它认出这两条操作，换成「允许 AI 助手联网搜索？」的文案。
final RegExp kAgentWebSearchOp = RegExp(r'^web\.(search|read)$');
