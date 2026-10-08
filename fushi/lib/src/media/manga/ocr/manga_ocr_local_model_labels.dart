import 'dart:io';

import 'package:fushi/utils.dart' show t;
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';

/// 本机 OCR 模型的显示名（设置区引擎下拉 / 「设置 › 存储」/ OCR 向导共用）。
String localModelLabel(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.baberu => t.manga_ocr_baberu_model,
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_model,
};

/// 本机模型的一句话取舍（体积 / 速度 / 硬件要求）。
String localModelDescription(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.baberu => t.manga_ocr_baberu_desc,
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_desc,
};

/// 本平台列得出的模型：Baberu 只在 Windows
/// （[MangaOcrLocalModel.availableOnAllPlatforms]）。
List<MangaOcrLocalModel> platformMangaOcrLocalModels() => <MangaOcrLocalModel>[
  for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
    if (Platform.isWindows || model.availableOnAllPlatforms) model,
];
