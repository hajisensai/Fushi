/// LLM 标注说话人（多声优配音的选角）。
///
/// 两遍（主循环见 `tts_cast_passes.dart`，分块 / 提示词 / 解析 / 角色表操作见
/// `tts_cast_prompt.dart`）：
/// 1. `roster`：逐章逐块抽角色表，每章并完即落盘；
/// 2. `lines`：逐章逐块按角色表归属台词，一章标完并入选角表即落盘。
/// 第一遍先把所有待标的章跑完，第二遍才开始——后面章节才揭晓的名字 / 别名也能
/// 用在前面章节的归属上。中途取消或失败，已落盘的角色表与已标完的章不丢；重跑时
/// 未标完的章会重做第一遍（并入是幂等的：同名补别名 / 空特征，不覆盖已有值）。
///
/// 系列：开标注前把系列里记住的角色并进本书角色表（同一个人在各卷用同一个名字），
/// 结束（含取消 / 失败）后把本书角色表学回系列，下一卷接着用。
///
/// 采样温度：[AiChatClient.complete] 不暴露 temperature（各协议默认值不同，推理
/// 模型还拒收这个字段），这里用服务端默认值；稳定性靠严格 JSON 约束 + 本地校验。
library;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_passes.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_cast_prompt.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';

export 'package:fushi/src/media/audiobook/tts/studio/tts_cast_passes.dart'
    show TtsCastAnnotateFailure, kTtsCastPhaseLines, kTtsCastPhaseRoster;

/// 单块回复的输出上限：100 句全是台词时约 4k token，给推理模型的思考留余量。
const int _kAnnotateMaxTokens = 8192;

/// 单块请求的整体时限：上限 [_kAnnotateMaxTokens] 按消费级显卡上本地模型约
/// 15 token/s 算要九分钟出头；默认的 90 秒在本地 14B 上几乎每块都超时，又被当成
/// 网络抖动整块重生成（BUG-5367）。云端模型几十秒就回，不受影响。
const Duration _kAnnotateRequestTimeout = Duration(minutes: 10);

/// 两遍请 LLM 标注 [sections]（空 = 计划里的全部章）里每句的说话人，并入 [bookKey]
/// 的选角表并落盘；用户手改过的行保留。返回更新后的选角表。
///
/// [onProgress] = 两遍都完成的章数 / 待标章数；[onPhase] = 当前阶段
/// （[kTtsCastPhaseRoster] / [kTtsCastPhaseLines]）内完成的章数 / 待标章数。
Future<TtsCast> annotateTtsCast({
  required AudioProductionHost appModel,
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
  final SeriesCastProfile? series = await loadTtsSeriesProfile(
    appModel,
    bookKey,
  );
  cast.series = series?.voices;
  seedTtsRosterFromSeries(cast, series);
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

  final AiChatClient client = AiChatClient(
    requestTimeout: _kAnnotateRequestTimeout,
  );
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
    await runTtsCastPasses(
      cast: cast,
      bySection: bySection,
      todo: todo,
      substitutions: series?.substitutions ?? const <CastTextSubstitution>[],
      ask: ask,
      save: () => store.save(bookKey, cast),
      onProgress: onProgress,
      isCancelled: isCancelled,
      onPhase: onPhase,
    );
  } finally {
    client.close();
    // 取消 / 失败时已抽到的角色也学回系列（角色表只增不减，并入幂等）。
    // 在最新的系列档案上学（串行读-改-写：同时开着的制作台改的声音不会被这份旧拷贝
    // 覆盖）。
    if (series != null && learnTtsRosterIntoSeries(cast, series)) {
      await seriesCastStoreFor(appModel).update(
        series.seriesKey,
        (SeriesCastProfile fresh) => learnTtsRosterIntoSeries(cast, fresh),
      );
    }
  }
  return cast;
}

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
