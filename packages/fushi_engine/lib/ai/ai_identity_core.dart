/// 「在已取回的候选里认出本地条目是哪部作品」的 AI 判定核心——视频（本地目录 /
/// 用户口头点名）、书 / 漫画、游戏共用这一份。
///
/// 以前三处各抄一份提示词与请求生命周期（`ai_video_identity_assistant.dart`、
/// `ai_video_acquisition_assistant.dart` 的多义作品选择、`ai_media_identity_assistant.dart`），
/// 规则修一处另两处不跟：2026-11 给视频补的「BD 分卷 / 部分集数不算矛盾」「候选缺字段
/// 是未知不是不符」书和游戏那份就没有（漫画「第2巻」「上 / 下」同样被当成对不上）。
/// 现在：
///
/// * 系统提示 = 共用规则 + 场景段（[AiIdentityScenario]），共用规则只写一次；
/// * 回复解析 / 判定类型 / 自动采用门槛只有一份（[parseAiIdentityDecision]、
///   [AiVideoIdentityDecision]、[kAiVideoIdentityAutoAcceptConfidence]）；
/// * 请求生命周期（建客户端、抓联网资料、诊断日志、关连接）只有一份
///   （[runAiIdentityRequest]），书 / 游戏因此也带上联网资料。
///
/// 各媒体的 assistant 只负责把本地线索与候选序列化成 JSON（字段不同）。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

/// 认的是什么、本地线索从哪来。决定系统提示的场景段。
enum AiIdentityScenario {
  /// 本地视频目录 / 文件（刮削）。
  videoFolder,

  /// 用户口头点名要下载的视频作品（AI 下视频的多义作品选择）。
  videoRequest,

  /// 本地书 / 书系列（小说、轻小说、漫画、画集）。
  book,

  /// 本地游戏（视觉小说为主）。
  game,
}

/// 参考资料最多几页、每页多少字：识别只要一小段背景，别把上下文撑爆。
const int kAiIdentityReferenceMaxPages = 3;
const int kAiIdentityReferenceMaxChars = 3000;

/// 带联网资料时追加的规则（所有场景共用）。
const String kAiIdentityReferenceRule = '''
- The user message may contain a "reference" array of encyclopedia excerpts
  fetched by the app. Use it only as background knowledge (titles in other
  languages, release years, which entries are sequels, movies or remakes). It
  never adds candidates: the answer must still be one of the candidate keys or
  null.
''';

String _intro(AiIdentityScenario scenario) => switch (scenario) {
  AiIdentityScenario.videoFolder =>
    'You match a local video folder to exactly one of the candidate works '
        'returned by\na metadata provider.',
  AiIdentityScenario.videoRequest =>
    'The user named a video work they want to download, and a metadata '
        'provider\nreturned several candidate works. You choose exactly one '
        'candidate that the\nuser meant, or null.',
  AiIdentityScenario.book =>
    'You match a local book or book series (novel, light novel, manga) to '
        'exactly one\nof the candidate entries returned by a metadata database.',
  AiIdentityScenario.game =>
    'You match a local game (mostly visual novels) to exactly one of the '
        'candidate\nentries returned by a metadata database.',
};

/// 场景段：只写这个场景特有的规则。
String _scenarioRules(AiIdentityScenario scenario) => switch (scenario) {
  AiIdentityScenario.videoFolder =>
    '''
- Return null for "key" when the local season number does not match the
  candidate, or the local episode count clearly exceeds the candidate's.
- Do not pick a sequel, prequel, movie, OVA or spin-off when the local folder
  looks like a different entry of the same franchise.
''',
  AiIdentityScenario.videoRequest =>
    '''
- "localTitles" holds what the user said (title as typed, plus spellings the
  app derived from it); "season", "year" and "sampleFileNames" are what the
  user mentioned, when anything.
- Return null for "key" when the user did not mention a season and the
  candidates are different seasons of the same work.
- Do not pick a movie, OVA, special or spin-off unless the user said so; when
  the user just names the franchise, prefer the main TV series.
''',
  AiIdentityScenario.book =>
    '''
- When the local entry is a series ("localVolumeCount" given), prefer the
  candidate describing the series or its first volume; never pick a different
  series, a spin-off, an anthology or a guide book.
- A known local creator (author) that contradicts the candidate's creator
  means it is not that candidate.
''',
  AiIdentityScenario.game =>
    '''
- Do not pick a fan disc, sequel, append or console port when the local title
  names the original release.
- A known local creator (brand) that contradicts the candidate's creator means
  it is not that candidate.
''',
};

