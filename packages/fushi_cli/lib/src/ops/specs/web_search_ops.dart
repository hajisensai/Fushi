/// AI 助手通用联网搜索的操作声明（所有者 2026-11-20「ai 可以自主搜索」「第一次要确认吧」）。
/// 实现在 app `fushi/lib/src/ops/ctl_web_search_routes.dart`，CLI 命令在
/// `commands/web_commands.dart`（`web search` / `web read`），都引用这里的同一个对象。
///
/// 两条都是 irreversible：搜索词 / 要读的网页地址发给已指派 LLM 以外的第三方（用户
/// 配的搜索后端、结果所在网站），撤销收不回（spec §5.2）。用户在确认卡上点过一次同意后
/// 记进本机偏好，实现侧的 `consentGranted` 为真，AI 助手不再逐次出卡（spec §5.2
/// 「首次确认」）。`web.read` 只收 `web.search` 给的结果 id、不收地址：目的地址由搜索
/// 后端决定，模型选不了主机，所以没有地址类参数。
library;

import '../fushi_op.dart';
import '../op_spec.dart';

abstract final class WebSearchOps {
  /// 一次搜索默认 / 最多回几条。
  static const int defaultLimit = 5;
  static const int maxLimit = 10;

  /// `web.read` 一段回多少字。
  static const int readChunkChars = 4000;

  static const OpParam consent = OpParam.userGate(
    'confirm',
    description:
        'User agreed (once, remembered on this device) that search words and '
        'the addresses of pages to read are sent to the configured search '
        'backend.',
  );

  static const OpParam searchQuery = OpParam.string(
    'query',
    description: 'Search words.',
    required: true,
  );

  static const OpParam searchLimit = OpParam.integer(
    'limit',
    description:
        'Max results (default $defaultLimit, '
        'at most $maxLimit).',
  );

  static const OpSpec search = OpSpec(
    id: 'web.search',
    method: 'POST',
    pattern: '/api/admin/web/search',
    summary:
        'Search the public web with the search backend the user configured '
        '(SearXNG / Brave). Returns result ids with title, snippet and site; '
        'read a result with web.read. The query is sent to that backend.',
    risk: OpRisk.irreversible,
    params: <OpParam>[searchQuery, searchLimit, consent],
  );

  static const OpParam readId = OpParam.string(
    'id',
    description: 'Result id from web.search (expires after 30 minutes).',
    required: true,
  );

  static const OpParam readOffset = OpParam.integer(
    'offset',
    description: 'Character offset (nextOffset of the previous call).',
  );

  static const OpSpec read = OpSpec(
    id: 'web.read',
    method: 'POST',
    pattern: '/api/admin/web/read',
    summary:
        'Read the text of a web.search result page (plain text, '
        '$readChunkChars characters per call; pass nextOffset as offset '
        'for more). Only result ids from web.search, not addresses.',
    risk: OpRisk.irreversible,
    params: <OpParam>[readId, readOffset, consent],
  );
}
