/// 转录弹层里两条走 AI 提供商的路的 app 装配：云端转录服务与转录稿 AI 校对。
///
/// 提供商一律按「功能指派」现取（`PreferencesRepository.resolveAiFeatureProvider`），
/// 不在弹层打开时固化：用户开着弹层去设置里换了提供商，下一次点击就用新的。key
/// 与提供商配置的存储完全沿用 AI 模块（本文件不碰 key，也不写日志）。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/asr/asr_transcript_proofreader.dart';
import 'package:fushi_engine/asr/cloud_whisper_transcription_service.dart';
import 'package:fushi_engine/asr/fushi_asr_ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';

import 'package:fushi/src/models/preferences_repository.dart';

/// 弹层与「AI 校对」之间的窄接口（widget 测试注入 fake）。
class AsrProofreadHost {
  const AsrProofreadHost({required this.providerName, required this.run});

  /// 当前指派给「字幕校对」的提供商显示名；null = 没指派 / 没配全（按钮仍显示，
  /// 点了说清去哪里配）。
  final String? Function() providerName;

  /// 校对 [srtPath]（任务目录里的 `transcript.srt`），原稿备份、行数与时间轴不变
  /// 的约束见 [proofreadAsrTranscriptFile]。请求失败抛 [SubtitleAiRequestFailure]。
  final Future<AsrTranscriptProofreadFileOutcome> Function({
    required String srtPath,
    required String languageTag,
    required SubtitleCancelToken cancel,
    void Function(int doneBatches, int totalBatches)? onProgress,
  })
  run;
}

/// 云端转录服务的 app 装配：提供商取「云端语音转录」指派，ffmpeg 走本仓后端。
CloudWhisperTranscriptionService createAppCloudTranscriptionService(
  PreferencesRepository prefs,
) => CloudWhisperTranscriptionService(
  resolveProvider: () =>
      prefs.resolveAiFeatureProvider(AiFeature.cloudTranscription),
  ffmpeg: const FushiAsrFfmpegBackend(),
);

/// 转录稿 AI 校对的 app 装配：提供商取「字幕校对」指派（与视频日语字幕校对同一
/// 指派，用户只配一处）。
AsrProofreadHost appAsrProofreadHost(PreferencesRepository prefs) =>
    AsrProofreadHost(
      providerName: () => prefs
          .resolveAiFeatureProvider(AiFeature.subtitleProofread)
          ?.displayName,
      run:
          ({
            required String srtPath,
            required String languageTag,
            required SubtitleCancelToken cancel,
            void Function(int doneBatches, int totalBatches)? onProgress,
          }) async {
            final AiProviderConfig? provider = prefs.resolveAiFeatureProvider(
              AiFeature.subtitleProofread,
            );
            if (provider == null) {
              throw const SubtitleAiRequestFailure(kSubtitleAiNotConfigured);
            }
            final AiChatClient client = AiChatClient();
            cancel.onCancel(client.close);
            try {
              return await proofreadAsrTranscriptFile(
                srtPath: srtPath,
                proofreader: AsrTranscriptProofreader(
                  completer: AiChatTextCompleter(
                    client: client,
                    provider: provider,
                  ),
                  languageTag: languageTag,
                  concurrency: provider.batchConcurrency,
                  // 只有批序号与脱敏原因码（见 AsrTranscriptProofreader.log），
                  // 不含回复原文与 key。
                  log: (String message) =>
                      debugPrint('[Fushi] ASR proofread: $message'),
                ),
                cancel: cancel,
                onProgress: onProgress,
              );
            } finally {
              client.close();
            }
          },
    );
