/// LLM 标注说话人（多声优配音的选角）。
///
/// 逐章逐块请模型回台词行的说话人（分块 / 提示词 / 解析见 `tts_cast_prompt.dart`），
/// 一章标完并入选角表即落盘：中途取消或失败，已完成的章不丢。
library;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_prompt.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/models/app_model.dart';

/// 单块回复的输出上限：100 句全是台词时约 3k token，给推理模型的思考留余量。
const int _kAnnotateMaxTokens = 8192;

/// 标注失败（[code]：`no_ai_provider` / `ai_failed` / `bad_output` / `cancelled`）。
class TtsCastAnnotateFailure implements Exception {
  const TtsCastAnnotateFailure(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() =>
      'TtsCastAnnotateFailure($code${detail == null ? '' : ': $detail'})';
}

/// 逐章请 LLM 标注 [sections]（空 = 计划里的全部章）里每句的说话人，并入 [bookKey]
/// 的选角表并落盘；用户手改过的行保留。返回更新后的选角表。
Future<TtsCast> annotateTtsCast({
  required AppModel appModel,
  required String bookKey,
  required TtsBookPlan plan,
  Set<int> sections = const <int>{},
  bool skipAnnotated = true,
  required void Function(int done, int total) onProgress,
  required bool Function() isCancelled,
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
  try {
    onProgress(0, todo.length);
    for (int done = 0; done < todo.length; done++) {
      final int section = todo[done];
      final Map<String, TtsCastLine> annotated = <String, TtsCastLine>{};
      // 本章前几块新出现的名字也要带给后几块，否则同一人跨块会被写成两种名字。
      final List<String> known = <String>[
        for (final ({String speaker, int count}) s in cast.speakers())
          s.speaker,
      ];
      for (final TtsCastChunk chunk in chunkTtsCastSection(
        bySection[section]!,
      )) {
        if (isCancelled()) throw const TtsCastAnnotateFailure('cancelled');
        final String reply;
        try {
          reply = await client.complete(
            provider: provider,
            messages: <AiChatMessage>[
              const AiChatMessage.system(kTtsCastSystemPrompt),
              AiChatMessage.user(
                buildTtsCastUserPrompt(chunk, knownSpeakers: known),
              ),
            ],
            maxTokens: _kAnnotateMaxTokens,
          );
        } on AiChatFailure catch (e) {
          throw TtsCastAnnotateFailure('ai_failed', e.message);
        }
        final TtsCastParseResult? parsed = parseTtsCastReply(
          reply,
          chunk.sentences.length,
        );
        if (parsed == null ||
            (parsed.labels.isEmpty &&
                (parsed.rawCount > 0 || chunk.hasDialogue))) {
          throw TtsCastAnnotateFailure(
            'bad_output',
            'section $section: ${parsed == null ? 'no JSON array' : 'no usable labels'}',
          );
        }
        for (final TtsCastLabel label in parsed.labels) {
          if (!known.contains(label.speaker)) known.add(label.speaker);
        }
        annotated.addAll(ttsCastLinesForChunk(chunk, parsed.labels));
      }
      cast.mergeLlm(section, annotated);
      await store.save(bookKey, cast);
      onProgress(done + 1, todo.length);
    }
  } finally {
    client.close();
  }
  return cast;
}
