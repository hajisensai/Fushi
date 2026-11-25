/// 广播剧 / 动画音轨当漫画有声成品的应用层装配（设计 §9 末段）。流水线本体在引擎
/// （`manga_drama_track.dart`），这里只接三样宿主能力：
/// - **转录**：设备端 ASR，经唯一装配入口 [createAsrTranscriptionService]（混音素材
///   `mixedAudio`：广播剧 / 动画都带 BGM 与效果音）；算法在上游 `fushi-subtitles`，
///   本仓不改；
/// - **剪段**：ffmpeg（与生成端同一个 [runMangaFfmpeg] / [buildMangaClipArgs]）；
/// - **登记**：先停掉这卷的播放，再 [registerMangaAudio]——与合成成品同一套
///   `Audiobooks` / `AudioCues`，漫画卡与阅读器直接能播。
library;

import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart'
    show
        AsrAccelerationPreference,
        AsrAudioProfile,
        AsrLanguage,
        AsrRunningTranscription,
        AsrTranscribeEvent,
        AsrTranscribeFinishedEvent,
        AsrTranscribePausedEvent,
        AsrTranscribePlan,
        AsrTranscribeProgressEvent,
        AsrTranscribeResult,
        AsrTranscriptionService;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart'
    show FfmpegBackend, FfmpegRunResult, resolveFfmpegBackend;
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:fushi_engine/tts/manga_audio/manga_drama_track.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart'
    show TtsRenderCancelled, TtsRenderCancelToken;

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_render_mix.dart'
    show readMp4PresentationDurationMs;
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_backend.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/media/manga/audio/manga_audiobook_source.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 匹配单元取自哪里。
enum MangaDramaUnitSource {
  /// 演出稿里会发声的行（与当前 OCR 一致时才用：文字有修正、顺序是朗读顺序）。
  script,

  /// 没有可用演出稿：每个 OCR 块一个单元（不需要先做 AI 标注）。
  ocr,
}

/// 一卷做广播剧匹配所需的输入。
class MangaDramaVolume {
  const MangaDramaVolume({
    required this.bookKey,
    required this.pageCount,
    required this.units,
    required this.unitSource,
    required this.ocrSignature,
    required this.language,
  });

  final String bookKey;
  final int pageCount;
  final List<MangaDramaUnit> units;
  final MangaDramaUnitSource unitSource;
  final String ocrSignature;

  /// 转录语言（书的语言 → 转录偏好 → 日语）。
  final AsrLanguage language;
}

/// 选单元（纯函数）：演出稿与当前 OCR 一致且有会发声的行 → 用演出稿；否则用 OCR 块。
({List<MangaDramaUnit> units, MangaDramaUnitSource source})
chooseMangaDramaUnits(MangaAudioScript script, MokuroPayload payload) {
  final String signature = mangaPayloadOcrSignature(payload);
  if (script.audibleLines.isNotEmpty &&
      script.freshness(signature) == MangaScriptFreshness.upToDate) {
    return (
      units: mangaDramaUnitsFromScript(script, payload),
      source: MangaDramaUnitSource.script,
    );
  }
  return (
    units: mangaDramaUnitsFromOcr(payload),
    source: MangaDramaUnitSource.ocr,
  );
}

/// 设备端转录不可用（平台不支持 / 模型没下载）。
class MangaDramaAsrUnavailable implements Exception {
  const MangaDramaAsrUnavailable();

  @override
  String toString() => 'MangaDramaAsrUnavailable';
}

/// ffmpeg 不可用。
class MangaDramaFfmpegMissing implements Exception {
  const MangaDramaFfmpegMissing();

  @override
  String toString() => 'MangaDramaFfmpegMissing';
}

/// ffmpeg 剪段：输出与生成端同格式（44.1 kHz 单声道 AAC m4a），视频只取音轨。
class AppMangaDramaCutter implements MangaDramaCutter {
  AppMangaDramaCutter({required FfmpegBackend ffmpeg}) : _ffmpeg = ffmpeg;

  final FfmpegBackend _ffmpeg;

  @override
  Future<int> cut({
    required String sourcePath,
    required int startMs,
    required int? endMs,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  }) async {
    await runMangaFfmpeg(
      _ffmpeg,
      buildMangaClipArgs(
        sourcePath: sourcePath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
      ),
      outputPath: outputPath,
      cancel: cancel,
      source: 'MangaDrama.cut',
      log: (String source, String summary) =>
          ErrorLogService.instance.log(source, summary, StackTrace.current),
    );
    return await readMp4PresentationDurationMs(outputPath) ??
        (throw StateError('manga drama segment has no duration'));
  }
}

