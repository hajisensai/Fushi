/// 整库补字幕（`library_subtitle_fill.dart`）在 app 侧的三个端口：本地 ASR 生成、
/// 内封图形轨离线 OCR、按 ASR 稿逐句重定时。与设计系统无关（无 UI）。
///
/// 三条都不发 AI 请求：生成关校对；OCR 去掉 AI 重读（[MangaOcrWizardEngines.withoutAiRefinement]），
/// 也不弹任何确认框（Lens 上传一律拒）——整库任务无人值守，用户拍板「不用 API key」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/library_subtitle_fill.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart'
    show SubtitleSource, loadCuesForSource;
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart'
    show MangaAiOcrContext, MangaAiOcrSource;
import 'package:material_ui/material_ui.dart' show BuildContext;
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_track_ocr.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle_retiming_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// [LibrarySubtitleFillHost] 的生产实现。
class AppLibrarySubtitleFillHost implements LibrarySubtitleFillHost {
  AppLibrarySubtitleFillHost({
    required this.appModel,
    required this.subtitles,
    required this.context,
  });

  final AppModel appModel;
  final AppVideoSubtitleService subtitles;

  /// OCR 引擎装配要 Provider 容器（[MangaOcrWizardEngines.resolve]）；没有可用的
  /// context（app 还没起完）时 OCR 这档报不可用，编排层往下走。
  final BuildContext? Function() context;

  // ── 生成 ───────────────────────────────────────────────────────────────

  @override
  Future<SubtitleFillProduct> generate(
    SubtitleFillItem item,
    String language,
    SubtitleCancelToken cancel,
  ) async {
    if (!isAsrSupported) {
      throw const SubtitleFillStepFailure(
        'this build has no on-device speech recognition',
      );
    }
    final VideoSubtitleLanguage? asrLanguage = VideoSubtitleLanguage.fromTag(
      language,
    );
    if (asrLanguage == null) {
      throw SubtitleFillStepFailure(
        'on-device recognition only supports '
        '${VideoSubtitleLanguage.values.map((VideoSubtitleLanguage l) => l.tag).join(' / ')}',
      );
    }
    final AppVideoSubtitleTarget target;
    try {
      target = await subtitles.resolveBook(item.bookUid);
    } on AppVideoSubtitleTargetNotFound catch (e) {
      throw SubtitleFillStepFailure('no ${e.what}');
    }
    if (target.episodes.isEmpty) {
      throw const SubtitleFillStepFailure('no local media to transcribe');
    }
    final AppVideoSubtitleJob job;
    try {
      job = subtitles.start(
        target,
        AppVideoSubtitleOptions(
          language: asrLanguage,
          segmenter: appModel.prefsRepo.videoSubtitleSegmenter,
          mossBackend: appModel.prefsRepo.videoSubtitleMossBackend,
        ),
      );
    } on AppVideoSubtitleStartRefused catch (refused) {
      throw SubtitleFillStepFailure(
        'subtitle generation refused: ${refused.problem.name}',
      );
    }
    cancel.onCancel(job.cancel);
    await job.done;
    switch (job.status) {
      case AppVideoSubtitleJobStatus.succeeded:
        break;
      case AppVideoSubtitleJobStatus.cancelled:
        throw const SubtitlePipelineCancelled();
      case AppVideoSubtitleJobStatus.running ||
          AppVideoSubtitleJobStatus.pausedAiFailure ||
          AppVideoSubtitleJobStatus.glossaryInvalid ||
          AppVideoSubtitleJobStatus.failed:
        throw SubtitleFillStepFailure(job.errorMessage ?? job.status.name);
    }
    final String? output = job.result?.episodes
        .map((e) => e.outputPath)
        .whereType<String>()
        .firstOrNull;
    if (output == null) {
      throw const SubtitleFillStepFailure('recognition produced no subtitle');
    }
    return SubtitleFillProduct(
      path: output,
      registered: job.registeredBookUids.contains(item.bookUid),
    );
  }

  // ── 内封图形轨 OCR ─────────────────────────────────────────────────────

