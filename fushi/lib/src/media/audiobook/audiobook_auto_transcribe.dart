/// 有声书「下载后自动转录入库」的 app 侧装配：
///
/// - [AppAudiobookTranscriber]：引擎队列的转录端口，接设备端 ASR（与转录弹层
///   同一个服务工厂 `createAsrTranscriptionService`）。缺模型时自动下载——用户
///   已经在下一本几百 MB 的有声书，模型是同一次自动化的必要部分。
/// - [routeTranscribeAudiobookPlan]：导入执行器的 `transcribeAudiobook` 端口。
///   先查有声书素材库（有现成字幕就直接入库，不白跑几个小时转录），配不到
///   再排进转录队列；开关关掉或本机没有 ASR 时与改前一样以
///   `audiobookMissingSubtitle` 挡下。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart'
    show DiscoveryImportOutcome;
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart'
    show audiobookTitleForAudioPaths, discoveryImportFileName;
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_service.dart';

/// 转录语言：书有正文（EPUB `dc:language`）跟书走；否则用「上次转录语言」偏好；
/// 都认不出时日语（与转录弹层同一条回退链）。
Future<AsrLanguage> resolveAutoTranscribeLanguage({
  required String? contentPath,
  required String preferredTag,
}) async {
  if (contentPath != null && contentPath.toLowerCase().endsWith('.epub')) {
    try {
      final String? language = await Isolate.run(
        () => EpubParser.readLanguageSync(contentPath),
      );
      final AsrLanguage? fromBook = AsrLanguage.fromBookLanguage(language);
      if (fromBook != null) return fromBook;
    } catch (e, stack) {
      // 读不到书的语言只是少一个提示，不该挡住转录：按偏好继续，但留日志。
      engineLog.log('resolveAutoTranscribeLanguage', e, stack);
    }
  }
  return AsrLanguage.fromTag(preferredTag) ?? AsrLanguage.japanese;
}

class AppAudiobookTranscriber implements AudiobookTranscriber {
  AppAudiobookTranscriber({
    required AsrTranscriptionService Function() serviceFactory,
    required String Function() preferredLanguageTag,
    AsrAccelerationPreference preference = AsrAccelerationPreference.auto,
  }) : _serviceFactory = serviceFactory,
       _preferredLanguageTag = preferredLanguageTag,
       _preference = preference;

  final AsrTranscriptionService Function() _serviceFactory;
  final String Function() _preferredLanguageTag;
  final AsrAccelerationPreference _preference;

  @override
  Future<String> transcribe(
    AudiobookTranscribeJob job, {
    required void Function(AudiobookTranscribeJobPhase phase, double? progress)
    onProgress,
    required AudiobookTranscribeCancelToken cancel,
  }) async {
    final AsrLanguage language = await resolveAutoTranscribeLanguage(
      contentPath: job.contentPath,
      preferredTag: _preferredLanguageTag(),
    );
    final AsrTranscriptionService service = _serviceFactory();
    // 同一组音频 + 语言之前已经转完（上次入库失败后重试）：直接用。
    final String? finished = await service.finishedSrtPath(
      job.audioPaths,
      language,
    );
    if (finished != null) return finished;

    AsrTranscribePlan plan = await service.plan(
      language: language,
      preference: _preference,
    );
    if (!plan.modelReady) {
      await _downloadModel(service, plan, onProgress, cancel);
      plan = await service.plan(language: language, preference: _preference);
      if (!plan.modelReady) {
        throw StateError(
          'ASR model for ${language.tag} is still incomplete after download',
        );
      }
    }
    if (cancel.isCancelled) throw const AudiobookTranscribeCancelled();

    onProgress(AudiobookTranscribeJobPhase.transcribing, 0);
    final AsrRunningTranscription running = await service.start(
      audioPaths: job.audioPaths,
      language: language,
      variant: plan.variant,
      preference: _preference,
    );
    cancel.onCancel(running.requestPause);
    AsrTranscribeResult? result;
    try {
      await for (final AsrTranscribeEvent event in running.run()) {
        switch (event) {
          case AsrTranscribeProgressEvent(
            progress: final AsrTranscribeProgress progress,
          ):
            onProgress(
              AudiobookTranscribeJobPhase.transcribing,
              progress.fraction,
            );
          case AsrTranscribePausedEvent():
            // 只有取消会请求暂停；进度已落在转录服务自己的任务目录里，重试
            // 会从断点接着跑。
            throw const AudiobookTranscribeCancelled();
          case AsrTranscribeFinishedEvent(
            result: final AsrTranscribeResult done,
          ):
            result = done;
        }
      }
    } finally {
      await running.dispose();
    }
    final AsrTranscribeResult done =
        result ??
        (throw StateError('ASR transcription ended without a result'));
    if (done.cueCount == 0) {
      // 一句都没识别出来（静音 / 语言选错 / 非人声）：落一本空书只会让用户
      // 以为导入成功了。如实失败。
      throw StateError('ASR recognized no speech (language ${language.tag})');
    }
    return done.srtPath;
  }

