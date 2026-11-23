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

/// 标注失败（[code]：`no_ai_provider` / `ai_failed` / `bad_output` /
/// [kTtsCastFailureOutputLimit] / `cancelled`）。
///
/// `bad_output` 带上模型的原始回复 [reply]：错误日志里要能看到模型到底回了什么，
/// 否则「回复无法理解」无从查起（BUG-5366）。
class TtsCastAnnotateFailure implements Exception {
  const TtsCastAnnotateFailure(this.code, [this.detail, this.reply]);
  final String code;
  final String? detail;
  final String? reply;

  @override
  String toString() {
    final StringBuffer b = StringBuffer('TtsCastAnnotateFailure($code');
    if (detail != null) b.write(': $detail');
    b.write(')');
    if (reply case final String r) {
      final String shown = r.length > _kFailureReplyMaxChars
          ? '${r.substring(0, _kFailureReplyMaxChars)}…'
          : r;
      b.write('\nreply (${r.length} chars):\n$shown');
    }
    return b.toString();
  }
}

/// 拆到 [kTtsCastSplitMinSentences] 句以内的块回复仍被截断：模型（多半是推理模型
/// 的思考）把整份输出额度用光，块再小也写不出标注（BUG-5369）。界面提示调低推理
/// 强度；[TtsCastAnnotateFailure.detail] 记哪一遍、哪章、几句。
const String kTtsCastFailureOutputLimit = 'output_limit';

/// 错误日志里原始回复最多留多少字符（台词遍一块的回复约 4k token）。
const int _kFailureReplyMaxChars = 20000;

/// 一次问答的回复：[text] 原始回复文本；[truncated] = 输出撞上上限被截断（[text]
/// 只是前半截，可能为空——推理模型把额度全花在思考上）。
typedef TtsCastReply = ({String text, bool truncated});

/// 问一次模型：[system] 系统提示词、[user] 用户提示词。
/// 调用失败由实现方抛 [TtsCastAnnotateFailure]（`ai_failed`）；输出被截断（含正文
/// 为空的截断）不是失败，返回 `truncated: true`，由 [runTtsCastPasses] 拆块重问。
typedef TtsCastAsk = Future<TtsCastReply> Function(String system, String user);