  @override
  Future<SubtitleFillProduct> ocrGraphicTrack(
    SubtitleFillItem item,
    int trackIndex,
    String language,
    SubtitleCancelToken cancel,
  ) async {
    final BuildContext? ctx = context();
    if (ctx == null || !ctx.mounted) {
      throw const SubtitleFillStepFailure('OCR engines are not ready');
    }
    final MangaOcrWizardEngines engines = MangaOcrWizardEngines.resolve(
      context: ctx,
      db: appModel.database,
    ).withoutAiRefinement();
    final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
      prepare: (String dir) => prepareMangaStreamOcr(
        imageDirPath: dir,
        engines: engines,
        preference: MangaOcrEnginePreferenceKey.fromKey(
          appModel.mangaOcrEnginePreference,
        ),
        lensLanguage: appModel.mangaOcrLensLanguage,
        // 无人值守：不上传任何画面。
        confirmLensUpload: () async => false,
        aiContext: MangaAiOcrContext(
          source: MangaAiOcrSource.subtitle,
          title: item.title,
          language: language,
        ),
      ),
    );
    final Directory work = await Directory.systemTemp.createTemp(
      'fushi_fill_graphic_sub_',
    );
    final Completer<void> stop = Completer<void>();
    cancel.onCancel(() {
      if (!stop.isCompleted) stop.complete();
    });
    try {
      await session.resolveEngine();
      final String payload = p.join(work.path, 'track.bin');
      final bool extracted = await extractGraphicSubtitleTrack(
        input: GraphicSubtitleInput.local(item.videoPath),
        streamIndex: trackIndex,
        outputPath: payload,
        cancel: stop.future,
      );
      throwIfSubtitleCancelled(cancel);
      if (!extracted) {
        throw const SubtitleFillStepFailure('graphic track extraction failed');
      }
      final List<GraphicSubtitleTextCue>? texts =
          await recognizeGraphicSubtitleCuesLive(
            snapshot: () =>
                readGraphicSubtitleTrackInBackground(payload, complete: true),
            sourceComplete: () => true,
            sourceDone: Future<void>.value(),
            session: session,
            positionMs: () => 0,
            isCancelled: () => cancel.isCancelled,
          );
      throwIfSubtitleCancelled(cancel);
      if (texts == null) throw const SubtitlePipelineCancelled();
      final String srt = buildGraphicSubtitleSrt(texts);
      if (srt.isEmpty) {
        throw const SubtitleFillStepFailure('OCR recognized no text');
      }
      final Directory dir = await AppPaths.videoSubtitlesDirectory();
      await dir.create(recursive: true);
      final String key = sha256
          .convert(utf8.encode('${item.bookUid}|${item.videoPath}'))
          .toString()
          .substring(0, 12);
      final File out = File(
        p.join(dir.path, 'graphic-ocr-$key-s$trackIndex.$language.srt'),
      );
      await out.writeAsString(srt, flush: true);
      return SubtitleFillProduct(path: out.path);
    } on GraphicSubtitleOcrUnavailable catch (e) {
      throw SubtitleFillStepFailure('OCR unavailable: ${e.reason.name}');
    } finally {
      if (!stop.isCompleted) stop.complete();
      await session.close();
      try {
        await work.delete(recursive: true);
      } on FileSystemException {
        // 临时目录，删不掉留给系统清理。
      }
    }
  }

  // ── 重定时 ─────────────────────────────────────────────────────────────

  @override
  Future<SubtitleFillRetimed> retime(
    SubtitleFillItem item,
    String subtitlePath,
    String referenceSrtPath,
    SubtitleCancelToken cancel,
  ) async {
    final List<AudioCue> cues = await loadCuesForSource(
      SubtitleSource.external(
        externalPath: subtitlePath,
        label: p.basename(subtitlePath),
      ),
      item.videoPath,
      item.bookUid,
    );
    if (cues.isEmpty) {
      throw const SubtitleFillStepFailure('downloaded subtitle has no lines');
    }
    throwIfSubtitleCancelled(cancel);
    final RetimedSubtitleFile? retimed = await retimeVideoSubtitleToFile(
      subtitleCues: cues,
      transcriptSrtPath: referenceSrtPath,
      outputDirectory: Directory(p.dirname(subtitlePath)),
      baseName: p.basename(subtitlePath),
    );
    if (retimed == null) {
      throw const SubtitleFillStepFailure('retiming produced nothing');
    }
    final ({int matched, int total, int percent, int medianShiftMs}) summary =
        retimedSubtitleSummary(retimed);
    return SubtitleFillRetimed(
      path: retimed.path,
      matchPercent: summary.percent,
      medianShiftMs: summary.medianShiftMs,
    );
  }
}
