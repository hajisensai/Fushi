import 'dart:io';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi_engine/ocr/manga_ocr_custom_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';

/// 本机 OCR 模型的显示名（设置区引擎下拉 / 「设置 › 存储」/ OCR 向导共用）。
String localModelLabel(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_model,
  MangaOcrLocalModel.ppOcrV6Medium => t.manga_ocr_ppocrv6_medium_model,
  MangaOcrLocalModel.ppOcrV5Korean => t.manga_ocr_ppocrv5_korean_model,
  MangaOcrLocalModel.charspotSmall => t.manga_ocr_charspot_small_model,
  MangaOcrLocalModel.charspotNano => t.manga_ocr_charspot_nano_model,
  MangaOcrLocalModel.narSmall => t.manga_ocr_nar_small_model,
  MangaOcrLocalModel.custom => t.manga_ocr_custom_model_label,
};

/// 本机模型的一句话取舍（语言 / 体积 / 速度 / 硬件要求 / 许可）。
String localModelDescription(MangaOcrLocalModel model) => switch (model) {
  MangaOcrLocalModel.mangaCtc => t.manga_ocr_ctc_desc,
  MangaOcrLocalModel.ppOcrV6Medium => t.manga_ocr_ppocrv6_medium_desc,
  MangaOcrLocalModel.ppOcrV5Korean => t.manga_ocr_ppocrv5_korean_desc,
  MangaOcrLocalModel.charspotSmall => t.manga_ocr_charspot_small_desc,
  MangaOcrLocalModel.charspotNano => t.manga_ocr_charspot_nano_desc,
  MangaOcrLocalModel.narSmall => t.manga_ocr_nar_small_desc,
  MangaOcrLocalModel.custom => t.manga_ocr_custom_model_desc,
};

/// 本平台列得出的模型：只给 Windows 的模型在别的平台不列
/// （[MangaOcrLocalModel.availableOnAllPlatforms]；目前五个模型五端都能跑）。
List<MangaOcrLocalModel> platformMangaOcrLocalModels() => <MangaOcrLocalModel>[
  for (final MangaOcrLocalModel model in MangaOcrLocalModel.values)
    if (Platform.isWindows || model.availableOnAllPlatforms) model,
];

/// One translated sentence for why a custom model import failed (settings
/// toast). Anything that is not a [MangaOcrCustomModelImportException] is shown
/// as is.
String customMangaOcrImportErrorText(Object? failure) {
  if (failure is! MangaOcrCustomModelImportException) return '$failure';
  final String detail = failure.detail ?? '';
  return switch (failure.error) {
    MangaOcrCustomModelImportError.modelFileType =>
      t.manga_ocr_custom_model_error_model_file_type,
    MangaOcrCustomModelImportError.dictFileType =>
      t.manga_ocr_custom_model_error_dict_file_type,
    MangaOcrCustomModelImportError.fileUnreadable =>
      t.manga_ocr_custom_model_error_file_unreadable,
    MangaOcrCustomModelImportError.modelTooLarge =>
      t.manga_ocr_custom_model_error_file_too_large(
        limit: FushiByteFormat.bytes(kCustomMangaOcrMaxModelBytes),
      ),
    MangaOcrCustomModelImportError.dictTooLarge =>
      t.manga_ocr_custom_model_error_file_too_large(
        limit: FushiByteFormat.bytes(kCustomMangaOcrMaxDictBytes),
      ),
    MangaOcrCustomModelImportError.dictInvalid =>
      t.manga_ocr_custom_model_error_dict_invalid(detail: detail),
    MangaOcrCustomModelImportError.modelLoadFailed =>
      t.manga_ocr_custom_model_error_load_failed,
    MangaOcrCustomModelImportError.notRecognizer =>
      t.manga_ocr_custom_model_error_not_recognizer,
    MangaOcrCustomModelImportError.classCountMismatch =>
      t.manga_ocr_custom_model_error_dict_mismatch(
        expected: '${failure.expectedDictEntries}',
        actual: '${failure.dictEntries}',
        diff:
            '${((failure.expectedDictEntries ?? 0) - (failure.dictEntries ?? 0)).abs()}',
      ),
    MangaOcrCustomModelImportError.storageFailed =>
      t.manga_ocr_custom_model_error_storage_failed(detail: detail),
  };
}
