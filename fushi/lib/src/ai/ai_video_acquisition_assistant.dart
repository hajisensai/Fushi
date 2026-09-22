/// 「AI 下视频」的 AI 侧：把用户的一句话解析成结构化意图补丁，以及在**已取回**的
/// 作品候选里选唯一命中。
///
/// 边界（与 `ai_feature.dart` 的硬边界同源，设计见
/// `docs/specs/2026-09-15-ai-feature-expansion.md`）：
///
/// - **AI 只解析、不决策。** 缺什么、问什么、何时提交，全由
///   `video_acquisition_reducer.dart` 的纯函数按决策表决定；模型看不到候选资源，
///   也不发起任何网络检索。
/// - **AI 输出里没有自由文本字段。** [VideoAcquisitionIntent] 只有枚举 / 数字 /
///   查询词列表；助手对用户说的每一句都是 i18n 模板，模型散文永不进 UI。身份判定
///   的 `reason` 是唯一例外，且只作为「AI 判定」的旁注展示，不驱动任何分支。
/// - **产物必须本地校验。** [parseVideoAcquisitionIntent] 逐字段比白名单：枚举越界
///   只丢那一个字段，不整包作废；下标 / 季号 / 集号越界丢弃；坏 JSON → `unclear`。
/// - **未指派提供商 = 功能不存在。** 生产装配未指派时回 null 且不发请求；调用失败
///   记诊断日志后原样抛出，由编排器吞成「请点选」退化——chip 点击永不经 LLM，
///   流程照样能走完。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi/src/ai/ai_video_identity_assistant.dart';
import 'package:fushi/src/ai/ai_video_search_assistant.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';

/// 从偏好里解析「AI 下视频」的提供商；null = 未指派 / 已删 / 没配全。
AiProviderConfig? resolveVideoAcquireAiProvider(PreferencesRepository prefs) =>
    prefs.aiFeatureAssignments.resolve(
      AiFeature.videoAcquire,
      prefs.aiProviders,
    );

/// 一句话解析的输入：用户原文 + 当前会话的最小快照，让模型知道「在回答哪个问题」。
class VideoAcquisitionIntentQuery {
  VideoAcquisitionIntentQuery({
    required this.utterance,
    required this.stage,
    this.locale = 'en',
    this.pendingQuestion,
    this.slots = const <String, Object?>{},
    List<({String role, String text})> history =
        const <({String role, String text})>[],
  }) : history = List<({String role, String text})>.unmodifiable(
         history.length > kVideoAcquisitionIntentHistoryLimit
             ? history.sublist(
                 history.length - kVideoAcquisitionIntentHistoryLimit,
               )
             : history,
       );

  /// 用户这句话（原文，不清洗）。
  final String utterance;

  /// 让模型用哪种语言理解口语（`zh-CN` / `ja` …）；不影响输出——输出没有文本字段。
  final String locale;

  /// 会话阶段名（`VideoAcquisitionStage.name`）。
  final String stage;

  /// 当前挂起的问题；null = 没在等用户选。
  final VideoAcquisitionQuestion? pendingQuestion;

  /// 已定槽位的简化快照：`workTitle` / `workChosen` / `workKind` / `airing` /
  /// `mode` / `quality` / `subtitleLanguage` / `season` / `episodes`。只放模型
  /// 判断「这句话在补哪个槽」需要的键，值全是字符串 / 数字 / bool。
  final Map<String, Object?> slots;

  /// 最近的对话（`role` ∈ user / assistant），最多保留最后
  /// [kVideoAcquisitionIntentHistoryLimit] 条。
  final List<({String role, String text})> history;

