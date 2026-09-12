/// 在线漫画章节的落盘布局与「已下载」判据——**布局与判据本体住在引擎**
/// （`package:fushi_engine/media/manga/manga_chapter_storage.dart`，互联 host 按同一
/// 布局把已下载的章端给对端），本文件 re-export 它并补一个要拿 app 侧 `manga.json`
/// 写锁的删除 helper。
library;

import 'dart:io';

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';

export 'package:fushi_engine/media/manga/manga_chapter_storage.dart';

/// 删除一章的全部落盘（半成品也一并清）。
///
/// 删目录前先拿该章 `manga.json` 的 per-path 写锁：整卷 OCR 完成落盘走的是同一把
/// 锁，无锁删会落在它的读-改-写之间，让刚删掉的目录被它原样写回一半。
Future<void> deleteChapterDownload(String bookDir, String chapterKey) async {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final File json = mangaChapterJsonFile(chapterDir);
  await runExclusiveOnMangaJson<void>(json.path, () async {
    if (await chapterDir.exists()) {
      await chapterDir.delete(recursive: true);
    }
  });
}
