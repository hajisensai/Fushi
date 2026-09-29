/// 「AI 下载」（浏览 › 发现里的小说 / 漫画 / 游戏域）的 AI 侧：把用户一句话解析
/// 成搜索词，以及在**已取回**的候选里挑推荐项。视频域有自己的对话式编排
/// （`ai_video_acquisition_assistant.dart`），本文件只管另外三个域。
///
/// 边界（与 `ai_feature.dart` 的硬边界同源）：
///
/// - **AI 只解析 / 只在候选里选。** 搜哪些源、怎么下载全是本地确定性代码；模型
///   看不到网络，也不发起检索。
/// - **AI 输出里没有自由文本字段进 UI。** 解析结果只有搜索词（拿去搜，不展示成
///   助手的话）与枚举；挑选结果只有候选 id。
/// - **产物必须本地校验。** 搜索词去空 / 去重 / 截长 / 限个数；候选 id 必须在
///   本次候选集合里，越界的丢掉；坏 JSON = 什么都没解析出来（调用方退回原文搜索）。
/// - **未指派提供商 = 不发请求。** 生产装配未指派时回 null。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi/src/ai/ai_video_search_assistant.dart'
    show AiClientFactory;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 「AI 下载」覆盖的三个域（视频走自己的对话页）。
enum AiMediaAcquisitionDomain { novel, manga, game }

/// 一次解析最多用几个搜索词（原名 + 译名 / 别名）。每个词都要向全部来源各打
/// 一轮，给多了就是成倍的请求。
const int kAiMediaAcquisitionMaxQueries = 3;

/// 单个搜索词的最大长度（一句话被整句塞进来时截断，而不是拿一整句去搜）。
const int kAiMediaAcquisitionMaxQueryLength = 80;

/// AI 最多推荐几个候选。
const int kAiMediaAcquisitionMaxPicks = 3;

/// 喂给挑选步骤的候选上限（按本地排序截前 N 个，控制提示词长度）。
const int kAiMediaAcquisitionPickPool = 40;

/// 从偏好里解析「AI 下载」的提供商；null = 未指派 / 已删 / 没配全。
AiProviderConfig? resolveMediaAcquireAiProvider(PreferencesRepository prefs) =>
    prefs.aiFeatureAssignments.resolve(AiFeature.acquire, prefs.aiProviders);

/// 一句话的解析结果：拿去搜的词（原文优先）。
class AiMediaAcquisitionIntent {
  const AiMediaAcquisitionIntent({required this.queries});

  static const AiMediaAcquisitionIntent empty = AiMediaAcquisitionIntent(
    queries: <String>[],
  );

  final List<String> queries;

  bool get isEmpty => queries.isEmpty;
}

/// 发给挑选步骤的一条候选（只含事实，不含可执行信息）。
class AiMediaAcquisitionCandidateFact {
  const AiMediaAcquisitionCandidateFact({
    required this.id,
    required this.title,
    required this.source,
    this.details = const <String>[],
  });

  final String id;
  final String title;
  final String source;

  /// 大小 / 做种数 / 日期 / 汉化状态等外显事实。
  final List<String> details;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'source': source,
    if (details.isNotEmpty) 'details': details,
  };
}

String _domainNoun(AiMediaAcquisitionDomain domain) => switch (domain) {
  AiMediaAcquisitionDomain.novel => 'a novel / light novel / audiobook',
  AiMediaAcquisitionDomain.manga => 'a manga / comic',
  AiMediaAcquisitionDomain.game => 'a game (usually a Japanese visual novel)',
};

String buildAiMediaAcquisitionIntentSystemPrompt(
  AiMediaAcquisitionDomain domain,
) =>
    '''
The user wants to download ${_domainNoun(domain)}. Turn their message into search queries for online catalogs and torrent indexes.

Rules:
- Reply with ONE JSON object and nothing else: {"queries": ["...", "..."]}
- At most $kAiMediaAcquisitionMaxQueries queries, most likely to match first.
- The first query is the work's title in its original language when you know it (Japanese for Japanese works), otherwise the title exactly as the user wrote it.
- Further queries are well-known alternative titles (romaji, English, Chinese). Do not invent titles you are not sure about.
- Queries contain only the title: no words like "download", "volume", "torrent", "please".
- If the message names no work at all, reply {"queries": []}.''';

/// 解析「一句话 → 搜索词」的回复。坏 JSON / 缺字段 → [AiMediaAcquisitionIntent.empty]。
AiMediaAcquisitionIntent parseAiMediaAcquisitionIntent(String reply) {
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? raw = json?['queries'];
  if (raw is! List) return AiMediaAcquisitionIntent.empty;
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final Object? value in raw) {
    if (value is! String) continue;
    String query = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (query.isEmpty) continue;
    if (query.length > kAiMediaAcquisitionMaxQueryLength) {
      query = query.substring(0, kAiMediaAcquisitionMaxQueryLength).trim();
    }
    if (!seen.add(query.toLowerCase())) continue;
    out.add(query);
    if (out.length >= kAiMediaAcquisitionMaxQueries) break;
  }
  return AiMediaAcquisitionIntent(queries: List<String>.unmodifiable(out));
}

