/// LLM 标注说话人（多声优配音的选角）。
///
/// 两遍（分块 / 提示词 / 解析 / 角色表操作见 `tts_cast_prompt.dart`）：
/// 1. `roster`：逐章逐块抽角色表，每章并完即落盘；
/// 2. `lines`：逐章逐块按角色表归属台词，一章标完并入选角表即落盘。
/// 第一遍先把所有待标的章跑完，第二遍才开始——后面章节才揭晓的名字 / 别名也能
/// 用在前面章节的归属上。中途取消或失败，已落盘的角色表与已标完的章不丢；重跑时
/// 未标完的章会重做第一遍（并入是幂等的：同名补别名 / 空特征，不覆盖已有值）。
///
/// 采样温度：[AiChatClient.complete] 不暴露 temperature（各协议默认值不同，推理
/// 模型还拒收这个字段），这里用服务端默认值；稳定性靠严格 JSON 约束 + 本地校验。
library;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_prompt.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/models/app_model.dart';

/// 单块回复的输出上限：100 句全是台词时约 4k token，给推理模型的思考留余量。
const int _kAnnotateMaxTokens = 8192;

/// [annotateTtsCast] 的 `onPhase` 阶段名：第一遍角色表。
const String kTtsCastPhaseRoster = 'roster';

/// [annotateTtsCast] 的 `onPhase` 阶段名：第二遍逐句归属。
const String kTtsCastPhaseLines = 'lines';

