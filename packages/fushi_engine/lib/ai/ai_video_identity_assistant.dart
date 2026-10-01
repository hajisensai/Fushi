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

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

export 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

/// 系统提示：任务是「本地目录对应哪个候选作品」，只回一个 JSON 对象。
String buildAiVideoIdentitySystemPrompt({required String locale}) =>
    '''
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
$kAiIdentityReferenceRule''';

/// 带联网资料时追加的规则（刮削与 AI 下视频两套系统提示共用）。
const String kAiIdentityReferenceRule = '''
- The user message may contain a "reference" array of encyclopedia excerpts
  fetched by the app. Use it only as background knowledge (titles in other
  languages, release years, which entries are sequels, movies or remakes). It
  never adds candidates: the answer must still be one of the candidate keys or
  null.
''';

/// 参考资料最多几页、每页多少字：识别只要一小段背景，别把上下文撑爆。
const int kAiIdentityReferenceMaxPages = 3;
const int kAiIdentityReferenceMaxChars = 3000;

/// 为这次识别抓联网资料：按第一个本地标题搜，每个来源取一页。失败 / 没开来源 →
/// 空（识别照常，只是没有背景）。
Future<List<WebKnowledgePage>> fetchAiIdentityReferences(
  WebKnowledgeClient? web,
  AiVideoIdentityQuery query,
) async {
  if (web == null || !web.isEnabled || query.localTitles.isEmpty) {
    return const <WebKnowledgePage>[];
  }
  final List<WebKnowledgePage> pages = await web.search(
    query.localTitles.first,
    maxCharsPerPage: kAiIdentityReferenceMaxChars,
  );
  return pickDiverseWebKnowledgePages(pages, kAiIdentityReferenceMaxPages);
}

/// 按来源类型轮流挑页：先每种类型（百科 / ANN / TVmaze）各取第一页，再按原顺序
/// 补满 [limit]。只按顺序取前几页的话，三个维基永远占满名额，ANN / TVmaze 这类
/// 对动画 / 剧集身份最有用的清单页白抓。
List<WebKnowledgePage> pickDiverseWebKnowledgePages(
  List<WebKnowledgePage> pages,
  int limit,
) {
  final List<WebKnowledgePage> picked = <WebKnowledgePage>[];
  final Set<WebKnowledgeSiteKind> seenKinds = <WebKnowledgeSiteKind>{};
  for (final WebKnowledgePage page in pages) {
    if (picked.length >= limit) break;
    if (seenKinds.add(page.site.kind)) picked.add(page);
  }
  for (final WebKnowledgePage page in pages) {
    if (picked.length >= limit) break;
    if (!picked.contains(page)) picked.add(page);
  }
  return List<WebKnowledgePage>.unmodifiable(picked);
}

/// 用户侧提示：把本地线索和候选一起序列化成 JSON，模型不用猜字段含义；有联网
/// 资料时挂在 `reference` 下。
String buildAiVideoIdentityUserPrompt(
  AiVideoIdentityQuery query, {
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) => const JsonEncoder.withIndent('  ').convert(<String, Object?>{
  ...query.toJson(),
  if (references.isNotEmpty)
    'reference': <Map<String, Object?>>[
      for (final WebKnowledgePage page in references)
        <String, Object?>{
          'source': page.url.toString(),
          'title': page.title,
          'text': page.text,
        },
    ],
});

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
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiVideoIdentitySystemPrompt(locale: query.locale),
      ),
      AiChatMessage.user(
        buildAiVideoIdentityUserPrompt(query, references: references),
      ),
    ],
    // 回复只有一个小 JSON 对象；给 512 是留给推理型模型偶尔多话。
    maxTokens: 512,
  );
  return parseAiVideoIdentityDecision(reply, allowedKeys: query.candidateKeys);
}

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
    final AiChatClient client = _clientFactory?.call() ?? AiChatClient();
    final WebKnowledgeClient web =
        _webFactory?.call() ??
        WebKnowledgeClient(sites: _prefs.aiWebKnowledgeSites);
    try {
      return await request(
        client,
        provider,
        await fetchAiIdentityReferences(web, query),
      );
    } catch (error, stack) {
      engineLog.logDiagnostic(
        'VideoSourceScrapeCoordinator.aiIdentity',
        '${query.localTitles.join(' / ')}: $error\n$stack',
      );
      rethrow;
    } finally {
      client.close();
      web.close();
    }
  }
}
