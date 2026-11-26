/// [AppVideoSubtitleService] 的 app 装配入口：从 [AppModel] 取库、设置与本机 OCR 模型。
///
/// 与服务本体（`app_video_subtitle_service.dart`）分开：服务只收注入的依赖，自己不读
/// AppModel；只有这一处装配读。服务本体再 import AppModel 就会把它连同只持服务的字幕生成
/// 面板 / 术语表页 / 网页档字幕生成一起拖回 lib/ 的 import 大环
/// （`test/build/import_cycle_guard_test.dart`，2026-11-26 实测 627）。
library;

import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/burned_in_subtitle_ocr.dart';
import 'package:fushi/src/models/app_model.dart';

/// UI 与 ctl 取服务的唯一入口（同一个库共用一个实例，任务表跨页面存活）。
AppVideoSubtitleService appVideoSubtitleService(AppModel appModel) =>
    AppVideoSubtitleService.shared(
      database: appModel.database,
      settings: PrefsVideoSubtitleSettings(appModel.prefsRepo),
      burnedInOcr: AppBurnedInSubtitleOcr(
        modelKey: () => appModel.prefsRepo.mangaOcrLocalModel,
      ),
    );