/// 标注失败（[code]：`no_ai_provider` / `ai_failed` / `bad_output` / `cancelled`）。
class TtsCastAnnotateFailure implements Exception {
  const TtsCastAnnotateFailure(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() =>
      'TtsCastAnnotateFailure($code${detail == null ? '' : ': $detail'})';
}

/// 两遍请 LLM 标注 [sections]（空 = 计划里的全部章）里每句的说话人，并入 [bookKey]
/// 的选角表并落盘；用户手改过的行保留。返回更新后的选角表。
///
/// [onProgress] = 两遍都完成的章数 / 待标章数；[onPhase] = 当前阶段
/// （[kTtsCastPhaseRoster] / [kTtsCastPhaseLines]）内完成的章数 / 待标章数。
Future<TtsCast> annotateTtsCast({
  required AppModel appModel,
  required String bookKey,
  required TtsBookPlan plan,
  Set<int> sections = const <int>{},
  bool skipAnnotated = true,
  required void Function(int done, int total) onProgress,
  required bool Function() isCancelled,
  void Function(String phase, int done, int total)? onPhase,
}) async {
  final AiProviderConfig? provider = appModel.isPreferencesReady
      ? appModel.prefsRepo.aiFeatureAssignments.resolve(
          AiFeature.audiobookCast,
          appModel.prefsRepo.aiProviders,
        )
      : null;
  if (provider == null) throw const TtsCastAnnotateFailure('no_ai_provider');

  final TtsCastStore store = ttsCastStoreFor(appModel);
  final TtsCast cast = await store.load(bookKey);
  _seedRosterFromLines(cast);

  final Map<int, List<TtsPlanSentence>> bySection =
      <int, List<TtsPlanSentence>>{};
  for (final TtsPlanSentence s in plan.sentences) {
    if (sections.isNotEmpty && !sections.contains(s.section)) continue;
    (bySection[s.section] ??= <TtsPlanSentence>[]).add(s);
  }
  final List<int> todo =
      bySection.keys
          .where(
            (int section) =>
                !skipAnnotated || !cast.annotatedSections.contains(section),
          )
          .toList()
        ..sort();

  final AiChatClient client = AiChatClient();
  Future<String> ask(String system, String user) async {
    try {
      return await client.complete(
        provider: provider,
        messages: <AiChatMessage>[
          AiChatMessage.system(system),
          AiChatMessage.user(user),
        ],
        maxTokens: _kAnnotateMaxTokens,
      );
    } on AiChatFailure catch (e) {
      throw TtsCastAnnotateFailure('ai_failed', e.message);
    }
  }

  try {
    onProgress(0, todo.length);

    onPhase?.call(kTtsCastPhaseRoster, 0, todo.length);
    for (int done = 0; done < todo.length; done++) {
      final int section = todo[done];
      for (final TtsCastChunk chunk in chunkTtsRosterSection(
        bySection[section]!,
      )) {
        if (isCancelled()) throw const TtsCastAnnotateFailure('cancelled');
        final String reply = await ask(
          kTtsRosterSystemPrompt,
          buildTtsRosterUserPrompt(chunk, roster: _orderedRoster(cast)),
        );
        final TtsRosterParseResult? parsed = parseTtsRosterReply(reply);
        if (parsed == null ||
            parsed.looping ||
            (parsed.ops.isEmpty && parsed.rawCount > 0)) {
          throw TtsCastAnnotateFailure(
            'bad_output',
            'roster, section $section: ${_badReason(parsed?.looping)}',
          );
        }
        applyTtsRosterOps(cast, parsed.ops);
      }
      await store.save(bookKey, cast);
      onPhase?.call(kTtsCastPhaseRoster, done + 1, todo.length);
    }

    onPhase?.call(kTtsCastPhaseLines, 0, todo.length);
    for (int done = 0; done < todo.length; done++) {
      final int section = todo[done];
      final List<TtsCastCharacter> roster = _orderedRoster(cast);
      final TtsCastSpeakerIndex index = TtsCastSpeakerIndex(roster);
      final Map<String, TtsCastLine> annotated = <String, TtsCastLine>{};
      List<TtsCastRecentLine> recent = const <TtsCastRecentLine>[];
      for (final TtsCastChunk chunk in chunkTtsCastSection(
        bySection[section]!,
      )) {
        if (isCancelled()) throw const TtsCastAnnotateFailure('cancelled');
        final String reply = await ask(
          kTtsCastLinesSystemPrompt,
          buildTtsCastLinesUserPrompt(chunk, roster: roster, recent: recent),
        );
        final TtsCastParseResult? parsed = parseTtsCastReply(
          reply,
          chunk.sentences.length,
          speakers: index,
        );
        if (parsed == null ||
            parsed.looping ||
            (parsed.labels.isEmpty &&
                (parsed.rawCount > 0 || chunk.hasDialogue))) {
          throw TtsCastAnnotateFailure(
            'bad_output',
            'lines, section $section: ${_badReason(parsed?.looping)}',
          );
        }
        final Map<String, TtsCastLine> lines = ttsCastLinesForChunk(
          chunk,
          parsed.labels,
        );
        annotated.addAll(lines);
        recent = ttsCastRecentDialogue(chunk, lines);
      }
      cast.mergeLlm(section, annotated);
      await store.save(bookKey, cast);
      onPhase?.call(kTtsCastPhaseLines, done + 1, todo.length);
      onProgress(done + 1, todo.length);
    }
  } finally {
    client.close();
  }
  return cast;
}

String _badReason(bool? looping) => switch (looping) {
  null => 'no JSON array',
  true => 'looping output',
  false => 'no usable entries',
};

/// 旧版选角表（只有逐句标注、没有角色表）或用户手填的新名字：先补进角色表，
/// 否则第二遍只能从角色表里选人，这些名字会被打成「不明」。
void _seedRosterFromLines(TtsCast cast) {
  final TtsCastSpeakerIndex index = TtsCastSpeakerIndex(cast.roster.values);
  cast.mergeRoster(<TtsCastCharacter>[
    for (final ({String speaker, int count}) s in cast.speakers())
      if (s.speaker != kTtsUnknown && index.canonicalOf(s.speaker) == null)
        TtsCastCharacter(name: s.speaker),
  ]);
}

/// 角色表按台词数降序（提示词截断时留下戏份多的），没台词的按原顺序排在后面。
List<TtsCastCharacter> _orderedRoster(TtsCast cast) {
  final Map<String, int> counts = <String, int>{
    for (final ({String speaker, int count}) s in cast.speakers())
      s.speaker: s.count,
  };
  final List<TtsCastCharacter> list = cast.roster.values.toList();
  final Map<String, int> order = <String, int>{
    for (int i = 0; i < list.length; i++) list[i].name: i,
  };
  return list..sort((TtsCastCharacter a, TtsCastCharacter b) {
    final int byCount = (counts[b.name] ?? 0).compareTo(counts[a.name] ?? 0);
    return byCount != 0 ? byCount : order[a.name]!.compareTo(order[b.name]!);
  });
}