  /// 用户提示的 JSON 形状。
  Map<String, Object?> toJson() => <String, Object?>{
    'locale': locale,
    'stage': stage,
    'pendingQuestion': pendingQuestion == null
        ? null
        : <String, Object?>{
            'slot': pendingQuestion!.slot.name,
            'options': <Object?>[
              for (int i = 0; i < pendingQuestion!.options.length; i += 1)
                <String, Object?>{
                  'index': i,
                  'label':
                      pendingQuestion!.options[i].label ??
                      pendingQuestion!.options[i].id,
                },
            ],
          },
    'slots': slots,
    'history': <Object?>[
      for (final ({String role, String text}) entry in history)
        <String, Object?>{'role': entry.role, 'text': entry.text},
    ],
    'utterance': utterance,
  };
}

/// 用户提示里带的对话历史上限。
const int kVideoAcquisitionIntentHistoryLimit = 6;

/// 意图枚举串（与 [VideoAcquisitionIntentKind.name] 一致），提示词与解析共用。
List<String> get _intentNames => <String>[
  for (final VideoAcquisitionIntentKind kind
      in VideoAcquisitionIntentKind.values)
    kind.name,
];

List<String> get _modeNames => <String>[
  for (final VideoAcquisitionMode mode in VideoAcquisitionMode.values)
    mode.name,
];

List<String> get _qualityKeys => <String>[
  for (final VideoAcquisitionQuality quality in VideoAcquisitionQuality.values)
    quality.storageKey,
];

/// 字幕语言白名单：`original` + 具体语言码 + `none`。
List<String> get _subtitleLanguageKeys => <String>[
  kVideoAcquisitionSubtitleOriginal,
  ...kVideoAcquisitionSubtitleLanguageCodes,
  kVideoAcquisitionSubtitleNone,
];

List<String> get _categoryNames => <String>[
  for (final VideoDiscoveryCategory category in VideoDiscoveryCategory.values)
    category.name,
];

String _quoted(Iterable<String> values) =>
    values.map((String value) => '"$value"').join(' | ');

/// 系统提示：只解析、只回 JSON、枚举白名单由代码枚举推导（改枚举提示词自动跟上）。
String buildVideoAcquisitionIntentSystemPrompt({required String locale}) =>
    '''
You turn one message from a user who wants to download or subscribe to a video
work (anime, TV series or movie) into a structured patch. You only extract what
the message states. You never decide what to do next, never ask questions, never
comment, and never invent facts the user did not say. The app itself decides
what is missing and what to ask.

The user may write in any language; the interface language tag is "$locale".

Answer with a single JSON object and nothing else. Every field is optional except
"intent"; omit a field (or set it to null) when the message does not state it.
{
  "intent": ${_quoted(_intentNames)},
  "choiceIndex": <0-based index into pendingQuestion.options, or null>,
  "workQueries": ["<work title>", "<alternate spelling>", ...],
  "category": ${_quoted(_categoryNames)},
  "season": <integer 1-99>,
  "episode": <integer 1-9999>,
  "episodeRange": {"from": <integer>, "to": <integer>},
  "allEpisodes": <true when the user explicitly asks for all / the whole season>,
  "mode": ${_quoted(_modeNames)},
  "quality": ${_quoted(_qualityKeys)},
  "qualityRemember": <true only when the user says this quality should be the default from now on>,
  "subtitleLanguage": ${_quoted(_subtitleLanguageKeys)},
  "subtitleLanguageRemember": <true only when the user says this subtitle language should be the default from now on>
}

Rules:
- "intent": "choose" when the user is answering the pending question (for
  example "the first one", "the 1080p one", "follow the work", "subscribe");
  then give "choiceIndex" (0-based) and prefer it over other fields. "next"
  means "another version / not this one". "confirm" means "this one / yes / go".
  "cancel" means "never mind / stop". "provide" when the message adds new
  information (a title, a quality, a language, an episode, ...). "unclear"
  when you cannot tell.
- When "pendingQuestion" is null there is nothing to choose; use "provide",
  "next", "confirm", "cancel" or "unclear" instead.
- "workQueries": the work title as the user wrote it, plus 1 to 3 other
  spellings you are confident about (original Japanese title, Hepburn romaji,
  official English title). 2 to 4 entries, each at most 80 characters, without
  season numbers, episode numbers, resolution or codec tags. Do not guess
  titles you are unsure of; give only what the user wrote in that case. Leave
  the list empty when no work is mentioned.
- "mode": "download" for "download / get / grab it now"; "subscribe" for
  "follow / subscribe / keep getting new episodes".
- "quality": map "4K" / "2160" to "2160p", "1080" / "full HD" to "1080p",
  "720" to "720p", "480" / "SD" / "small" to "480p", "any / whatever" to "any".
- "subtitleLanguage": "original" when the user wants subtitles in the work's
  own language; a language code for an explicit language; "none" when the
  user wants no subtitles.
- "qualityRemember" / "subtitleLanguageRemember": true only when the user
  explicitly says "from now on", "by default", "always" or equivalent.
  Otherwise omit them; a one-off choice is not a new default.
- Numbers must be JSON numbers. Never add fields that are not listed above.
''';

