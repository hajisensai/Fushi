// 漫画 OCR 服务工厂：整棵 UI 依赖图中**唯一**直接引用 [MangaOcrServiceImpl] 的地方——设置区 /
// 向导等 widget 一律经构造参数注入服务（测试注 fake），故它们与本文件解耦、不依赖 impl。
//
// 与 Riverpod 接线（`manga_ocr_provider.dart`，读 AppModel）分开：视频硬字幕 OCR
// （`burned_in_subtitle_ocr.dart`）等只要「按模型建一份服务」的件 import 本文件，不被拖进
// lib/ 的 import 大环（`test/build/import_cycle_guard_test.dart`）。provider 文件原样 re-export。
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_selected_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';

/// 无 Riverpod 场景（AppModel → 互联 host 代跑 OCR 接线）的服务工厂。与
/// `mangaOcrServiceProvider`（`manga_ocr_provider.dart`）同源，保持「唯一直接引用 Impl 的文件」不变。
///
/// [ignoreFurigana]：「OCR 忽略振假名」开关的现读入口（每次开跑调用）；不传 = 关。
MangaOcrService createMangaOcrService({
  MangaOcrLocalModel localModel = kDefaultMangaOcrLocalModel,
  bool Function()? ignoreFurigana,
}) =>
    MangaOcrServiceImpl(localModel: localModel, ignoreFurigana: ignoreFurigana);

/// Interconnect hosts keep this facade while new jobs follow model changes.
MangaOcrService createSelectedMangaOcrService(String Function() modelKey) =>
    SelectedMangaOcrService(
      () => createMangaOcrService(
        localModel: MangaOcrLocalModel.forPlatform(modelKey()),
      ),
    );

/// 互联 host 给对端点名的模型表：本平台列得出的每个本机模型一份服务。用户导入的
/// 自定义槽不列：那份权重只在这台设备上，对端点名它没有意义。
Map<String, MangaOcrService> createMangaOcrHostModelServices() =>
    <String, MangaOcrService>{
      for (final MangaOcrLocalModel model in MangaOcrLocalModel.builtInValues)
        if (MangaOcrLocalModel.forPlatform(model.key) == model)
          model.key: createMangaOcrService(localModel: model),
    };