  Future<void> _downloadModel(
    AsrTranscriptionService service,
    AsrTranscribePlan plan,
    void Function(AudiobookTranscribeJobPhase, double?) onProgress,
    AudiobookTranscribeCancelToken cancel,
  ) async {
    final int total = plan.totalModelBytes;
    int completedBytes = plan.obtainedModelBytes;
    String lastFile = '';
    int lastFileTotal = 0;
    onProgress(
      AudiobookTranscribeJobPhase.downloadingModel,
      total > 0 ? completedBytes / total : null,
    );
    final Completer<void> done = Completer<void>();
    late final StreamSubscription<ModelDownloadEvent> sub;
    sub = service
        .downloadModel(language: plan.language, variant: plan.variant)
        .listen(
          (ModelDownloadEvent e) {
            // 逐文件事件：把「之前文件」的字节累计起来算总进度（同转录弹层）。
            if (e.fileName != lastFile) {
              completedBytes += lastFileTotal;
              lastFile = e.fileName;
              lastFileTotal = e.totalBytes;
            }
            onProgress(
              AudiobookTranscribeJobPhase.downloadingModel,
              total > 0
                  ? ((completedBytes + e.receivedBytes) / total).clamp(0, 1)
                  : null,
            );
          },
          onError: (Object e, StackTrace stack) {
            if (!done.isCompleted) done.completeError(e, stack);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    cancel.onCancel(() {
      unawaited(sub.cancel());
      if (!done.isCompleted) {
        done.completeError(const AudiobookTranscribeCancelled());
      }
    });
    await done.future;
  }
}

/// 导入执行器 `transcribeAudiobook` 端口的实现（依赖经参数注入，可单测）。
///
/// - [autoTranscribeEnabled]：开关开 **且** 本机支持 ASR。
/// - [contentAlreadyInLibrary]：正文会不会撞上库里的同名书。撞上就以
///   `audiobookBookAlreadyInLibrary` 挡下（同齐料包的既有口径，UI 告诉用户去
///   那本书里手动导入有声书），而不是先跑几个小时转录再在入库那一步失败。
/// - [matchMaterials]：按音频 + 书名查素材库。
/// - [importNow]：素材库配齐时立刻入库（对齐或独立字幕书）。
/// - [enqueue]：排进转录后入库队列。
Future<DiscoveryImportOutcome> routeTranscribeAudiobookPlan(
  TranscribeAudiobookPlan plan, {
  required bool autoTranscribeEnabled,
  required Future<bool> Function(String contentPath) contentAlreadyInLibrary,
  required Future<AudiobookMaterialMatch> Function(
    List<String> audioPaths,
    String title,
  )
  matchMaterials,
  required Future<String?> Function(DiscoveryImportPlan plan) importNow,
  required Future<AudiobookTranscribeJob> Function({
    required List<String> audioPaths,
    String? contentPath,
    required String title,
  })
  enqueue,
}) async {
  final String title = audiobookTitleForAudioPaths(plan.audioPaths);
  final AudiobookMaterialMatch match = await matchMaterials(
    plan.audioPaths,
    title,
  );
  // 正文只认身份键精确命中的：标题猜出来的弱匹配要让用户确认，后台自动链路
  // 没有地方提示「这是猜的」（同 planAudiobookFromMaterials 的纪律）。
  final String? content =
      plan.contentPath ?? (match.contentIsWeakMatch ? null : match.contentPath);
  if (content != null && await contentAlreadyInLibrary(content)) {
    throw DiscoveryImportBlockedException(
      DiscoveryImportBlocker.audiobookBookAlreadyInLibrary,
      discoveryImportFileName(content),
    );
  }
  final String? subtitle = match.subtitleIsWeakMatch
      ? null
      : match.subtitlePath;
  if (subtitle != null) {
    final String? key = await importNow(
      content != null
          ? AlignAudiobookPlan(
              contentPath: content,
              subtitlePath: subtitle,
              audioPaths: plan.audioPaths,
            )
          : SubtitleAudiobookPlan(
              subtitlePath: subtitle,
              audioPaths: plan.audioPaths,
            ),
    );
    return DiscoveryImportOutcome(
      importedCount: key == null ? 0 : 1,
      summary: key,
    );
  }
  if (!autoTranscribeEnabled) {
    throw const DiscoveryImportBlockedException(
      DiscoveryImportBlocker.audiobookMissingSubtitle,
    );
  }
  final AudiobookTranscribeJob job = await enqueue(
    audioPaths: plan.audioPaths,
    contentPath: content,
    title: title,
  );
  return DiscoveryImportOutcome(summary: job.title, deferred: true);
}

/// 按音频文件给素材库配字幕/正文（下载任务的 externalId 拿不到时，身份键取
/// 音频文件名里的键，同浏览页「配对」入口的兜底）。素材库没配时返回空匹配。
Future<AudiobookMaterialMatch> matchAudiobookMaterialsForAudio(
  AudiobookMaterialService service,
  List<String> audioPaths,
  String title,
) async {
  final AudiobookMaterialScan scan = await service.scan();
  if (scan.index.isEmpty) return const AudiobookMaterialMatch();
  String? key;
  for (final String path in audioPaths) {
    key = audiobookKeyFromAudioPath(path);
    if (key != null) break;
  }
  return matchAudiobookMaterial(scan.index, key: key, title: title);
}
