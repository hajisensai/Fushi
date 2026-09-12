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
/// 跳过」、作品页判「显示已下载」、阅读器判「能不能开」、互联 host 判「哪些章可以
/// 端给对端」都问 [isChapterDownloaded]，各写一份必然漂移出「作品页说已下载、阅读器
/// 说没有」的状态。
///
/// 住在引擎而不是 app：互联 host（引擎里唯一那份实现）要按同一布局枚举对端可读的章，
/// 而引擎禁 import `package:fushi`。app 侧 `media/manga/library/manga_chapter_storage.dart`
/// 只是本文件的 re-export + 一个需要 app 写锁的删除 helper。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 书目录下承载各章目录的子目录名。
const String kMangaChaptersDirName = 'chapters';

/// 章 key 的目录名摘要：`sha256(chapterKey)` 十六进制前 24 位。
///
/// 章 key 是源给的 URL / 路径，长度和字符集都不可控，不能直接进文件名。
String mangaChapterDigest(String chapterKey) =>
    sha256.convert(utf8.encode(chapterKey)).toString().substring(0, 24);

/// [value] 是否形如 [mangaChapterDigest] 的输出（24 位小写十六进制）。
///
/// 互联页图端点把 digest 当路径段收，进目录前先按此判形，杜绝穿越。
bool isMangaChapterDigest(String value) =>
    RegExp(r'^[0-9a-f]{24}$').hasMatch(value);

/// 某一章的受管目录 `<bookDir>/chapters/<digest>`。不创建。
Directory mangaChapterDirectory(String bookDir, String chapterKey) =>
    mangaChapterDirectoryByDigest(bookDir, mangaChapterDigest(chapterKey));

/// 按已知 [digest] 定位章目录（互联 host 端点只拿到 digest、拿不到原 key）。
Directory mangaChapterDirectoryByDigest(String bookDir, String digest) =>
    Directory(p.join(bookDir, kMangaChaptersDirName, digest));

/// 章目录里的 `manga.json`。
File mangaChapterJsonFile(Directory chapterDir) =>
    File(p.join(chapterDir.path, MangaStorage.kMangaJsonFileName));

/// 章目录里的页图根 `images/`。
Directory mangaChapterImagesDirectory(Directory chapterDir) =>
    MangaStorage.imagesDirectory(chapterDir.path);

/// 读并校验一章目录的 payload：`manga.json` 存在、`pages` 非空、每页文件都在时
/// 返回 payload，否则 null。
///
/// 三个条件缺一不可：只看 `manga.json` 会把「写完 payload 前进程被杀」的半成品
/// 当成已下载；只看 `images/` 非空会把「下了两页就断网」当成已下载。页文件用
/// [MangaStorage.resolvePageFilePath] 解析，越界的 url 视同缺页。
Future<MokuroPayload?> readDownloadedChapterPayload(
  Directory chapterDir,
) async {
  final File json = mangaChapterJsonFile(chapterDir);
  if (!await json.exists()) return null;
  final MokuroPayload payload;
  try {
    payload = parseMangaJson(await json.readAsString());
  } on Object {
    return null;
  }
  if (payload.images.isEmpty) return null;
  final String imagesRoot = mangaChapterImagesDirectory(chapterDir).path;
  for (final MokuroImage image in payload.images) {
    final String? file = MangaStorage.resolvePageFilePath(
      imagesRoot,
      MangaStorage.pageRelativePath(image.url),
    );
    if (file == null) return null;
  }
  return payload;
}

/// 一章是否**完整**下载（判据见 [readDownloadedChapterPayload]）。
Future<bool> isChapterDownloaded(String bookDir, String chapterKey) async =>
    await readDownloadedChapterPayload(
      mangaChapterDirectory(bookDir, chapterKey),
    ) !=
    null;

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

/// 书目录下是否**可能**有已下载的章：`chapters/` 里至少一个子目录带 `manga.json`。
///
/// 这是清单级的廉价判据（一次目录列举，不逐页 stat）——`/api/library/books` 对每本
/// 漫画都要答一次，逐章逐页校验在几百章的库上是 O(页数) 次磁盘访问。真正的
/// 「这一章能不能读」仍由 [readDownloadedChapterPayload] 在按章请求时把关，所以这里
/// 偶尔把半成品算进来只会让清单多一张卡，翻页端点照样拒绝。
bool hasAnyChapterDirSync(String bookDir) {
  final Directory chapters = Directory(p.join(bookDir, kMangaChaptersDirName));
  // 与 hasExportableMangaContent 同口径吞 IO 异常：清单对每本漫画都问一次，书目录
  // 在两次调用之间被删（host 上「移出书架」）或权限错误时，这一本按「无章」处理，
  // 不能让整个 /api/library/books 500、对端所有远端卡一起消失。
  try {
    if (!chapters.existsSync()) return false;
    for (final FileSystemEntity entity in chapters.listSync()) {
      if (entity is! Directory) continue;
      if (!isMangaChapterDigest(p.basename(entity.path))) continue;
      if (mangaChapterJsonFile(entity).existsSync()) return true;
    }
  } on FileSystemException {
    return false;
  }
  return false;
}