/// 对 [todo]（升序章号）跑两遍标注，结果并进 [cast]：
/// 1. `roster`：逐章逐块抽角色表，每章并完调一次 [save]；
/// 2. `lines`：逐章逐块按角色表归属台词，一章标完并入 [cast] 后调一次 [save]。
///
/// 回复不可用（缺 JSON 数组 / 复读 / 非空数组全废）抛 `bad_output`；模型回空数组
/// `[]` 是合法的「本块没有新角色 / 没有说出口的台词」，不算失败（见
/// [ttsRosterReplyFailureReason] / [ttsCastReplyFailureReason]）。
///
/// 回复被截断（[TtsCastReply.truncated]，正文为空或只有前半截）：把这块按字数拆成
/// 两半依次重问，递归到 [kTtsCastSplitMinSentences] 句为止，仍截断抛
/// [kTtsCastFailureOutputLimit]（BUG-5369）。截断的前半截不拿来补救：缺的行会被
/// 悄悄记成旁白 / 不明。拆块不影响进度计数（按章算）。
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
  // 示例语言跟着正文走（BUG-5366）；惰性取文本，检测只读前两万字。
  final TtsCastScript script = detectTtsCastScript(
    todo.expand(
      (int section) => bySection[section]!.map((TtsPlanSentence s) => s.text),
    ),
  );
  final String rosterSystem = ttsRosterSystemPrompt(script);
  final String linesSystem = ttsCastLinesSystemPrompt(script);

  /// 截断的块拆半；拆不动（已到下限）抛 [kTtsCastFailureOutputLimit]。
  (TtsCastChunk, TtsCastChunk) splitTruncated(
    TtsCastChunk chunk,
    String where,
    TtsCastReply reply, {
    required int contextSentences,
  }) {
    final (TtsCastChunk, TtsCastChunk)? halves =
        chunk.sentences.length > kTtsCastSplitMinSentences
        ? splitTtsCastChunk(chunk, contextSentences: contextSentences)
        : null;
    if (halves == null) {
      throw TtsCastAnnotateFailure(
        kTtsCastFailureOutputLimit,
        '$where: ${chunk.sentences.length} sentences',
        reply.text.isEmpty ? null : reply.text,
      );
    }
    return halves;
  }

  /// 第一遍的一块：每次问都用最新角色表（拆开的后一半能看到前一半刚登记的人）。
  Future<void> rosterChunk(int section, TtsCastChunk chunk) async {
    if (isCancelled()) throw const TtsCastAnnotateFailure('cancelled');
    final List<TtsCastCharacter> roster = _orderedRoster(cast);
    final CastPromptRoster promptRoster = CastPromptRoster(
      roster: roster,
      substitutions: substitutions,
    );
    final TtsCastReply reply = await ask(
      rosterSystem,
      buildTtsRosterUserPrompt(
        chunk,
        roster: roster,
        promptRoster: promptRoster,
        substitutions: substitutions,
      ),
    );
    if (reply.truncated) {
      final (TtsCastChunk head, TtsCastChunk tail) = splitTruncated(
        chunk,
        'roster, section $section',
        reply,
        contextSentences: 0,
      );
      await rosterChunk(section, head);
      await rosterChunk(section, tail);
      return;
    }
    final TtsRosterParseResult? parsed = parseTtsRosterReply(
      reply.text,
      promptRoster: promptRoster,
    );
    final String? failure = ttsRosterReplyFailureReason(parsed);
    if (parsed == null || failure != null) {
      throw TtsCastAnnotateFailure(
        'bad_output',
        'roster, section $section: $failure',
        reply.text,
      );
    }
    applyTtsRosterOps(cast, parsed.ops);
  }

  onPhase?.call(kTtsCastPhaseRoster, 0, todo.length);
  for (int done = 0; done < todo.length; done++) {
    final int section = todo[done];
    for (final TtsCastChunk chunk in chunkTtsRosterSection(
      bySection[section]!,
    )) {
      await rosterChunk(section, chunk);
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

    // 第二遍的一块，结果并进 annotated。拆开时后一半的滚动上下文 = 进来的
    // recent 接上前一半刚归属的台词——与不拆时模型在同一份编号列表里看到的一致。
    Future<void> linesChunk(
      TtsCastChunk chunk,
      List<TtsCastRecentLine> recent,
    ) async {
      if (isCancelled()) throw const TtsCastAnnotateFailure('cancelled');
      final TtsCastReply reply = await ask(
        linesSystem,
        buildTtsCastLinesUserPrompt(
          chunk,
          roster: roster,
          promptRoster: promptRoster,
          recent: recent,
          substitutions: substitutions,
        ),
      );
      if (reply.truncated) {
        final (TtsCastChunk head, TtsCastChunk tail) = splitTruncated(
          chunk,
          'lines, section $section',
          reply,
          contextSentences: kTtsCastContextSentences,
        );
        await linesChunk(head, recent);
        await linesChunk(
          tail,
          _carryRecent(recent, ttsCastRecentDialogue(head, annotated)),
        );
        return;
      }
      final TtsCastParseResult? parsed = parseTtsCastReply(
        reply.text,
        chunk.sentences.length,
        speakers: index,
        promptRoster: promptRoster,
      );
      final String? failure = ttsCastReplyFailureReason(parsed);
      if (parsed == null || failure != null) {
        throw TtsCastAnnotateFailure(
          'bad_output',
          'lines, section $section: $failure',
          reply.text,
        );
      }
      annotated.addAll(ttsCastLinesForChunk(chunk, parsed.labels));
    }

    List<TtsCastRecentLine> recent = const <TtsCastRecentLine>[];
    for (final TtsCastChunk chunk in chunkTtsCastSection(bySection[section]!)) {
      await linesChunk(chunk, recent);
      recent = ttsCastRecentDialogue(chunk, annotated);
    }
    cast.mergeLlm(section, annotated);
    await save();
    onPhase?.call(kTtsCastPhaseLines, done + 1, todo.length);
    onProgress(done + 1, todo.length);
  }
}

/// 拆开重问时接续滚动上下文：[before] 后面接上 [fresh]，只留最后
/// [kTtsCastRecentDialogue] 句。
List<TtsCastRecentLine> _carryRecent(
  List<TtsCastRecentLine> before,
  List<TtsCastRecentLine> fresh,
) {
  final List<TtsCastRecentLine> all = <TtsCastRecentLine>[...before, ...fresh];
  return all.length <= kTtsCastRecentDialogue
      ? all
      : all.sublist(all.length - kTtsCastRecentDialogue);
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
