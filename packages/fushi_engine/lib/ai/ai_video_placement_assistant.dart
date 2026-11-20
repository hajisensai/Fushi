/// 视频摆放判断：让模型看一部剧集作品里「挂在第 0 季 / 没绑到任何一集」的本机
/// 文件，判断它们是真的特别篇、其实是独立的电影、还是正片的某一集。
///
/// 契约类型住在 `media/video/organize/video_placement_ai.dart`（库管家在引擎包里，
/// 不能反向依赖 LLM 客户端）；本文件只负责「怎么问模型」：提示词、回复解析、生产
/// 装配。用「视频作品识别」（[AiFeature.videoIdentify]）的指派——这就是认身份的
/// 一部分（AI 库管家设计稿 §9：不新增功能指派，每一步用它自己的）。
///
/// 模型回复经 [parseAiVideoPlacementAnswers] 本地校验：键必须是提问里的文件键，
/// 判定必须是四种之一，`episode` 的季集必须落在作品的正片季集范围内，否则降级成
/// `unsure`。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/organize/video_placement_ai.dart';

export 'package:fushi_engine/media/video/organize/video_placement_ai.dart';

String buildAiVideoPlacementSystemPrompt({required String locale}) =>
    '''
A media library filed some local video files under the "specials" season
(season 0) of a TV series, or left them in the series folder without matching
any episode. Many of these are wrong: a feature film of the franchise filed as
"S00E01", a regular episode mislabelled as a special. Look at each file and
decide what it really is.

The user message is a JSON object: "work" describes the series (titles, year,
regular episode length in minutes, regular seasons with their episode counts,
how many regular episodes exist locally) and "files" lists the files to judge
(path relative to the library root, length in minutes, the special it is
currently bound to and that special's title / length in the metadata source).

Answer with a single JSON object and nothing else:
{"files": [{"key": "<file key>", "verdict": "special|movie|episode|unsure",
"confidence": <number 0.0-1.0>, "title": "...", "season": 1, "episode": 2,
"reason": "..."}]}

Rules:
- One entry per file, "key" copied verbatim from the input.
- "special": a genuine special / OVA / bonus of this series. Typical signs: about
  as long as a regular episode or shorter; the bound special's title or length
  fits the file; names like OVA, SP, NCOP, PV, picture drama.
- "movie": a separate work that metadata databases list on its own (theatrical
  film, standalone movie). Typical signs: feature length (usually 60+ minutes
  and far longer than a regular episode); names or folders containing 劇場版,
  剧场版, Movie, The Movie, a film subtitle or a film year. Give "title": the
  title under which this film is most likely listed (original title preferred),
  or omit it when the path does not tell which film it is.
- "episode": actually a regular episode of this series. Give "season" and
  "episode"; they must exist in "regularSeasons". Use it only when the path
  clearly names that episode.
- "unsure": the facts do not settle it. Prefer "unsure" over guessing: a wrong
  "movie" or "episode" moves the user's file to the wrong place.
- A long recap / compilation that the bound special's title or length matches
  is a "special", not a "movie".
- "confidence" is your honest probability that the verdict is right. Use 0.85
  or higher only when length and names agree.
- "reason" is one short sentence in the language with tag "$locale".
''';

String buildAiVideoPlacementUserPrompt(AiVideoPlacementQuery query) =>
    jsonEncode(query.toJson());

/// 解析并校验模型回复。抠不出 JSON → 空表（没有结论）。
List<AiVideoPlacementAnswer> parseAiVideoPlacementAnswers(
  String reply, {
  required AiVideoPlacementQuery query,
}) {
  final Object? raw = decodeAiJsonObject(reply)?['files'];
  if (raw is! List<Object?>) return const <AiVideoPlacementAnswer>[];
  final Set<String> keys = <String>{
    for (final AiVideoPlacementFile f in query.files) f.key,
  };
  final Map<String, AiVideoPlacementAnswer> out =
      <String, AiVideoPlacementAnswer>{};
  for (final Object? entry in raw) {
    if (entry is! Map) continue;
    final Object? key = entry['key'];
    if (key is! String || !keys.contains(key) || out.containsKey(key)) continue;
    AiVideoPlacementVerdict verdict =
        AiVideoPlacementVerdict.values.asNameMap()[entry['verdict']] ??
        AiVideoPlacementVerdict.unsure;
    final Object? rawConfidence = entry['confidence'];
    double confidence =
        rawConfidence is num &&
            rawConfidence.isFinite &&
            rawConfidence >= 0 &&
            rawConfidence <= 1
        ? rawConfidence.toDouble()
        : 0;
    final Object? rawTitle = entry['title'];
    final String? title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : null;
    int? season;
    int? episode;
    if (verdict == AiVideoPlacementVerdict.episode) {
      final Object? s = entry['season'];
      final Object? e = entry['episode'];
      final int? count = s is int ? query.regularSeasons[s] : null;
      if (s is int && e is int && count != null && e >= 1 && e <= count) {
        season = s;
        episode = e;
      } else {
        // 给不出作品里真实存在的集位：这个判定没法执行。
        verdict = AiVideoPlacementVerdict.unsure;
      }
    }
    if (verdict == AiVideoPlacementVerdict.unsure) confidence = 0;
    final Object? reason = entry['reason'];
    out[key] = AiVideoPlacementAnswer(
      key: key,
      verdict: verdict,
      confidence: confidence,
      title: verdict == AiVideoPlacementVerdict.movie ? title : null,
      season: season,
      episode: episode,
      reason: reason is String ? reason.trim() : '',
    );
  }
  return List<AiVideoPlacementAnswer>.unmodifiable(out.values);
}

/// 跑一次判断。失败原样抛 [AiChatFailure]（文案已脱敏）。
Future<List<AiVideoPlacementAnswer>> requestAiVideoPlacement({
  required AiChatClient client,
  required AiProviderConfig provider,
  required AiVideoPlacementQuery query,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(
        buildAiVideoPlacementSystemPrompt(locale: query.locale),
      ),
      AiChatMessage.user(buildAiVideoPlacementUserPrompt(query)),
    ],
    // 每个文件一小段 JSON；一部长寿番的第 0 季能有几十个文件。
    maxTokens: 4096,
  );
  return parseAiVideoPlacementAnswers(reply, query: query);
}

/// 生产装配：每次被问时现取偏好里「视频作品识别」的指派；未指派时 [isAssigned]
/// 为 false，库管家据此完全不问（不发请求）。
class PreferencesAiVideoPlacementAdvisor {
  PreferencesAiVideoPlacementAdvisor(
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

  Future<List<AiVideoPlacementAnswer>> judge(
    AiVideoPlacementQuery query,
  ) async {
    final AiProviderConfig? provider = _provider();
    if (provider == null) {
      throw StateError('视频作品识别未指派可用的 AI 提供商');
    }
    final AiChatClient client = _clientFactory?.call() ?? AiChatClient();
    try {
      return await requestAiVideoPlacement(
        client: client,
        provider: provider,
        query: query,
      );
    } catch (error, stack) {
      engineLog.logDiagnostic(
        'LibraryCurator.videoPlacement',
        '${query.workTitle}: $error\n$stack',
      );
      rethrow;
    } finally {
      client.close();
    }
  }
}
