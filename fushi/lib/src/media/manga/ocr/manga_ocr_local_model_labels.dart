import 'dart:io';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';

/// 本机 OCR 模型的显示名（设置区引擎下拉 / 「设置 › 存储」/ OCR 向导共用）。
String localModelLabel(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_model,
  MangaOcrLocalModel.ppOcrV6Medium => t.manga_ocr_ppocrv6_medium_model,
  MangaOcrLocalModel.ppOcrV5Korean => t.manga_ocr_ppocrv5_korean_model,
  MangaOcrLocalModel.charspotSmall => t.manga_ocr_charspot_small_model,
  MangaOcrLocalModel.charspotNano => t.manga_ocr_charspot_nano_model,
};

/// 本机模型的一句话取舍（语言 / 体积 / 速度 / 硬件要求 / 许可）。
String localModelDescription(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_desc,
  MangaOcrLocalModel.ppOcrV6Medium => t.manga_ocr_ppocrv6_medium_desc,
  MangaOcrLocalModel.ppOcrV5Korean => t.manga_ocr_ppocrv5_korean_desc,
  MangaOcrLocalModel.charspotSmall => t.manga_ocr_charspot_small_desc,
  MangaOcrLocalModel.charspotNano => t.manga_ocr_charspot_nano_desc,
};

/// 本平台列得出的模型：只给 Windows 的模型在别的平台不列
/// （[MangaOcrLocalModel.availableOnAllPlatforms]；目前五个模型五端都能跑）。
List<MangaOcrLocalModel> platformMangaOcrLocalModels() => <MangaOcrLocalModel>[
  for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
    if (Platform.isWindows || model.availableOnAllPlatforms) model,
];
