import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';

/// 「同名书受管内容已丢 → 新导入就地恢复到原条目」的**唯一**判据（UXtYShn4Yj）。
///
/// 书库行还在、书目录没了（外部清理工具 / 旧版 flutter_logs 整树删除 / 搬家残缺）时，
/// 这本书本来就打不开；用户能做的唯一一件事就是把原件再导入一次。此前任何导入入口
/// （手动导入对话框、来源扫描、批量下载）都按标题把它判成「重复」：跳过，或另起一本
/// `X (2)`，原条目（进度、书签、统计、合集、有声书对齐）永远修不回来；来源扫描的
/// 重建（BUG-5569）又只认「当初就是本来源导进来的行」。
///
/// 现在所有「往书库落一本书」的入口都经 `EpubImporter.placeUnderResolvedTitle`，
/// 它和各入口的跳过预检（[precheckSkippedDuplicate]）都只问这里：撞名的行**格式
/// 相同、受管内容已丢、书目录在当前书库根下**，就把新导入的内容换进它的书目录，
/// 不再按重复处置。内容完好的同名行行为不变（跳过 / 询问 / 加后缀）。

/// 一本已入库书的受管内容是否还在——只认阅读器开书必需的产物：书目录在且非空；
/// EPUB 还要有 `META-INF/container.xml`（重新解析解压树的入口），PDF / 漫画还要有
/// 书目录里的 `extractDir/epubPath`（`document.pdf` / `manga.json`）。封面不算：它有
/// 大小写不敏感的兜底解析，还可能被用户换成别处的文件。[extractDir] 为空或是别的
/// 格式一律算「在」（没有可判、可重建的受管目录）。
Future<bool> bookManagedContentIntact({
  required String format,
  required String extractDir,
  required String epubPath,
}) async {
  if (extractDir.isEmpty) return true;
  final bool isEpub = format == BookFormat.epub.dbValue;
  final bool isFileBook =
      format == BookFormat.pdf.dbValue || format == BookFormat.manga.dbValue;
  if (!isEpub && !isFileBook) return true;
  if (!await EpubStorage.bookDirExists(extractDir)) return false;
  final String entry = isEpub
      ? p.join(extractDir, 'META-INF', 'container.xml')
      : p.join(extractDir, epubPath);
  return File(entry).exists();
}

/// [extractDir] 是否落在当前书库根（`EpubStorage.baseDirectory`）之下。不在的（旧数据
/// 根、没 rebase 的路径）不往那里写：重建只会把书散落到库外。
Future<bool> bookDirWithinLibrary(String extractDir) async {
  if (extractDir.isEmpty) return false;
  final String base = await EpubStorage.baseDirectory();
  return p.isWithin(p.canonicalize(base), p.canonicalize(extractDir));
}

/// 书行 [row] 能否由一次 [format] 格式的新导入就地恢复：格式相同、受管内容已丢、
/// 书目录在当前书库根下。
Future<bool> isRestorableBookRow(EpubBookRow row, String format) async {
  if (row.format != format) return false;
  if (await bookManagedContentIntact(
    format: row.format,
    extractDir: row.extractDir,
    epubPath: row.epubPath,
  )) {
    return false;
  }
  return bookDirWithinLibrary(row.extractDir);
}

/// 书名 [proposedTitle] 撞上的那一行（与判重复同一口径：净化后的标题），且它能由
/// [format] 格式的新导入就地恢复（[isRestorableBookRow]）时返回它；不撞名 / 撞上的
/// 行内容完好 / 格式不同 / 在库外都返回 null。只读一次瘦投影书目快照加几次 stat。
Future<EpubBookRow?> findRestorableDuplicate({
  required FushiDatabase db,
  required String proposedTitle,
  required String format,
}) async {
  final String key = sanitizeTtuFilename(proposedTitle);
  for (final EpubBookMeta meta in await db.getEpubBookMetas()) {
    if (sanitizeTtuFilename(meta.title) != key) continue;
    if (meta.format != format) return null;
    final EpubBookRow? row = await db.getEpubBook(meta.bookKey);
    if (row == null) return null;
    return await isRestorableBookRow(row, format) ? row : null;
  }
  return null;
}

/// [DuplicatePolicy.skip] 的导入前预检（manga-10 / PDF）：[proposedTitle] 已在书库里、
/// 且撞上的行**不能**就地恢复时抛 [DuplicateImportCancelledException]；能恢复的放行
/// （落位时 `EpubImporter.placeUnderResolvedTitle` 把内容换进原条目）。其它策略直接
/// 返回，不碰数据库（[DuplicatePolicy.ask] 的「先做完再问」次序不变）。
Future<void> precheckSkippedDuplicate({
  required FushiDatabase db,
  required String proposedTitle,
  required String format,
  required DuplicatePolicy policy,
}) async {
  if (policy is! SkipDuplicate) return;
  final List<EpubBookMeta> books = await db.getEpubBookMetas();
  final String key = sanitizeTtuFilename(proposedTitle);
  if (!books.any((EpubBookMeta b) => sanitizeTtuFilename(b.title) == key)) {
    return;
  }
  if (policy.restoreMissing &&
      await findRestorableDuplicate(
            db: db,
            proposedTitle: proposedTitle,
            format: format,
          ) !=
          null) {
    return;
  }
  throw DuplicateImportCancelledException(proposedTitle);
}

/// 就地恢复（新导入换进原条目 / 来源扫描按原件重建）之后回写原行的**唯一**口径：
/// 章节元数据必须与盘上的新树一致（阅读器按它定位章节文件 / 页图），所以照写；EPUB
/// 的目录（[tocJson]，href 指向解压树里的文件）同理，换了树就必须一起换；PDF / 漫画
/// 没有解压树目录，传 absent 不动；
/// 封面列只在它为空、或指着书目录里已经不存在的文件时才换成新树的封面——用户换过 /
/// 刮削过的封面不被原件的封面盖掉。bookKey / uid / 进度 / 统计 / 合集一概不动。
Future<void> writeRestoredBookMetadata({
  required FushiDatabase db,
  required EpubBookRow existing,
  required int chapterCount,
  required String chaptersJson,
  required String? coverPath,
  Value<String?> tocJson = const Value.absent(),
}) async {
  await db.updateEpubBookChapters(
    existing.bookKey,
    chapterCount: chapterCount,
    chaptersJson: chaptersJson,
    tocJson: tocJson,
  );
  final String? cover = existing.coverPath;
  final bool coverGone =
      cover == null ||
      (!p.isAbsolute(cover) &&
          !File(p.join(existing.extractDir, cover)).existsSync());
  if (coverGone && coverPath != null) {
    await db.updateEpubBookContentPaths(existing.bookKey, coverPath: coverPath);
  }
}