/// 用户提示：整份快照 JSON 序列化，模型不用猜字段含义。
String buildVideoAcquisitionIntentUserPrompt(
  VideoAcquisitionIntentQuery query,
) => const JsonEncoder.withIndent('  ').convert(query.toJson());

/// 解析模型回复成已校验的意图。
///
/// - 抠不出 JSON / `intent` 不在枚举 → [VideoAcquisitionIntent.unclear]。
/// - 枚举字段越界**逐字段丢弃**：`quality: "4k"` 丢掉，同一包里的 `mode` 照收。
/// - `choiceIndex` 宽容解析（int / `"3"` / `3.0`），不在 `[0, optionCount)` 或
///   [optionCount] 为 0 → null。
/// - `season` 1..99、`episode` 1..9999、`episodeRange.from <= to` 且都在范围。
/// - `workQueries` 与 `parseAiSearchQueries` 同规则（trim、折叠空白、≤80、去重、≤4）。
/// - `intent == provide` 且补丁全空 → unclear（模型说「有新信息」却什么都没给）。
VideoAcquisitionIntent parseVideoAcquisitionIntent(
  String reply, {
  required int optionCount,
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) return const VideoAcquisitionIntent.unclear();
  final VideoAcquisitionIntentKind? kind = _readEnum(
    decoded['intent'],
    VideoAcquisitionIntentKind.values,
    (VideoAcquisitionIntentKind value) => value.name,
  );
  if (kind == null) return const VideoAcquisitionIntent.unclear();

  final int? season = _readIntInRange(decoded['season'], min: 1, max: 99);
  final int? episode = _readIntInRange(
    decoded['episode'],
    min: 1,
    max: kVideoAcquisitionEpisodeMax,
  );
  final ({int from, int to})? episodeRange = _readEpisodeRange(
    decoded['episodeRange'],
  );
  final int? rawChoice = _readIndex(decoded['choiceIndex']);
  final int? choiceIndex =
      rawChoice != null && rawChoice >= 0 && rawChoice < optionCount
      ? rawChoice
      : null;

  final VideoAcquisitionIntentPatch patch = VideoAcquisitionIntentPatch(
    workQueries: parseAiSearchQueries(
      jsonEncode(<String, Object?>{'queries': decoded['workQueries']}),
    ),
    category: _readEnum(
      decoded['category'],
      VideoDiscoveryCategory.values,
      (VideoDiscoveryCategory value) => value.name,
    ),
    season: season,
    episode: episode,
    episodeRange: episodeRange,
    allEpisodes: _readBool(decoded['allEpisodes']),
    quality: decoded['quality'] is String
        ? VideoAcquisitionQuality.fromStorageKey(decoded['quality'] as String)
        : null,
    qualityRemember: _readBool(decoded['qualityRemember']),
    subtitleLanguage: _readSubtitleLanguage(decoded['subtitleLanguage']),
    subtitleLanguageRemember: _readBool(decoded['subtitleLanguageRemember']),
    mode: _readEnum(
      decoded['mode'],
      VideoAcquisitionMode.values,
      (VideoAcquisitionMode value) => value.name,
    ),
    choiceIndex: choiceIndex,
  );
  if (kind == VideoAcquisitionIntentKind.provide && patch.isEmpty) {
    return const VideoAcquisitionIntent.unclear();
  }
  return VideoAcquisitionIntent(kind, patch);
}

