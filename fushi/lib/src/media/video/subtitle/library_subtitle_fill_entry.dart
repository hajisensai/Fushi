/// 整库补字幕的 app 装配入口：从 [AppModel] 取库、偏好、字幕服务、在线下载，并在这里解析
/// 内封图形轨 OCR 的引擎。
///
/// 与控制器（`library_subtitle_fill_controller.dart`）/ 端口实现（`library_subtitle_fill_host.dart`）/
/// 面板（`library_subtitle_fill_sheet.dart`）分开：那三处只收注入的依赖，自己不读 AppModel；只有这一处
/// 装配读。它们再 import AppModel 就会一起进 lib/ 的 import 大环
/// （`test/build/import_cycle_guard_test.dart`，2026-11-27 实测 626）。
library;

import 'package:fushi_engine/media/video/subtitle/library_subtitle_fill.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart'
    show MangaAiOcrContext;
import 'package:material_ui/material_ui.dart' show BuildContext;

import 'package:fushi/src/media/manga/manga_ocr_wizard_engines.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_stream_ocr.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart'
    show GraphicSubtitleOcrPrepare;
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service_entry.dart'
    show appVideoSubtitleService;
import 'package:fushi/src/media/video/subtitle/library_subtitle_fill_controller.dart';
import 'package:fushi/src/media/video/subtitle/library_subtitle_fill_host.dart';
import 'package:fushi/src/models/app_model.dart';

/// 面板与控制通道共用的单例（挂在 [AppModel] 生命周期上）。
final Expando<LibrarySubtitleFillController> _controllers =
    Expando<LibrarySubtitleFillController>('librarySubtitleFill');

/// UI 与 ctl 取控制器的唯一入口。
LibrarySubtitleFillController librarySubtitleFillController(
  AppModel appModel,
) => _controllers[appModel] ??= LibrarySubtitleFillController(
  database: () => appModel.database,
  createFill: () => LibrarySubtitleFill(
    database: appModel.database,
    host: AppLibrarySubtitleFillHost(
      prefs: appModel.prefsRepo,
      subtitles: appVideoSubtitleService(appModel),
      prepareGraphicOcr: (MangaAiOcrContext aiContext) =>
          _prepareGraphicOcr(appModel, aiContext),
    ),
    backfill: appModel.videoSubtitleBackfillService,
    seriesLanguage: appModel.seriesSubtitleLanguage,
  ),
);

/// 内封图形轨的离线 OCR 准备：引擎装配要 Provider 容器（[MangaOcrWizardEngines.resolve]），
/// 没有可用的 context（app 还没起完）时返回 null。去掉 AI 重读、Lens 上传一律拒——整库任务
/// 无人值守。
GraphicSubtitleOcrPrepare? _prepareGraphicOcr(
  AppModel appModel,
  MangaAiOcrContext aiContext,
) {
  final BuildContext? ctx = appModel.navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return null;
  final MangaOcrWizardEngines engines = MangaOcrWizardEngines.resolve(
    context: ctx,
    db: appModel.database,
  ).withoutAiRefinement();
  return (String dir) => prepareMangaStreamOcr(
    imageDirPath: dir,
    engines: engines,
    preference: MangaOcrEnginePreferenceKey.fromKey(
      appModel.mangaOcrEnginePreference,
    ),
    lensLanguage: appModel.mangaOcrLensLanguage,
    // 无人值守：不上传任何画面。
    confirmLensUpload: () async => false,
    aiContext: aiContext,
  );
}
