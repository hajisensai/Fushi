/// 在线漫画章节的落盘布局与「已下载」判据（设计稿 2026-09-12 §2.1）。
///
/// 一条在线书架条目住在 `<fushi_books>/<bookKey>/`，每章一个受管目录：
///
/// ```
/// <bookDir>/chapters/<digest>/
///   manga.json               # 该章 payload：pages[{url,width,height,blocks}]
///   images/page-000001.<ext>
/// ```
///
/// `digest = sha256(chapterKey)[:24]`——与旧 `OnlineMangaLibraryService.
/// chapterDirectory()` 同算法，只换根目录。判据**只写这一处**：下载服务判「要不要
/// 跳过」、作品页判「显示已下载」、阅读器判「能不能开」都问 [isChapterDownloaded]，
/// 各写一份必然漂移出「作品页说已下载、阅读器说没有」的状态。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 书目录下承载各章目录的子目录名。
const String kMangaChaptersDirName = 'chapters';

/// 章 key 的目录名摘要：`sha256(chapterKey)` 十六进制前 24 位。
///
/// 章 key 是源给的 URL / 路径，长度和字符集都不可控，不能直接进文件名。
String mangaChapterDigest(String chapterKey) =>
    sha256.convert(utf8.encode(chapterKey)).toString().substring(0, 24);

/// 某一章的受管目录 `<bookDir>/chapters/<digest>`。不创建。
Directory mangaChapterDirectory(String bookDir, String chapterKey) => Directory(
      p.join(bookDir, kMangaChaptersDirName, mangaChapterDigest(chapterKey)),
    );

/// 章目录里的 `manga.json`。
File mangaChapterJsonFile(Directory chapterDir) =>
    File(p.join(chapterDir.path, MangaStorage.kMangaJsonFileName));

/// 章目录里的页图根 `images/`。
Directory mangaChapterImagesDirectory(Directory chapterDir) =>
    MangaStorage.imagesDirectory(chapterDir.path);

/// 一章是否**完整**下载：`manga.json` 存在、`pages` 非空、每页文件都在。
///
/// 三个条件缺一不可：只看 `manga.json` 会把「写完 payload 前进程被杀」的半成品
/// 当成已下载；只看 `images/` 非空会把「下了两页就断网」当成已下载。页文件用
/// [MangaStorage.resolvePageFilePath] 解析，越界的 url 视同缺页。
Future<bool> isChapterDownloaded(String bookDir, String chapterKey) async {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final File json = mangaChapterJsonFile(chapterDir);
  if (!await json.exists()) return false;
  final MokuroPayload payload;
  try {
    payload = parseMangaJson(await json.readAsString());
  } on Object {
    return false;
  }
  if (payload.images.isEmpty) return false;
  final String imagesRoot = mangaChapterImagesDirectory(chapterDir).path;
  for (final MokuroImage image in payload.images) {
    final String? file = MangaStorage.resolvePageFilePath(
      imagesRoot,
      MangaStorage.pageRelativePath(image.url),
    );
    if (file == null) return false;
  }
  return true;
}

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

/// 一批章里哪些已下载（作品页 / 章节选择器一次算全量）。
Future<Set<String>> downloadedChapterKeys(
  String bookDir,
  Iterable<String> chapterKeys,
) async {
  final Set<String> downloaded = <String>{};
  for (final String key in chapterKeys) {
    if (await isChapterDownloaded(bookDir, key)) downloaded.add(key);
  }
  return downloaded;
}
