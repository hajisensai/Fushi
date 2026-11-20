import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_web_search_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// AI 助手通用联网搜索的操作描述（路由见 `ctl_web_search_routes.dart`）。
///
/// 两条都是 irreversible：搜索词 / 要读的网页地址发给已指派 LLM 以外的第三方（用户
/// 配的搜索后端、结果所在网站），撤销收不回（spec §5.2）。但所有者 2026-11-20 定了
/// 「第一次要确认吧」：用户在确认卡上点过一次同意后记进本机偏好，[consentGranted]
/// 为真，AI 助手不再逐次出卡（spec §5.2「首次确认」）。用户在「设置 › AI › 联网搜索」
/// 关掉后两条都不可用，再打开要重新确认。
///
/// 不在模块开关下：与内置浏览器（`web.open` 等，「浏览器」模块）无关，只看搜索后端
/// 配没配、用户关没关。
List<OpDescription> describeWebSearchOps(OpDescribeKit kit) {
  PreferencesRepository prefs() => kit.context.appModel.prefsRepo;
  OpAvailability availability() => agentWebSearchAvailability(
    prefs().aiWebSearchConfig,
    prefs().aiAgentWebSearchConsent,
  );
  bool granted() => agentWebSearchConsentGranted(prefs());
  const OpParam consent = OpParam.userGate(
    'confirm',
    description:
        'User agreed (once, remembered on this device) that search words and '
        'the addresses of pages to read are sent to the configured search '
        'backend.',
  );
  return <OpDescription>[
    OpDescription(
      id: 'web.search',
      method: 'POST',
      pattern: kWebSearchCtlSearch,
      summary:
          'Search the public web with the search backend the user configured '
          '(SearXNG / Brave). Returns result ids with title, snippet and site; '
          'read a result with web.read. The query is sent to that backend.',
      risk: OpRisk.irreversible,
      availability: availability,
      consentGranted: granted,
      params: const <OpParam>[
        OpParam.string(
          'query',
          description: 'Search words.',
          required: true,
        ),
        OpParam.integer(
          'limit',
          description:
              'Max results (default $kWebSearchDefaultLimit, '
              'at most $kWebSearchMaxLimit).',
        ),
        consent,
      ],
    ),
    OpDescription(
      id: 'web.read',
      method: 'POST',
      pattern: kWebSearchCtlRead,
      summary:
          'Read the text of a web.search result page (plain text, '
          '$kWebReadChunkChars characters per call; pass nextOffset as offset '
          'for more). Only result ids from web.search, not addresses.',
      risk: OpRisk.irreversible,
      availability: availability,
      consentGranted: granted,
      params: const <OpParam>[
        OpParam.string(
          'id',
          description: 'Result id from web.search (expires after 30 minutes).',
          required: true,
        ),
        OpParam.integer(
          'offset',
          description: 'Character offset (nextOffset of the previous call).',
        ),
        consent,
      ],
    ),
  ];
}
