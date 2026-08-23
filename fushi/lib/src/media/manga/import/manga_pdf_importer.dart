import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/media/manga/book_format_convert.dart';
import 'package:fushi/src/media/manga/book_format_rebuild.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 「一份 PDF 直接进漫画库」的落地路径。
///
/// 为什么不是第三条导入器：仓库里早就有把 PDF 变成漫画的**全部**零件——
/// [PdfImporter.importFromPath] 负责「PDF 落成一本书」（拷 `document.pdf` 进书目录、
/// 栅格化首页当封面、落 `format='pdf'` 的行），[BookFormatRebuild.convert] 负责
/// 「把这一行的产物重建成漫画」（逐页栅格化成 `images/`、写 `manga.json`、把行翻成
/// `format='manga'`）。本函数只是把这两步串起来，一行新的导入逻辑都不写。
///
/// 串起来（而不是「直接把 PDF 逐页栅格化后当图片目录导入」）的关键收益：书目录里
/// 仍留着那份 `document.pdf`，于是 [BookFormatRebuild] 的「漫画 → 转回 PDF」往返对
/// 这本书**依然成立**（判据是 `recoverableBookSource` 能不能找到 `document.pdf`）。
/// 走图片目录那条捷径导出来的漫画永远转不回去，那是单向的数据损失。
///
/// 失败即回滚：PDF 那一步自带回滚，但它成功、转化那一步失败时，书架上会凭空多出
/// 一本「PDF 书」而调用方却收到了一个异常——用户看到的是「导入失败」加一本没要过的
/// 书。这一段本来就是本函数在这一次操作里创建的东西，删干净才是诚实的结局。
Future<String> importMangaFromPdf({
  required FushiDatabase db,
  required String pdfPath,
  required String fileName,
  required String title,
  DuplicatePolicy policy = const DuplicatePolicy.suffix(),
  void Function(int done, int total)? onProgress,
  int? sourceId,
}) async {
  final String bookKey = await PdfImporter.importFromPath(
    db: db,
    filePath: pdfPath,
    fileName: fileName,
    title: title,
    policy: policy,
    sourceId: sourceId,
  );

  try {
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) {
      throw StateError('PDF 行导入后立刻查不到：$bookKey');
    }
    await BookFormatRebuild.convert(
      db: db,
      row: row,
      target: BookFormatTarget.manga,
      onProgress: onProgress,
    );
  } catch (_) {
    await _rollbackBook(db, bookKey);
    rethrow;
  }

  return bookKey;
}

/// 删掉本次操作刚建出来的书：行 + 书目录。回滚自身失败只记日志，不掩盖原始异常。
Future<void> _rollbackBook(FushiDatabase db, String bookKey) async {
  String? bookDir;
  try {
    bookDir = (await db.getEpubBook(bookKey))?.extractDir;
  } catch (e, stack) {
    ErrorLogService.instance.log('importMangaFromPdf.rollbackLookup', e, stack);
  }
  try {
    await db.deleteEpubBook(bookKey);
  } catch (e, stack) {
    ErrorLogService.instance.log('importMangaFromPdf.rollbackDelete', e, stack);
  }
  if (bookDir == null) return;
  try {
    final Directory dir = Directory(bookDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (e, stack) {
    ErrorLogService.instance.log('importMangaFromPdf.rollbackDir', e, stack);
  }
}