/// 本地条目是「一部作品的一部分」的说法：分卷 / 分盘 / 部分集数。请求场景（用户
/// 口头点名）没有本地文件，不带这条。
String _partRule(AiIdentityScenario scenario) => switch (scenario) {
  AiIdentityScenario.videoRequest => '',
  AiIdentityScenario.videoFolder =>
    '''
- A local folder is often one physical volume or disc of a release ("vol.6",
  "上巻" / "下巻", "Disc 2", "BOX", "[BDMV]"): it may hold only some of the
  episodes, bonus material, or disc playlists named by number ("00001.mpls").
  It belongs to the work it is a volume of. A volume number in the title, or
  fewer local files than the candidate's episode count, is not a
  contradiction.
''',
  AiIdentityScenario.book =>
    '''
- A local book is often one volume or part of a work ("2", "第2巻", "Vol.2",
  "上" / "下", "前編"), a special edition or a store-bonus short story of it.
  It belongs to the work it is a volume of: a volume number in the title, or
  fewer local volumes than the candidate has, is not a contradiction.
''',
  AiIdentityScenario.game =>
    '''
- A local game may be one edition, disc or volume of a release ("Disc 2",
  "上巻", "初回限定版", "DL版"); it belongs to that release.
''',
};

/// 统一的系统提示：共用规则 + 场景段。
String buildAiIdentitySystemPrompt(
  AiIdentityScenario scenario, {
  required String locale,
}) =>
    '''
${_intro(scenario)} The candidates were already fetched; you only choose
among them and must not invent other works or identifiers.

Answer with a single JSON object and nothing else:
{"key": "<candidate key or null>", "confidence": <number 0.0-1.0>, "reason": "..."}

Rules:
- "key" must be copied verbatim from one candidate's "key", or be null.
- Return null for "key" whenever several candidates fit equally well, no
  candidate plausibly matches, or the local titles are only a file name,
  episode labels or release-group noise with no identifiable work name.
- Local titles may come from file names: ignore extensions, release tags in
  brackets, checksums like "[3574f94a]", resolution / codec labels and
  separators.
${_scenarioRules(scenario)}${_partRule(scenario)}- A field missing from a candidate (type, year, episode or volume count,
  creator) means the source did not say; treat it as unknown, never as a
  mismatch.
- "confidence" is your honest probability that the chosen candidate is the
  right work. Use 0.9 or higher only when the titles clearly name the same
  work and none of the known type, year, season, volume or creator clues
  contradicts it; otherwise stay below 0.85.
- Compare titles across languages and romanizations (Japanese, Chinese,
  Korean, English, romaji), ignoring case, punctuation and width.
- "reason" is one short sentence written in the language with tag "$locale".
$kAiIdentityReferenceRule''';

/// 用户侧提示：本地线索与候选的 JSON（各媒体自己序列化），有联网资料时挂在
/// `reference` 下。
String buildAiIdentityUserPrompt(
  Map<String, Object?> payload, {
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) => jsonEncode(<String, Object?>{
  ...payload,
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
AiVideoIdentityDecision parseAiIdentityDecision(
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

/// 跑一次身份判定。失败原样抛 [AiChatFailure]（文案已脱敏）。
Future<AiVideoIdentityDecision> requestAiIdentityDecision({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiIdentityScenario scenario,
  required String locale,
  required Map<String, Object?> payload,
  required Set<String> allowedKeys,
  List<WebKnowledgePage> references = const <WebKnowledgePage>[],
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiIdentitySystemPrompt(scenario, locale: locale),
      ),
      AiChatMessage.user(
        buildAiIdentityUserPrompt(payload, references: references),
      ),
    ],
    // 回复只有一个小 JSON 对象；给 512 是留给推理型模型偶尔多话。
    maxTokens: 512,
  );
  return parseAiIdentityDecision(reply, allowedKeys: allowedKeys);
}

/// 为这次识别抓联网资料：按 [searchTitle] 搜，按来源类型轮流挑页。失败 / 没开
/// 来源 / 没标题 → 空（识别照常，只是没有背景）。
Future<List<WebKnowledgePage>> fetchAiIdentityReferences(
  WebKnowledgeClient? web,
  String? searchTitle,
) async {
  final String? title = searchTitle?.trim();
  if (web == null || !web.isEnabled || title == null || title.isEmpty) {
    return const <WebKnowledgePage>[];
  }
  final List<WebKnowledgePage> pages = await web.search(
    title,
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

/// 一次身份请求的生命周期：建客户端 → 抓联网资料（[referenceTitle]）→ 发请求 →
/// 失败记诊断日志并原样抛 → 关连接。三个场景的生产装配都走这里。
///
/// [clientFactory] / [webFactory] 为 null 时生产新建、用完即关，不留连接；
/// [webFactory] 返回 null 表示这条路不抓联网资料。
Future<T> runAiIdentityRequest<T>({
  required AiProviderConfig provider,
  required String? referenceTitle,
  required String logTag,
  required String logSubject,
  required AiChatClient Function() clientFactory,
  required WebKnowledgeClient? Function() webFactory,
  required Future<T> Function(
    AiChatClient client,
    AiProviderConfig provider,
    List<WebKnowledgePage> references,
  )
  request,
}) async {
  final AiChatClient client = clientFactory();
  final WebKnowledgeClient? web = webFactory();
  try {
    return await request(
      client,
      provider,
      await fetchAiIdentityReferences(web, referenceTitle),
    );
  } catch (error, stack) {
    engineLog.logDiagnostic(logTag, '$logSubject: $error\n$stack');
    rethrow;
  } finally {
    client.close();
    web?.close();
  }
}
