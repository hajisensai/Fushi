/// 视频刮削身份消解：在线源给出多个候选时，让 AI 在**已取回的候选**里选唯一命中。
///
/// 契约类型（提问 / 候选 / 判定 / 决策器 typedef / 运行记录标记）住在引擎包
/// `video_scrape_ai_identity.dart`——协调器在那边，不能反向依赖 app 与 LLM 客户端；
/// 本文件只负责「怎么问模型」：提示词、回复解析、生产装配。为省调用方两行 import，
/// 这里把契约类型原样 re-export。
///
/// 模型回复经 [parseAiVideoIdentityDecision] 本地校验：key 必须在候选集合里，
/// 置信度必须是 0~1 的数字，否则一律降级成「不采用」。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

export 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

/// 系统提示：任务是「本地目录对应哪个候选作品」，只回一个 JSON 对象。
String buildAiVideoIdentitySystemPrompt({required String locale}) => '''
You match a local video folder to exactly one of the candidate works returned by
a metadata provider. The candidates were already fetched; you only choose among
them and must not invent other works or identifiers.

Answer with a single JSON object and nothing else:
{"key": "<candidate key or null>", "confidence": <number 0.0-1.0>, "reason": "..."}

Rules:
- "key" must be copied verbatim from one candidate's "key", or be null.
- Return null for "key" whenever any of these holds: several candidates fit the
  local titles equally well; the local season number does not match the
  candidate; the local episode count clearly contradicts the candidate's
  episode count; no candidate plausibly matches; the local titles are only
  episode labels or release-group noise with no identifiable work name.
- Do not pick a sequel, prequel, movie, OVA or spin-off when the local folder
  looks like a different entry of the same franchise.
- "confidence" is your honest probability that the chosen candidate is the
  right work. Use 0.9 or higher only when titles, type, year and season all
  agree; otherwise stay below 0.85.
- Compare titles across languages and romanizations (Japanese, Chinese,
  Korean, English, romaji), ignoring case, punctuation and release-group tags.
- "reason" is one short sentence written in the language with tag "$locale".
''';

/// 用户侧提示：把本地线索和候选一起序列化成 JSON，模型不用猜字段含义。
String buildAiVideoIdentityUserPrompt(AiVideoIdentityQuery query) =>
    const JsonEncoder.withIndent('  ').convert(query.toJson());

/// 解析模型回复。
///
/// key 不在 [allowedKeys] 里 → 视为 null；confidence 不是数字或不在 0~1 → 0。
/// 抠不出 JSON 也回一条 key=null、confidence=0 的判定，调用方不用区分。
AiVideoIdentityDecision parseAiVideoIdentityDecision(
  String reply, {
  required Set<String> allowedKeys,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) {
    return const AiVideoIdentityDecision(key: null, confidence: 0);
  }
  final Object? rawKey = decoded['key'];
  final String? key = rawKey is String && allowedKeys.contains(rawKey.trim())
      ? rawKey.trim()
      : null;
  final Object? rawConfidence = decoded['confidence'];
  double confidence = 0;
  if (rawConfidence is num &&
      rawConfidence.isFinite &&
      rawConfidence >= 0 &&
      rawConfidence <= 1) {
    confidence = rawConfidence.toDouble();
  }
  final Object? rawReason = decoded['reason'];
  return AiVideoIdentityDecision(
    key: key,
    confidence: key == null ? 0 : confidence,
    reason: rawReason is String ? rawReason.trim() : '',
  );
}

/// 跑一次身份消解。失败原样抛 [AiChatFailure]（文案已脱敏），由调用方决定吞不吞。
Future<AiVideoIdentityDecision> requestAiVideoIdentity({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiVideoIdentityQuery query,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiVideoIdentitySystemPrompt(locale: query.locale),
      ),
      AiChatMessage.user(buildAiVideoIdentityUserPrompt(query)),
    ],
    // 回复只有一个小 JSON 对象；给 512 是留给推理型模型偶尔多话。
    maxTokens: 512,
  );
  return parseAiVideoIdentityDecision(reply, allowedKeys: query.candidateKeys);
}

/// 生产装配：每次被问时**现取**偏好里的指派，未指派 / 不可用直接回 null（不发请求）。
///
/// 现取而不是构造期解析，是因为协调器实例在 home_page 里按配置指纹缓存、
/// 生命周期很长；用户在设置页改了指派要立即生效，不能等协调器重建。
/// [clientFactory] 只给测试注入假客户端；生产每次新建、用完即关，不留连接。
///
/// 失败先记诊断日志再原样抛出：协调器（引擎包，无日志服务）据此把本趟 run 余下
/// 的歧义作品跳过 AI，本条照旧进人工确认 / 待确认。
AiVideoIdentityDecider createPreferencesAiVideoIdentityDecider(
  PreferencesRepository prefsRepo, {
  AiChatClient Function()? clientFactory,
}) => (AiVideoIdentityQuery query) async {
  final AiProviderConfig? provider = prefsRepo.aiFeatureAssignments.resolve(
    AiFeature.videoIdentify,
    prefsRepo.aiProviders,
  );
  if (provider == null) {
    return null;
  }
  final AiChatClient client = clientFactory?.call() ?? AiChatClient();
  try {
    return await requestAiVideoIdentity(
      client: client,
      provider: provider,
      query: query,
    );
  } catch (error, stack) {
    ErrorLogService.instance.logDiagnostic(
      'VideoSourceScrapeCoordinator.aiIdentity',
      '${query.localTitles.join(' / ')}: $error\n$stack',
    );
    rethrow;
  } finally {
    client.close();
  }
};
