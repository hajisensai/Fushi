/// 视频刮削身份消解：在线源给出多个候选时，让 AI 在**已取回的候选**里选唯一命中。
///
/// 契约类型（提问 / 候选 / 判定 / 决策器 typedef / 运行记录标记）住在引擎包
/// `video_scrape_ai_identity.dart`——协调器在那边，不能反向依赖 app 与 LLM 客户端；
/// 本文件只负责视频本地目录这一场景的序列化、「查无 → 给搜索词」与生产装配；
/// 提示词、回复解析与请求生命周期在三媒体共用的 `ai_identity_core.dart`。为省调用方
/// 两行 import，这里把契约类型与共用核心原样 re-export。
library;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_identity_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

export 'package:fushi_engine/ai/ai_identity_core.dart';
export 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

/// 用户侧提示：把本地线索和候选一起序列化成 JSON，模型不用猜字段含义；有联网
/// 资料时挂在 `reference` 下（[buildAiIdentityUserPrompt]）。
String buildAiVideoIdentityUserPrompt(
  AiVideoIdentityQuery query, {
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) => buildAiIdentityUserPrompt(query.toJson(), references: references);

/// 跑一次本地视频目录的身份判定（[AiIdentityScenario.videoFolder]）。失败原样抛
/// [AiChatFailure]（文案已脱敏），由调用方决定吞不吞。
Future<AiVideoIdentityDecision> requestAiVideoIdentity({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiVideoIdentityQuery query,
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) => requestAiIdentityDecision(
  client: client,
  provider: provider,
  scenario: AiIdentityScenario.videoFolder,
  locale: query.locale,
  payload: query.toJson(),
  allowedKeys: query.candidateKeys,
  references: references,
);

/// 「资料源查无时给搜索词」的系统提示：只产出标题，不判定身份。
String buildAiVideoSearchTitlesSystemPrompt() =>
    '''
A metadata provider found no work for a local video folder. Suggest the official
titles under which this work is most likely listed on anime / TV / movie
databases (AniDB, MyAnimeList, TMDB), so the app can search again.

Answer with a single JSON object and nothing else:
{"titles": ["...", "..."]}

Rules:
- At most $kAiVideoIdentitySearchTitleLimit titles, most likely first.
- Prefer the original title (e.g. Japanese), then romaji, then the English
  title. Strip release-group tags, resolution, codec and episode labels.
- Only suggest titles you are confident refer to the work in the folder; return
  an empty list when the local clues do not identify a work.
$kAiIdentityReferenceRule''';

/// 解析搜索词回复：去空去重、截到 [kAiVideoIdentitySearchTitleLimit] 条；抠不出
/// JSON 或字段类型不对一律当空表。
List<String> parseAiVideoSearchTitles(String reply) {
  final Object? raw = decodeAiJsonObject(reply)?['titles'];
  if (raw is! List<Object?>) return const <String>[];
  final Set<String> seen = <String>{};
  return List<String>.unmodifiable(
    <String>[
      for (final Object? title in raw)
        if (title is String &&
            title.trim().isNotEmpty &&
            seen.add(title.trim()))
          title.trim(),
    ].take(kAiVideoIdentitySearchTitleLimit),
  );
}

/// 跑一次「查无 → 给搜索词」。失败原样抛 [AiChatFailure]。
Future<List<String>> requestAiVideoSearchTitles({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiVideoIdentityQuery query,
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiVideoSearchTitlesSystemPrompt()),
      AiChatMessage.user(
        buildAiVideoIdentityUserPrompt(query, references: references),
      ),
    ],
    maxTokens: 512,
  );
  return parseAiVideoSearchTitles(reply);
}

/// [provider] 的能力键：判定 / 搜索词结论只在同一套提供商、协议、地址、模型、
/// 推理档位下可复用。不含 API key——鉴权失败不缓存，改 key 后自然会重问。
String aiVideoIdentityCapabilityKey(AiProviderConfig provider) => <String>[
  provider.id,
  provider.protocol.storageKey,
  provider.baseUrl.toString(),
  provider.model.trim(),
  provider.reasoningEffort.storageKey,
].join('|');

/// 生产装配：每次被问时**现取**偏好里的指派，未指派 / 不可用时
/// [capabilityKey] 为 null，协调器据此完全不问 AI（不发请求）。
///
/// 现取而不是构造期解析，是因为协调器与补刮器在 home_page / 下载管线里生命周期
/// 很长；用户在设置页改了指派要立即生效，不能等它们重建。[clientFactory] /
/// [webFactory] 只给测试注入；生产每次新建、用完即关，不留连接。
///
/// 失败先记诊断日志再原样抛出：协调器（引擎包，无日志服务）据此记一条
/// `ai:failed` 运行警告，并把这部作品当作临时失败（补刮下轮再试）。
///
/// 联网资料（设置 › AI › 联网资料）开着时先抓一小段背景一起给模型；抓失败不影响
/// 识别本身。
class PreferencesAiVideoIdentityAdvisor implements AiVideoIdentityAdvisor {
  PreferencesAiVideoIdentityAdvisor(
    this._prefs, {
    AiChatClient Function()? clientFactory,
    WebKnowledgeClient Function()? webFactory,
  }) : _clientFactory = clientFactory,
       _webFactory = webFactory;

  final AiSettingsSource _prefs;
  final AiChatClient Function()? _clientFactory;
  final WebKnowledgeClient Function()? _webFactory;

  AiProviderConfig? _provider() => _prefs.aiFeatureAssignments.resolve(
    AiFeature.videoIdentify,
    _prefs.aiProviders,
  );

  @override
  String? get capabilityKey {
    final AiProviderConfig? provider = _provider();
    return provider == null ? null : aiVideoIdentityCapabilityKey(provider);
  }

  @override
  Future<AiVideoIdentityDecision> decide(AiVideoIdentityQuery query) => _ask(
    query,
    (
      AiChatClient client,
      AiProviderConfig provider,
      List<WebKnowledgePage> references,
    ) => requestAiVideoIdentity(
      client: client,
      provider: provider,
      query: query,
      references: references,
    ),
  );

  @override
  Future<List<String>> suggestSearchTitles(AiVideoIdentityQuery query) => _ask(
    query,
    (
      AiChatClient client,
      AiProviderConfig provider,
      List<WebKnowledgePage> references,
    ) => requestAiVideoSearchTitles(
      client: client,
      provider: provider,
      query: query,
      references: references,
    ),
  );

  Future<T> _ask<T>(
    AiVideoIdentityQuery query,
    Future<T> Function(
      AiChatClient client,
      AiProviderConfig provider,
      List<WebKnowledgePage> references,
    )
    request,
  ) async {
    final AiProviderConfig? provider = _provider();
    if (provider == null) {
      // 协调器先看 capabilityKey 才会来问；走到这里是两次读之间用户刚撤了指派。
      throw StateError('视频作品识别未指派可用的 AI 提供商');
    }
    return runAiIdentityRequest<T>(
      provider: provider,
      referenceTitle: query.localTitles.firstOrNull,
      logTag: 'VideoSourceScrapeCoordinator.aiIdentity',
      logSubject: query.localTitles.join(' / '),
      clientFactory: _clientFactory ?? AiChatClient.new,
      webFactory: () =>
          _webFactory?.call() ??
          WebKnowledgeClient(sites: _prefs.aiWebKnowledgeSites),
      request: request,
    );
  }
}
