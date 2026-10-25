/// 作品图谱 AI 裁决（[AiFeature.mediaLinks]，spec
/// `docs/specs/2026-10-24-cross-media-links.md`「AI 辅助判断」）。
///
/// 输入是确定性规则已缩小的候选（两端各自的标题写法、年份、种类、已知外部 id、
/// 规则给出的证据），输出按候选下标回填的结构化结论：是否同一作品 / 有关联、关系
/// （adaptation / same_work）、方向（哪一端是原作）、置信度、理由。**不让 AI 自由
/// 检索或编造 id**：回复里只有下标与枚举值，端点永远来自本地数据；下标越界、关系
/// 不认识、置信度非法的条目一律丢弃（该条视为「判不了」，保留确定性结果）。
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';

/// 一次请求最多送几条候选（再多拆批）。
const int kAiMediaLinkMaxCandidatesPerRequest = 20;

/// 解析「作品图谱裁决」当前可用的提供商；null = 未指派 / 已删 / 没配全（跳过 AI，
/// 只剩确定性推断）。
AiProviderConfig? resolveMediaLinkAiProvider(AiSettingsSource settings) =>
    settings.aiFeatureAssignments.resolve(
      AiFeature.mediaLinks,
      settings.aiProviders,
    );

const String kAiMediaLinkSystemPrompt = '''
You decide whether pairs of items from one person's media library (anime /
video series, single videos, books including manga and light novels, visual
novels and other games, music) belong to the same creative work or franchise.

For every candidate you get both sides with their kind, every known title
spelling, year and known external ids, plus the evidence a local rule found.
Judge each candidate on its own:
- "related": true only if both sides are the same work or one is an
  adaptation of the other (novel -> anime, game -> anime, manga -> game ...).
  Same title alone is not enough when years, kinds or creators contradict it.
- "relation": "adaptation" when one side adapts the other, "same_work" when
  they are versions of the same work and no side is clearly the original.
- "original": "a" or "b" for the side that is the original work of an
  adaptation; "unknown" when you cannot tell.
- "confidence": a number from 0 to 1.
- "reason": one short sentence the user will read.

Never invent identifiers and never add candidates. Reply with one JSON object
only, no prose:
{"verdicts":[{"index":0,"related":true,"relation":"adaptation","original":"a","confidence":0.8,"reason":"..."}]}
''';

Map<String, Object?> _side(MediaLinkSubject s) => <String, Object?>{
  'kind': s.endpoint.kind.dbValue,
  'titles': s.titles,
  if (s.year != null) 'year': s.year,
  if (s.externalIds.isNotEmpty) 'ids': s.externalIds,
};

/// 用户消息：候选数组（a = 候选 from，b = 候选 to）。
String buildAiMediaLinkUserPrompt(List<MediaLinkCandidate> candidates) =>
    jsonEncode(<String, Object?>{
      'candidates': <Map<String, Object?>>[
        for (int i = 0; i < candidates.length; i++)
          <String, Object?>{
            'index': i,
            'a': _side(candidates[i].from),
            'b': _side(candidates[i].to),
            'evidence': candidates[i].reason,
          },
      ],
    });

/// 解析 AI 回复成与 [count] 条候选同序的结论；形状不对的条目为 null。
List<MediaLinkVerdict?> parseAiMediaLinkVerdicts(String reply, int count) {
  final List<MediaLinkVerdict?> out = List<MediaLinkVerdict?>.filled(
    count,
    null,
  );
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? raw = json?['verdicts'];
  if (raw is! List) return out;
  for (final Object? node in raw) {
    if (node is! Map) continue;
    final Object? index = node['index'];
    if (index is! int || index < 0 || index >= count) continue;
    final Object? related = node['related'];
    final Object? confidence = node['confidence'];
    final Object? reason = node['reason'];
    if (related is! bool || confidence is! num) continue;
    final double c = confidence.toDouble();
    if (c.isNaN || c < 0 || c > 1) continue;
    final MediaLinkRelation? relation = switch (node['relation']) {
      'adaptation' => MediaLinkRelation.adaptation,
      'same_work' => MediaLinkRelation.sameWork,
      _ => null,
    };
    if (related && relation == null) continue;
    out[index] = MediaLinkVerdict(
      related: related,
      relation: relation ?? MediaLinkRelation.sameWork,
      fromIsOriginal: switch (node['original']) {
        'a' => true,
        'b' => false,
        _ => null,
      },
      confidence: c,
      reason: reason is String && reason.trim().isNotEmpty
          ? reason.trim()
          : 'AI verdict',
    );
  }
  return out;
}

/// [MediaLinkJudge] 的 AI 实现：按 [kAiMediaLinkMaxCandidatesPerRequest] 分批请求。
class AiMediaLinkJudge implements MediaLinkJudge {
  const AiMediaLinkJudge({required this.client, required this.provider});

  final AiChatClient client;
  final AiProviderConfig provider;

  @override
  Future<List<MediaLinkVerdict?>> judge(
    List<MediaLinkCandidate> candidates,
  ) async {
    final List<MediaLinkVerdict?> out = <MediaLinkVerdict?>[];
    for (
      int start = 0;
      start < candidates.length;
      start += kAiMediaLinkMaxCandidatesPerRequest
    ) {
      final List<MediaLinkCandidate> batch = candidates.sublist(
        start,
        (start + kAiMediaLinkMaxCandidatesPerRequest).clamp(
          0,
          candidates.length,
        ),
      );
      final String reply = await client.complete(
        provider: provider,
        messages: <AiChatMessage>[
          AiChatMessage.system(kAiMediaLinkSystemPrompt),
          AiChatMessage.user(buildAiMediaLinkUserPrompt(batch)),
        ],
        maxTokens: 2048,
      );
      out.addAll(parseAiMediaLinkVerdicts(reply, batch.length));
    }
    return out;
  }
}