/// 集号上限；再大就不是集号而是时间戳 / 年份了。
const int kVideoAcquisitionEpisodeMax = 9999;

T? _readEnum<T>(Object? raw, List<T> values, String Function(T value) nameOf) {
  if (raw is! String) return null;
  final String key = raw.trim().toLowerCase();
  for (final T value in values) {
    if (nameOf(value).toLowerCase() == key) return value;
  }
  return null;
}

bool? _readBool(Object? raw) => raw is bool ? raw : null;

/// 模型给下标时 int / "3" / 3.0 都见过，统一收成 int；认不出为 null。
int? _readIndex(Object? raw) {
  if (raw is int) return raw;
  if (raw is double && raw.isFinite && raw == raw.roundToDouble()) {
    return raw.round();
  }
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

int? _readIntInRange(Object? raw, {required int min, required int max}) {
  final int? value = _readIndex(raw);
  if (value == null || value < min || value > max) return null;
  return value;
}

({int from, int to})? _readEpisodeRange(Object? raw) {
  if (raw is! Map) return null;
  final int? from = _readIntInRange(
    raw['from'],
    min: 1,
    max: kVideoAcquisitionEpisodeMax,
  );
  final int? to = _readIntInRange(
    raw['to'],
    min: 1,
    max: kVideoAcquisitionEpisodeMax,
  );
  if (from == null || to == null || from > to) return null;
  return (from: from, to: to);
}

/// `original` / `none` 原样；其余先归一再比白名单（`jpn` / `ja-JP` → `ja`）。
String? _readSubtitleLanguage(Object? raw) {
  if (raw is! String) return null;
  final String value = raw.trim().toLowerCase();
  if (value == kVideoAcquisitionSubtitleOriginal ||
      value == kVideoAcquisitionSubtitleNone) {
    return value;
  }
  final String? code = normalizeSubtitleLanguageCode(value);
  if (code == null || !kVideoAcquisitionSubtitleLanguageCodes.contains(code)) {
    return null;
  }
  return code;
}

/// 跑一次意图解析。失败原样抛 [AiChatFailure]（文案已脱敏），由调用方决定吞不吞。
Future<VideoAcquisitionIntent> requestVideoAcquisitionIntent({
  required AiChatClient client,
  required AiProviderConfig provider,
  required VideoAcquisitionIntentQuery query,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildVideoAcquisitionIntentSystemPrompt(locale: query.locale),
      ),
      AiChatMessage.user(buildVideoAcquisitionIntentUserPrompt(query)),
    ],
    // 回复只有一个小 JSON 对象；给 512 是留给推理型模型偶尔多话。
    maxTokens: 512,
  );
  return parseVideoAcquisitionIntent(
    reply,
    optionCount: query.pendingQuestion?.optionCount ?? 0,
  );
}

// ---------------------------------------------------------------------------
// 多义作品选择（复用刮削身份判定的契约与解析）
// ---------------------------------------------------------------------------