String buildAiMediaAcquisitionPickSystemPrompt(
  AiMediaAcquisitionDomain domain,
) =>
    '''
The user wants to download ${_domainNoun(domain)}. You get their request and a list of search results that were already fetched. Pick the results that best match what they asked for.

Rules:
- Reply with ONE JSON object and nothing else: {"picks": ["id", ...]}
- At most $kAiMediaAcquisitionMaxPicks ids, best first. Only use ids from the list.
- Prefer the exact work the user named over sequels, spin-offs, or different works with similar names, unless the user asked for those.
- Prefer complete sets / whole works over single parts when the user did not ask for a specific part; prefer results with more seeders when otherwise equal.
- Respect any language or version the user asked for (e.g. Chinese translation, original Japanese).
- If nothing matches, reply {"picks": []}.''';

String buildAiMediaAcquisitionPickUserPrompt({
  required String request,
  required List<AiMediaAcquisitionCandidateFact> candidates,
}) => jsonEncode(<String, Object?>{
  'request': request,
  'results': <Map<String, Object?>>[
    for (final AiMediaAcquisitionCandidateFact c in candidates) c.toJson(),
  ],
});

/// 解析挑选回复：只保留出现在 [validIds] 里的 id，去重、按原序、最多
/// [kAiMediaAcquisitionMaxPicks] 个。
List<String> parseAiMediaAcquisitionPicks(
  String reply, {
  required Set<String> validIds,
}) {
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? raw = json?['picks'];
  if (raw is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? value in raw) {
    final String? id = switch (value) {
      final String s => s.trim(),
      final int n => '$n',
      _ => null,
    };
    if (id == null || !validIds.contains(id) || out.contains(id)) continue;
    out.add(id);
    if (out.length >= kAiMediaAcquisitionMaxPicks) break;
  }
  return List<String>.unmodifiable(out);
}

Future<AiMediaAcquisitionIntent> requestAiMediaAcquisitionIntent({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiMediaAcquisitionDomain domain,
  required String utterance,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiMediaAcquisitionIntentSystemPrompt(domain)),
      AiChatMessage.user(utterance),
    ],
    maxTokens: 512,
  );
  return parseAiMediaAcquisitionIntent(reply);
}

Future<List<String>> requestAiMediaAcquisitionPicks({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiMediaAcquisitionDomain domain,
  required String request,
  required List<AiMediaAcquisitionCandidateFact> candidates,
}) async {
  if (candidates.isEmpty) return const <String>[];
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiMediaAcquisitionPickSystemPrompt(domain)),
      AiChatMessage.user(
        buildAiMediaAcquisitionPickUserPrompt(
          request: request,
          candidates: candidates,
        ),
      ),
    ],
    maxTokens: 512,
  );
  return parseAiMediaAcquisitionPicks(
    reply,
    validIds: <String>{
      for (final AiMediaAcquisitionCandidateFact c in candidates) c.id,
    },
  );
}

// ---------------------------------------------------------------------------
// 生产装配
// ---------------------------------------------------------------------------

/// AI 端口：两步都返回 null = 提供商未指派（不发请求）。失败记诊断日志后原样抛出。
class AiMediaAcquisitionAi {
  const AiMediaAcquisitionAi({required this.parseIntent, required this.pick});

  final Future<AiMediaAcquisitionIntent?> Function(
    AiMediaAcquisitionDomain domain,
    String utterance,
  )
  parseIntent;

  final Future<List<String>?> Function(
    AiMediaAcquisitionDomain domain,
    String request,
    List<AiMediaAcquisitionCandidateFact> candidates,
  )
  pick;
}

/// 生产装配：每次调用现取偏好里的指派（设置页改了立即生效）。[clientFactory]
/// 只给测试注入假客户端；生产每次新建、用完即关。
AiMediaAcquisitionAi createPreferencesAiMediaAcquisitionAi(
  PreferencesRepository prefsRepo, {
  AiClientFactory? clientFactory,
}) {
  Future<T?> withClient<T>(
    String op,
    Future<T> Function(AiChatClient client, AiProviderConfig provider) run,
  ) async {
    final AiProviderConfig? provider = resolveMediaAcquireAiProvider(prefsRepo);
    if (provider == null) return null;
    final AiChatClient client = clientFactory?.call() ?? AiChatClient();
    try {
      return await run(client, provider);
    } catch (error, stack) {
      ErrorLogService.instance.logDiagnostic(
        'MediaAcquisition.$op',
        '$error\n$stack',
      );
      rethrow;
    } finally {
      client.close();
    }
  }

  return AiMediaAcquisitionAi(
    parseIntent: (AiMediaAcquisitionDomain domain, String utterance) =>
        withClient(
          'intent',
          (AiChatClient client, AiProviderConfig provider) =>
              requestAiMediaAcquisitionIntent(
                client: client,
                provider: provider,
                domain: domain,
                utterance: utterance,
              ),
        ),
    pick:
        (
          AiMediaAcquisitionDomain domain,
          String request,
          List<AiMediaAcquisitionCandidateFact> candidates,
        ) => withClient(
          'pick',
          (AiChatClient client, AiProviderConfig provider) =>
              requestAiMediaAcquisitionPicks(
                client: client,
                provider: provider,
                domain: domain,
                request: request,
                candidates: candidates,
              ),
        ),
  );
}
