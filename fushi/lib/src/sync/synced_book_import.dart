import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart'
    show importMangaPackageFile, isMangaPackage;
import 'package:fushi_engine/sync/pdf_sync_package.dart' show isPdfFile;
import 'package:path/path.dart' as p;

import 'package:fushi/src/pdf/pdf_importer.dart';

/// 从对端下载下来的一份书包落库，返回本机入库的 bookKey。
///
/// 互联 books 端点对 EPUB、漫画包、PDF 原件共用同一个传输面（下载落点文件名恒是
/// `.epub`），所以**按内容嗅探分流**，扩展名不参与判定：
/// - PDF 原件（头部 `%PDF-`，反馈 Jq1_ujHa4t）→ [PdfImporter]；
/// - zip 根含 `manga.json` → 漫画包两遍式校验落库；
/// - 其余 → [EpubImporter]，坏包由它如实报错。
///
/// 书架远端下载与「同步对比」弹窗下载共用本函数——此前两处各写一份嗅探，加一种
/// 格式就要改两处、漏一处就是那条入口下不了（对比弹窗曾漏过漫画）。host 收推送的
/// 分流在引擎 `LocalLibraryHostService.importBook`，用同一个 [isPdfFile] 判据。
///
/// [title] = 远端 raw 书名：漫画 / PDF 的身份键 bookKey 由它派生（不能用本地临时
/// 文件名——那是净化过的 ASCII 键，用它当标题会漂键）；null 时退回文件名去扩展名。
/// [epubFileName] 交 EPUB 导入器当原始文件名（EPUB 的标题取自书内元数据）。
Future<String> importSyncedBookFile({
  required FushiDatabase db,
  required File file,
  required String? title,
  required String epubFileName,
}) async {
  final String resolvedTitle = title ?? p.basenameWithoutExtension(file.path);
  if (await isPdfFile(file)) {
    return PdfImporter.importFromPath(
      db: db,
      filePath: file.path,
      fileName: '$resolvedTitle.pdf',
      title: resolvedTitle,
    );
  }
  if (await isMangaPackage(file)) {
    return importMangaPackageFile(db: db, file: file, title: resolvedTitle);
  }
  return EpubImporter.importFromPath(
    db: db,
    filePath: file.path,
    fileName: epubFileName,
  );
}
