import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_model_downloads.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi/src/media/manga/manga_ocr_service_factory.dart';

export 'package:fushi/src/media/manga/manga_ocr_service_factory.dart'
    show
        createMangaOcrHostModelServices,
        createMangaOcrService,
        createSelectedMangaOcrService;

/// 漫画整卷 OCR 服务的全局单例 provider。
///
/// 默认指向 `MangaOcrServiceImpl`（经 [createMangaOcrService]；ONNX 流水线 + 模型下载管理）。widget 测试用
/// `mangaOcrServiceProvider.overrideWithValue(fakeService)` 覆盖，但本仓约定各 UI
/// widget 直接经构造参数收服务、不 `ref.read` 本 provider，故测试无需覆盖亦可编译。
final Provider<MangaOcrService> mangaOcrServiceProvider =
    Provider<MangaOcrService>((Ref ref) {
      final String key = ref.watch(
        appProvider.select(
          (AppModel app) => app.isInitialised
              ? app.mangaOcrLocalModel
              : kDefaultMangaOcrLocalModel.key,
        ),
      );
      return createMangaOcrService(
        localModel: MangaOcrLocalModel.forPlatform(key),
        // 开关现读：设置里改了不必重建服务，下一次识别就按新值组装识别器与缓存签名。
        ignoreFurigana: () {
          final AppModel app = ref.read(appProvider);
          return app.isInitialised && app.mangaOcrIgnoreFurigana;
        },
      );
    });

/// 整卷 OCR 任务注册表的全局单例 provider（BUG-2449）。
///
/// 任务所有权在这里而不在阅读页 State：页面订阅的是注册表转发的广播流，退出页面
/// 只是不再观察，任务照跑；重进同书按 `bookKey` 接回进度。测试用
/// `mangaOcrJobRegistryProvider.overrideWithValue(registry)` 注入预置任务。
///
/// 跨书并发上限按设备自适应（[resolveMangaOcrJobConcurrency]），每次排到时现读，
/// 低内存模式开关即时生效；AppModel 初始化前按未开低内存模式算。
final Provider<MangaOcrJobRegistry> mangaOcrJobRegistryProvider =
    Provider<MangaOcrJobRegistry>((Ref ref) {
      final MangaOcrJobRegistry registry = MangaOcrJobRegistry(
        maxConcurrentJobs: () {
          final AppModel appModel = ref.read(appProvider);
          return resolveMangaOcrJobConcurrency(
            isMobile: isMobilePlatform,
            lowMemoryMode: appModel.isInitialised && appModel.lowMemoryMode,
            processors: Platform.numberOfProcessors,
            requestedTasks: appModel.isInitialised
                ? appModel.mangaOcrParallelTasks
                : 0,
            maxTasks: hostMangaOcrMaxParallelTasks(),
          );
        },
      );
      ref.listen<AppModel>(appProvider, (AppModel? previous, AppModel next) {
        registry.refreshConcurrencyLimit();
      });
      return registry;
    });

/// 本机 OCR 模型后台下载登记表的全局单例（设置区与「设置 › 存储」共用）。
///
/// 下载订阅归这里而不归页面：离开设置页下载照跑，结束时在此弹全局提示。
final Provider<MangaOcrModelDownloads> mangaOcrModelDownloadsProvider =
    Provider<MangaOcrModelDownloads>((Ref ref) {
      final MangaOcrModelDownloads downloads = MangaOcrModelDownloads(
        onFinished: (MangaOcrLocalModel model, {required bool failed}) {
          FushiToast.show(
            msg: failed
                ? t.manga_ocr_download_failed
                : t.manga_ocr_download_done,
            severity: failed ? ToastSeverity.error : ToastSeverity.success,
          );
        },
      );
      ref.onDispose(downloads.dispose);
      return downloads;
    });
