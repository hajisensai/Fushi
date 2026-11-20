/// 书 / 漫画 / 游戏刮削的身份消解（库管家 ③ 步，spec
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §6）：资料源给出多个候选时，让
/// AI 在**已取回的候选**里选唯一命中。
///
/// 形态照搬视频的 `ai_video_identity_assistant.dart`：提示词只让模型抄候选 key 或回
/// null，回复经 [parseAiVideoIdentityDecision] 本地校验（key 必须在候选集合里、置信度
/// 0~1），判定类型与自动采用门槛（[AiVideoIdentityDecision.isAutoAcceptable]）同一套。
/// 不新增 `AiFeature`（spec §9）：用视频刮削身份消解那一项指派
/// （[AiFeature.videoIdentify]）——同一件事「在刮削候选里认作品」，设置里不多一行。
///
/// 隐私（spec §9）：发出去的只有标题、作者 / 品牌、年份、卷数与候选本身。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/ai_video_identity_assistant.dart'
    show parseAiVideoIdentityDecision;
import 'package:fushi_engine/foundation/engine_log.dart';
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

/// 系统提示。
String buildAiMediaIdentitySystemPrompt(
  AiMediaIdentityKind kind, {
  required String locale,
}) {
  final String local = switch (kind) {
    AiMediaIdentityKind.book =>
      'a local book or book series (novel, light novel, manga)',
    AiMediaIdentityKind.game => 'a local game (mostly visual novels)',
  };
  return '''
You match $local to exactly one of the candidate entries returned by a metadata
database. The candidates were already fetched; you only choose among them and
must not invent other entries or identifiers.

Answer with a single JSON object and nothing else:
{"key": "<candidate key or null>", "confidence": <number 0.0-1.0>, "reason": "..."}

Rules:
- "key" must be copied verbatim from one candidate's "key", or be null.
- Return null for "key" whenever several candidates fit equally well, no
  candidate plausibly matches, or the local title is only a file name with no
  identifiable work name.
- The local title may be a file name: ignore extensions, release tags in
  brackets, volume / version labels and separators.
- When the local entry is a series ("localVolumeCount" given), prefer the
  candidate describing the series or its first volume; never pick a different
  series, a spin-off, an anthology or a guide book.
- For games, do not pick a fan disc, sequel, append or console port when the
  local title names the original release.
- A known local creator (author / brand) that contradicts the candidate's
  creator means it is not that candidate.
- "confidence" is your honest probability that the chosen candidate is right.
  Use 0.9 or higher only when titles and creator agree; otherwise stay below
  0.85.
- Compare titles across languages and romanizations, ignoring case and
  punctuation.
- "reason" is one short sentence written in the language with tag "$locale".
''';
}

/// 跑一次身份消解。失败原样抛 [AiChatFailure]。
Future<AiVideoIdentityDecision> requestAiMediaIdentity({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiMediaIdentityQuery query,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiMediaIdentitySystemPrompt(query.kind, locale: query.locale),
      ),
      AiChatMessage.user(
        const JsonEncoder.withIndent('  ').convert(query.toJson()),
      ),
    ],
    maxTokens: 512,
  );
  return parseAiVideoIdentityDecision(reply, allowedKeys: query.candidateKeys);
}

/// 生产装配：每次被问时现取 [AiFeature.videoIdentify] 的指派；未指派时 [isAssigned]
/// 为 false，编排器据此完全不问（不发请求）。
class PreferencesAiMediaIdentityAdvisor {
  PreferencesAiMediaIdentityAdvisor(
    this._prefs, {
    AiChatClient Function()? clientFactory,
  }) : _clientFactory = clientFactory;

  final AiSettingsSource _prefs;
  final AiChatClient Function()? _clientFactory;

  AiProviderConfig? _provider() => _prefs.aiFeatureAssignments.resolve(
    AiFeature.videoIdentify,
    _prefs.aiProviders,
  );

  bool get isAssigned => _provider() != null;

  Future<AiVideoIdentityDecision?> decide(AiMediaIdentityQuery query) async {
    final AiProviderConfig? provider = _provider();
    if (provider == null) return null;
    final AiChatClient client = _clientFactory?.call() ?? AiChatClient();
    try {
      return await requestAiMediaIdentity(
        client: client,
        provider: provider,
        query: query,
      );
    } catch (error, stack) {
      engineLog.logDiagnostic(
        'LibraryCurator.mediaIdentity',
        '${query.kind.name} ${query.localTitles.join(' / ')}: $error\n$stack',
      );
      rethrow;
    } finally {
      client.close();
    }
  }
}
