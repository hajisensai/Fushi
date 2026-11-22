/// LLM 选角标注的两遍主循环（纯 Dart，不碰网络 / 存储 / 偏好）。
///
/// [annotateTtsCast]（`tts_cast_annotator.dart`）负责解析 AI 提供商、读写选角表与
/// 系列档案，再把「问模型」和「落盘」作为回调交给 [runTtsCastPasses]；两遍的分块、
/// 回复校验与并表都在这里，测试可以用假的 [TtsCastAsk] 端到端驱动。
library;

import 'package:fushi_engine/tts/cast/cast_prompt_roster.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_prompt.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

/// [runTtsCastPasses] 的 `onPhase` 阶段名：第一遍角色表。
const String kTtsCastPhaseRoster = 'roster';

/// [runTtsCastPasses] 的 `onPhase` 阶段名：第二遍逐句归属。
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

/// 问一次模型：[system] 系统提示词、[user] 用户提示词，返回原始回复文本。
/// 调用失败由实现方抛 [TtsCastAnnotateFailure]（`ai_failed`）。
typedef TtsCastAsk = Future<String> Function(String system, String user);

/// 对 [todo]（升序章号）跑两遍标注，结果并进 [cast]：
/// 1. `roster`：逐章逐块抽角色表，每章并完调一次 [save]；
/// 2. `lines`：逐章逐块按角色表归属台词，一章标完并入 [cast] 后调一次 [save]。
///
/// 回复不可用（缺 JSON 数组 / 复读 / 非空数组全废）抛 `bad_output`；模型回空数组
/// `[]` 是合法的「本块没有新角色 / 没有说出口的台词」，不算失败（见
/// [ttsRosterReplyFailureReason] / [ttsCastReplyFailureReason]）。
///
/// [onProgress] = 两遍都完成的章数 / 待标章数；[onPhase] = 当前阶段
/// （[kTtsCastPhaseRoster] / [kTtsCastPhaseLines]）内完成的章数 / 待标章数。
Future<void> runTtsCastPasses({
  required TtsCast cast,
  required Map<int, List<TtsPlanSentence>> bySection,
  required List<int> todo,
  required List<CastTextSubstitution> substitutions,
  required TtsCastAsk ask,
  required Future<void> Function() save,
  required void Function(int done, int total) onProgress,
  required bool Function() isCancelled,
  void Function(String phase, int done, int total)? onPhase,
}) async {
  onProgress(0, todo.length);

  onPhase?.call(kTtsCastPhaseRoster, 0, todo.length);
  for (int done = 0; done < todo.length; done++) {
    final int section = todo[done];
    for (final TtsCastChunk chunk in chunkTtsRosterSection(
      bySection[section]!,
    )) {
      if (isCancelled()) throw const TtsCastAnnotateFailure('cancelled');
      final List<TtsCastCharacter> roster = _orderedRoster(cast);
      final CastPromptRoster promptRoster = CastPromptRoster(
        roster: roster,
        substitutions: substitutions,
      );
      final String reply = await ask(
        kTtsRosterSystemPrompt,
        buildTtsRosterUserPrompt(
          chunk,
          roster: roster,
          promptRoster: promptRoster,
          substitutions: substitutions,
        ),
      );
      final TtsRosterParseResult? parsed = parseTtsRosterReply(
        reply,
        promptRoster: promptRoster,
      );
      final String? failure = ttsRosterReplyFailureReason(parsed);
      if (parsed == null || failure != null) {
        throw TtsCastAnnotateFailure(
          'bad_output',
          'roster, section $section: $failure',
        );
      }
      applyTtsRosterOps(cast, parsed.ops);
    }
    await save();
    onPhase?.call(kTtsCastPhaseRoster, done + 1, todo.length);
  }

  onPhase?.call(kTtsCastPhaseLines, 0, todo.length);
  for (int done = 0; done < todo.length; done++) {
    final int section = todo[done];
    final List<TtsCastCharacter> roster = _orderedRoster(cast);
    final TtsCastSpeakerIndex index = TtsCastSpeakerIndex(roster);
    final CastPromptRoster promptRoster = CastPromptRoster(
      roster: roster,
      substitutions: substitutions,
    );
    final Map<String, TtsCastLine> annotated = <String, TtsCastLine>{};
    List<TtsCastRecentLine> recent = const <TtsCastRecentLine>[];
    for (final TtsCastChunk chunk in chunkTtsCastSection(bySection[section]!)) {
      if (isCancelled()) throw const TtsCastAnnotateFailure('cancelled');
      final String reply = await ask(
        kTtsCastLinesSystemPrompt,
        buildTtsCastLinesUserPrompt(
          chunk,
          roster: roster,
          promptRoster: promptRoster,
          recent: recent,
          substitutions: substitutions,
        ),
      );
      final TtsCastParseResult? parsed = parseTtsCastReply(
        reply,
        chunk.sentences.length,
        speakers: index,
        promptRoster: promptRoster,
      );
      final String? failure = ttsCastReplyFailureReason(parsed);
      if (parsed == null || failure != null) {
        throw TtsCastAnnotateFailure(
          'bad_output',
          'lines, section $section: $failure',
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
    await save();
    onPhase?.call(kTtsCastPhaseLines, done + 1, todo.length);
    onProgress(done + 1, todo.length);
  }
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
