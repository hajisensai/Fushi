import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_job_registry.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_selected_service.dart';
// 真实现由并行 agent（生产者 B）编写；本 provider 是 UI 层拿服务单例的唯一入口。
// 本文件是整棵 UI 依赖图中**唯一**直接引用 [MangaOcrServiceImpl] 的地方——设置区 /
// 向导等 widget 一律经构造参数注入服务（测试注 fake），故它们与本文件解耦、不依赖 impl；
// 只有真实接线点（本文件 + 设置 schema + book 导入入口）在 impl 落地前 analyze 会报缺文件。
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';

/// 无 Riverpod 场景（AppModel → 互联 host 代跑 OCR 接线）的服务工厂。与
/// [mangaOcrServiceProvider] 同源，保持「唯一直接引用 Impl 的文件」不变。
MangaOcrService createMangaOcrService({
  MangaOcrLocalModel localModel = MangaOcrLocalModel.mangaOcr,
}) => MangaOcrServiceImpl(localModel: localModel);

/// Interconnect hosts keep this facade while new jobs follow model changes.
MangaOcrService createSelectedMangaOcrService(String Function() modelKey) =>
    SelectedMangaOcrService(
      () => createMangaOcrService(
        localModel: MangaOcrLocalModel.forPlatform(modelKey()),
      ),
    );

/// 漫画整卷 OCR 服务的全局单例 provider。
///
/// 默认指向 [MangaOcrServiceImpl]（ONNX 流水线 + 模型下载管理）。widget 测试用
/// `mangaOcrServiceProvider.overrideWithValue(fakeService)` 覆盖，但本仓约定各 UI
/// widget 直接经构造参数收服务、不 `ref.read` 本 provider，故测试无需覆盖亦可编译。
final Provider<MangaOcrService> mangaOcrServiceProvider =
    Provider<MangaOcrService>((Ref ref) {
      final String key = ref.watch(
        appProvider.select(
          (AppModel app) =>
              app.isInitialised ? app.mangaOcrLocalModel : 'manga_ocr',
        ),
      );
      return createMangaOcrService(
        localModel: MangaOcrLocalModel.forPlatform(key),
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
          );
        },
      );
      ref.listen<AppModel>(appProvider, (AppModel? previous, AppModel next) {
        registry.refreshConcurrencyLimit();
      });
      return registry;
    });