/// 系统提示：语境是「用户口头说了作品名、候选已取回」，与刮削那份（本地目录名）
/// 的规则不同——用户没说季而候选多季 → null；不选剧场版 / OVA 除非用户说了。
String buildAiVideoAcquisitionIdentitySystemPrompt({required String locale}) =>
    '''
The user named a video work they want to download, and a metadata provider
returned several candidate works. You choose exactly one candidate that the
user meant, or null. The candidates were already fetched; you only choose among
them and must not invent other works or identifiers.

Answer with a single JSON object and nothing else:
{"key": "<candidate key or null>", "confidence": <number 0.0-1.0>, "reason": "..."}

Rules:
- "key" must be copied verbatim from one candidate's "key", or be null.
- "localTitles" holds what the user said (title as typed, plus spellings the
  app derived from it); "season", "year" and "sampleFileNames" are what the
  user mentioned, when anything.
- Return null for "key" whenever any of these holds: several candidates fit the
  user's words equally well; the user did not mention a season and the
  candidates are different seasons of the same work; no candidate plausibly
  matches.
- Do not pick a movie, OVA, special or spin-off unless the user said so; when
  the user just names the franchise, prefer the main TV series.
- "confidence" is your honest probability that the chosen candidate is the
  right work. Use 0.9 or higher only when title, type and (when mentioned)
  year and season all agree; otherwise stay below 0.85.
- Compare titles across languages and romanizations (Japanese, Chinese,
  Korean, English, romaji), ignoring case and punctuation.
- "reason" is one short sentence written in the language with tag "$locale".
''';

/// 跑一次「用户说的是哪一部」判定。失败原样抛 [AiChatFailure]。
Future<AiVideoIdentityDecision> requestAiVideoAcquisitionIdentity({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiVideoIdentityQuery query,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiVideoAcquisitionIdentitySystemPrompt(locale: query.locale),
      ),
      AiChatMessage.user(buildAiVideoIdentityUserPrompt(query)),
    ],
    maxTokens: 512,
  );
  return parseAiVideoIdentityDecision(reply, allowedKeys: query.candidateKeys);
}

// ---------------------------------------------------------------------------
// 生产装配
// ---------------------------------------------------------------------------

/// 一句话 → 意图。返回 null = 提供商未指派（功能不存在，不发请求）。
typedef VideoAcquisitionIntentParser =
    Future<VideoAcquisitionIntent?> Function(VideoAcquisitionIntentQuery query);

/// 生产装配：每次被问时**现取**偏好里的指派（用户在设置页改了立即生效），未指派回
/// null 不发请求。[clientFactory] 只给测试注入假客户端；生产每次新建、用完即关。
///
/// 失败先记诊断日志再原样抛出：编排器据此回退成「请点选」（chip 不经 LLM），
/// 流程照样能走完。
VideoAcquisitionIntentParser createPreferencesVideoAcquisitionIntentParser(
  PreferencesRepository prefsRepo, {
  AiClientFactory? clientFactory,
}) => (VideoAcquisitionIntentQuery query) async {
  final AiProviderConfig? provider = resolveVideoAcquireAiProvider(prefsRepo);
  if (provider == null) return null;
  final AiChatClient client = clientFactory?.call() ?? AiChatClient();
  try {
    return await requestVideoAcquisitionIntent(
      client: client,
      provider: provider,
      query: query,
    );
  } catch (error, stack) {
    ErrorLogService.instance.logDiagnostic(
      'VideoAcquisition.intent',
      '${query.stage}: $error\n$stack',
    );
    rethrow;
  } finally {
    client.close();
  }
};

/// 生产装配：多义作品选择。语义同 [createPreferencesVideoAcquisitionIntentParser]，
/// 只是指派槽位是 [AiFeature.videoAcquire] 而非刮削的 `videoIdentify`。
AiVideoIdentityDecider createPreferencesVideoAcquisitionIdentityDecider(
  PreferencesRepository prefsRepo, {
  AiClientFactory? clientFactory,
}) => (AiVideoIdentityQuery query) async {
  final AiProviderConfig? provider = resolveVideoAcquireAiProvider(prefsRepo);
  if (provider == null) return null;
  final AiChatClient client = clientFactory?.call() ?? AiChatClient();
  try {
    return await requestAiVideoAcquisitionIdentity(
      client: client,
      provider: provider,
      query: query,
    );
  } catch (error, stack) {
    ErrorLogService.instance.logDiagnostic(
      'VideoAcquisition.identity',
      '${query.localTitles.join(' / ')}: $error\n$stack',
    );
    rethrow;
  } finally {
    client.close();
  }
};