/// 设备端 ASR 转录一个文件 → 它的 cue。模型没准备好抛 [MangaDramaAsrUnavailable]；取消
/// 时请求暂停（进度留在识别任务目录，下次从断点接着跑）并抛 [TtsRenderCancelled]。
/// 识别任务不丢弃：同一份音频重做匹配时直接复用转录结果。
MangaDramaTranscriber appMangaDramaTranscriber({
  required AsrLanguage language,
  AsrTranscriptionService Function()? createService,
}) {
  AsrTranscriptionService? service;
  AsrTranscribePlan? plan;
  const AsrAccelerationPreference preference = AsrAccelerationPreference.auto;
  return (String audioPath, int fileIndex, TtsRenderCancelToken cancel) async {
    if (!isAsrSupported && createService == null) {
      throw const MangaDramaAsrUnavailable();
    }
    final AsrTranscriptionService s = service ??=
        (createService ??
        () => createAsrTranscriptionService(
          audioProfile: AsrAudioProfile.mixedAudio,
        ))();
    final AsrTranscribePlan p = plan ??= await s.plan(
      language: language,
      preference: preference,
    );
    if (!p.modelReady) throw const MangaDramaAsrUnavailable();
    cancel.throwIfCancelled();
    final AsrRunningTranscription running = await s.start(
      audioPaths: <String>[audioPath],
      language: language,
      variant: p.variant,
      preference: preference,
    );
    bool live = true;
    cancel.onCancel(() {
      if (live) running.requestPause();
    });
    AsrTranscribeResult? result;
    try {
      await for (final AsrTranscribeEvent event in running.run()) {
        switch (event) {
          case AsrTranscribeProgressEvent():
            break;
          case AsrTranscribePausedEvent():
            throw const TtsRenderCancelled();
          case AsrTranscribeFinishedEvent(
            result: final AsrTranscribeResult done,
          ):
            result = done;
        }
      }
    } finally {
      live = false;
      await running.dispose();
    }
    final AsrTranscribeResult done =
        result ?? (throw StateError('ASR ended without a result'));
    final List<AudioCue> cues = await SrtParser.parse(
      srtFile: File(done.srtPath),
      bookKey: '',
    );
    return <MangaDramaCue>[
      for (final AudioCue c in cues)
        MangaDramaCue(
          fileIndex: fileIndex,
          startMs: c.startMs,
          endMs: c.endMs,
          text: c.text,
        ),
    ];
  };
}

/// 读写入口（生产用 `AppModel`）。
class MangaDramaTrackService {
  MangaDramaTrackService(
    this.appModel, {
    required MangaBookTitleResolver bookTitle,
  }) : _source = MangaAudiobookSourceService(appModel, bookTitle: bookTitle);

  final AudioProductionHost appModel;
  final MangaAudiobookSourceService _source;

  /// 本卷的匹配输入；本地卷没有可用 OCR（在线作品、还没识别、`manga.json` 坏了）
  /// 返回 null。
  Future<MangaDramaVolume?> loadVolume(String bookKey) async {
    final MokuroPayload? payload = await _source.loadPayload(bookKey);
    if (payload == null || payload.images.isEmpty) return null;
    final MangaAudioScript script = await _source.loadScript(bookKey);
    final ({List<MangaDramaUnit> units, MangaDramaUnitSource source}) chosen =
        chooseMangaDramaUnits(script, payload);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    return MangaDramaVolume(
      bookKey: bookKey,
      pageCount: payload.images.length,
      units: chosen.units,
      unitSource: chosen.source,
      ocrSignature: mangaPayloadOcrSignature(payload),
      language:
          AsrLanguage.fromBookLanguage(row?.language) ??
          AsrLanguage.fromTag(appModel.prefsRepo.asrTranscribeLanguage) ??
          AsrLanguage.japanese,
    );
  }

  /// 跑整条流水线并登记成这卷的有声成品（替换已有的合成成品登记；合成成品的文件
  /// 不动，重新生成或导入即可换回）。
  Future<MangaDramaOutcome> run({
    required MangaDramaVolume volume,
    required List<String> audioPaths,
    required TtsRenderCancelToken cancel,
    MangaDramaProgress? onProgress,
  }) async {
    final FfmpegBackend ffmpeg = resolveFfmpegBackend();
    final FfmpegRunResult probe = await ffmpeg.runQuery(const <String>[
      '-hide_banner',
      '-version',
    ], const Duration(seconds: 20));
    if (!probe.isSuccess) throw const MangaDramaFfmpegMissing();
    final File manifestFile = mangaDramaManifestFile(appModel, volume.bookKey);
    // 段文件会被原地替换：先停掉这卷的播放（Windows 上被占用的文件换不掉）。
    await appModel.audiobookSession.stopIfPlayingAny(<String>[volume.bookKey]);
    final MangaDramaOutcome outcome = await runMangaDramaTrack(
      units: volume.units,
      pageCount: volume.pageCount,
      ocrSignature: volume.ocrSignature,
      audioPaths: audioPaths,
      transcribe: appMangaDramaTranscriber(language: volume.language),
      cutter: AppMangaDramaCutter(ffmpeg: ffmpeg),
      manifestFile: manifestFile,
      cancel: cancel,
      onProgress: onProgress,
    );
    cancel.throwIfCancelled();
    await appModel.audiobookSession.stopIfPlayingAny(<String>[volume.bookKey]);
    await registerMangaAudio(
      appModel.database,
      bookKey: volume.bookKey,
      manifestFile: manifestFile,
      manifest: outcome.manifest,
    );
    return outcome;
  }
}
