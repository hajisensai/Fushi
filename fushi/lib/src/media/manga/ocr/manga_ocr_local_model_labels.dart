import 'dart:io';

import 'package:fushi/utils.dart' show t;
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';

/// 本机 OCR 模型的显示名（设置区引擎下拉 / 「设置 › 存储」/ OCR 向导共用）。
String localModelLabel(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_model,
};

/// 本机模型的一句话取舍（体积 / 速度 / 硬件要求）。
String localModelDescription(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_desc,
};

/// 本平台列得出的模型：只给 Windows 的模型在别的平台不列
/// （[MangaOcrLocalModel.availableOnAllPlatforms]；目前五端都只有逐列 CTC）。
List<MangaOcrLocalModel> platformMangaOcrLocalModels() => <MangaOcrLocalModel>[
  for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
    if (Platform.isWindows || model.availableOnAllPlatforms) model,
];
