/// 漫画卡「导入漫画有声」：选一份成品清单（`manifest.json`）→ 校验 → 登记，结果用
/// toast 告知。校验与登记在 [importMangaAudioManifest]（可单测），这里只有选文件与提示。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// [result] 对应的提示文案与级别。
({String msg, ToastSeverity severity}) mangaAudioImportFeedback(
  MangaAudioImportResult result,
) => switch (result) {
  MangaAudioImportResult.imported => (
    msg: t.manga_audio_import_done,
    severity: ToastSeverity.success,
  ),
  MangaAudioImportResult.invalid || MangaAudioImportResult.missingAudio => (
    msg: t.manga_audio_import_invalid,
    severity: ToastSeverity.warning,
  ),
  MangaAudioImportResult.pageMismatch => (
    msg: t.manga_audio_import_page_mismatch,
    severity: ToastSeverity.warning,
  ),
  MangaAudioImportResult.ocrMismatch => (
    msg: t.manga_audio_import_ocr_mismatch,
    severity: ToastSeverity.warning,
  ),
};

Future<void> pickAndImportMangaAudio(FushiDatabase db, String bookKey) async {
  // 清单当场读完写进库，不长期引用路径；按扩展名选走统一入口（安卓 SAF 不认
  // 扩展名过滤时自动降级成 any + Dart 端校验）。
  final FilePickerResult? picked = await pickFilesByExtensions(
    context: null,
    allowedExtensions: const <String>['json'],
  );
  final String? path = picked?.files.single.path;
  if (path == null) return;
  final MangaAudioImportResult result = await importMangaAudioManifest(
    db,
    bookKey: bookKey,
    manifestFile: File(path),
  );
  final ({String msg, ToastSeverity severity}) feedback =
      mangaAudioImportFeedback(result);
  FushiToast.show(msg: feedback.msg, severity: feedback.severity);
}
