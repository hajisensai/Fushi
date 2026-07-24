import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/ocr/manga_ocr_service.dart';
// 真实现由并行 agent（生产者 B）编写；本 provider 是 UI 层拿服务单例的唯一入口。
// 本文件是整棵 UI 依赖图中**唯一**直接引用 [MangaOcrServiceImpl] 的地方——设置区 /
// 向导等 widget 一律经构造参数注入服务（测试注 fake），故它们与本文件解耦、不依赖 impl；
// 只有真实接线点（本文件 + 设置 schema + book 导入入口）在 impl 落地前 analyze 会报缺文件。
import 'package:hibiki/src/ocr/manga_ocr_service_impl.dart';

/// 无 Riverpod 场景（AppModel → 互联 host 代跑 OCR 接线）的服务工厂。与
/// [mangaOcrServiceProvider] 同源，保持「唯一直接引用 Impl 的文件」不变。
MangaOcrService createMangaOcrService() => MangaOcrServiceImpl();

/// 漫画整卷 OCR 服务的全局单例 provider。
///
/// 默认指向 [MangaOcrServiceImpl]（ONNX 流水线 + 模型下载管理）。widget 测试用
/// `mangaOcrServiceProvider.overrideWithValue(fakeService)` 覆盖，但本仓约定各 UI
/// widget 直接经构造参数收服务、不 `ref.read` 本 provider，故测试无需覆盖亦可编译。
final Provider<MangaOcrService> mangaOcrServiceProvider =
    Provider<MangaOcrService>((Ref ref) => createMangaOcrService());
