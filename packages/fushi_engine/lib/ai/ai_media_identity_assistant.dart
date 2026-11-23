/// 书 / 漫画 / 游戏刮削的身份消解（库管家 ③ 步，spec
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §6）：资料源给出多个候选时，让
/// AI 在**已取回的候选**里选唯一命中。
///
/// 提示词、回复解析、请求生命周期与视频共用 `ai_identity_core.dart`（场景
/// [AiIdentityScenario.book] / [AiIdentityScenario.game]），本文件只管书 / 游戏的本地
/// 线索与候选怎么序列化；判定类型与自动采用门槛同一套。
/// 不新增 `AiFeature`（spec §9）：用视频刮削身份消解那一项指派
/// （[AiFeature.videoIdentify]）——同一件事「在刮削候选里认作品」，设置里不多一行。
///
/// 隐私（spec §9）：发出去的只有标题、作者 / 品牌、年份、卷数与候选本身。
library;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_identity_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

export 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart'
    show AiVideoIdentityDecision, kAiVideoIdentityAutoAcceptConfidence;

/// 本地条目是什么。
enum AiMediaIdentityKind {
  /// 一本书 / 一套系列（小说、漫画、画集……）。
  book,

  /// 一款游戏（视觉小说为主）。
  game,
}

/// 一个候选。
class AiMediaIdentityCandidate {
  const AiMediaIdentityCandidate({
    required this.key,
    required this.titles,
    this.creator,
    this.year,
    this.series,
    this.volume,
  });

  /// 回答时原样抄回的键。
  final String key;
  final List<String> titles;

  /// 作者 / 品牌。
  final String? creator;
  final int? year;
  final String? series;
  final String? volume;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'titles': titles,
    if (creator != null) 'creator': creator,
    if (year != null) 'year': year,
    if (series != null) 'series': series,
    if (volume != null) 'volume': volume,
  };
}

/// 一次提问。
class AiMediaIdentityQuery {
  const AiMediaIdentityQuery({
    required this.kind,
    required this.localTitles,
    required this.candidates,
    this.creator,
    this.volumeCount,
    this.locale = 'en',
  });

  final AiMediaIdentityKind kind;

  /// 本地标题（系列名 / 书名 / 游戏显示名；可能就是文件名）。
  final List<String> localTitles;

  /// 本地已知的作者 / 品牌。
  final String? creator;

  /// 系列在本地有几卷（单本为 null）。
  final int? volumeCount;
  final List<AiMediaIdentityCandidate> candidates;
  final String locale;

  Set<String> get candidateKeys => <String>{
    for (final AiMediaIdentityCandidate c in candidates) c.key,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'localTitles': localTitles,
    if (creator != null) 'creator': creator,
    if (volumeCount != null) 'localVolumeCount': volumeCount,
    'candidates': <Object?>[
      for (final AiMediaIdentityCandidate c in candidates) c.toJson(),
    ],
  };
}

/// 单次判定函数；null = 本次不问。
typedef AiMediaIdentityDecider =
    Future<AiVideoIdentityDecision?> Function(AiMediaIdentityQuery query);

/// 系统提示场景（共用核心的场景段）。
AiIdentityScenario aiIdentityScenarioOf(AiMediaIdentityKind kind) =>
    switch (kind) {
      AiMediaIdentityKind.book => AiIdentityScenario.book,
      AiMediaIdentityKind.game => AiIdentityScenario.game,
    };

/// 跑一次身份消解。失败原样抛 [AiChatFailure]。
Future<AiVideoIdentityDecision> requestAiMediaIdentity({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiMediaIdentityQuery query,
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) => requestAiIdentityDecision(
  client: client,
  provider: provider,
  scenario: aiIdentityScenarioOf(query.kind),
  locale: query.locale,
  payload: query.toJson(),
  allowedKeys: query.candidateKeys,
  references: references,
);

/// 生产装配：每次被问时现取 [AiFeature.videoIdentify] 的指派；未指派时 [isAssigned]
/// 为 false，编排器据此完全不问（不发请求）。联网资料与视频同一套
/// （[runAiIdentityRequest]）。
class PreferencesAiMediaIdentityAdvisor {
  PreferencesAiMediaIdentityAdvisor(
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

  bool get isAssigned => _provider() != null;

  Future<AiVideoIdentityDecision?> decide(AiMediaIdentityQuery query) async {
    final AiProviderConfig? provider = _provider();
    if (provider == null) return null;
    return runAiIdentityRequest<AiVideoIdentityDecision>(
      provider: provider,
      referenceTitle: query.localTitles.firstOrNull,
      logTag: 'LibraryCurator.mediaIdentity',
      logSubject: '${query.kind.name} ${query.localTitles.join(' / ')}',
      clientFactory: _clientFactory ?? AiChatClient.new,
      webFactory: () =>
          _webFactory?.call() ??
          WebKnowledgeClient(sites: _prefs.aiWebKnowledgeSites),
      request:
          (
            AiChatClient client,
            AiProviderConfig provider,
            List<WebKnowledgePage> references,
          ) => requestAiMediaIdentity(
            client: client,
            provider: provider,
            query: query,
            references: references,
          ),
    );
  }
}
