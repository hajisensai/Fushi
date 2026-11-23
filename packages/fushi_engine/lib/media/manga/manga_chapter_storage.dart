/// 在线漫画章节的落盘布局与「已下载」判据（设计稿 2026-09-12 §2.1）。
///
/// 一条在线书架条目住在 `<fushi_books>/<bookKey>/`，每章一个受管目录：
///
/// ```
/// <bookDir>/chapters/<digest>/
///   manga.json               # 该章 payload：pages[{url,width,height,blocks}]
///   images/page-000001.<ext>
///   .fushi-source-pages.json # 每页的源端身份（MangaChapterSourcePage，可缺）
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
import 'package:path/path.dart' show PathMap;

import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/utils/misc/atomic_text_file.dart'
    show readAtomicallyWrittenTextFile;

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

/// 一批章的「章目录 → 章 key」索引（gap-mangamisc-4）。
///
/// OCR 任务只认目录、章节行只认 key：逐章 `p.equals(mangaChapterDirectory(...))`
/// 是每次查询 N 次 sha256 + 路径规范化。这里一次建好，查询走 [PathMap]——它的相等
/// 与哈希就是 `p.equals` / `p.hash`，大小写（Windows）、`..`、分隔符的口径与逐章比较
/// 完全一致。同一目录对应多个 key 时取先出现的（与逐章扫描「第一个命中」一致）。
PathMap<String> mangaChapterKeysByDirectory(
  String bookDir,
  Iterable<String> chapterKeys,
) {
  final PathMap<String> index = PathMap<String>();
  for (final String key in chapterKeys) {
    index.putIfAbsent(mangaChapterDirectory(bookDir, key).path, () => key);
  }
  return index;
}

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
///
/// [parse] 给了就用它解析 `manga.json`（阅读器传后台 isolate 版，几 MB 的 JSON 不在
/// UI isolate 上解析）；判过关的 payload 由调用方直接拿去装载，不再读第二遍
/// （manga-4）。缺省同步 [parseMangaJson]。
Future<MokuroPayload?> readDownloadedChapterPayload(
  Directory chapterDir, {
  Future<MokuroPayload> Function(String source)? parse,
}) async {
  final File json = mangaChapterJsonFile(chapterDir);
  if (!await json.exists()) return null;
  final MokuroPayload payload;
  try {
    final String source = await json.readAsString();
    payload = parse == null ? parseMangaJson(source) : await parse(source);
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

/// 章目录里记「每页从源端哪一页下来」的旁注文件名（下文 [MangaChapterSourcePage]）。
const String kMangaChapterSourcePagesFileName = '.fushi-source-pages.json';

/// 章目录里的源端页身份旁注。
File mangaChapterSourcePagesFile(Directory chapterDir) =>
    File(p.join(chapterDir.path, kMangaChapterSourcePagesFileName));

/// 已下载的一页是从源端哪一页下来的：下载服务在写 `manga.json` 之前落一份，
/// 互联 host 据此让一章「下载前 / 下载后」对外报同一个页身份。
///
/// 为什么需要：互联 host 端出没下载的章时，页身份是源端身份
/// （`OnlineMangaPageRef.pageKey`）；章一下完，页就成了磁盘文件，按文件认页。对端
/// 读到一半 host 正好下完这章，手上的页表身份全对不上，取页 409、对端的下载整章
/// 重下。有了这份旁注，host 对已下载的章照旧报源端身份、核对时两种身份都认。
///
/// 为什么是旁注而不是 `manga.json` 的字段：`manga.json` 之后会被 OCR / 大模型识别 /
/// PDF 文字层回填等多个写者按自己手里的 payload 整份重写，页上的额外字段会被悄悄
/// 冲掉——偏偏「下完立刻自动 OCR」就落在这个窗口里。旁注没有别的写者。
///
/// 每条按 [url] + 尺寸绑定到 `manga.json` 的那一页（与 host 按文件认页的口径
/// 相同）：`manga.json` 被换成另一份内容（重下、OCR 报了不同尺寸）时对不上，
/// 这一页退回按文件认页，宁可保守失败也不认错页。
typedef MangaChapterSourcePage = ({
  String url,
  int width,
  int height,
  String key,
});

/// [MangaChapterSourcePage] 列表的落盘形状：`{"version":1,"pages":[...]}`，下标 =
/// 页序，`null` = 这一页源端没给身份。
String encodeMangaChapterSourcePages(List<MangaChapterSourcePage?> pages) =>
    jsonEncode(<String, Object?>{
      'version': 1,
      'pages': <Map<String, Object?>?>[
        for (final MangaChapterSourcePage? page in pages)
          page == null
              ? null
              : <String, Object?>{
                  'url': page.url,
                  'width': page.width,
                  'height': page.height,
                  'key': page.key,
                },
      ],
    });

/// 解析 [encodeMangaChapterSourcePages] 的产出。坏 JSON / 未知版本 / 形状不对的
/// 条目一律当作「没有」（空列表或 null 条目）：旁注只是让对端少失败一次的增强，
/// 认不出就退回按文件认页。
List<MangaChapterSourcePage?> decodeMangaChapterSourcePages(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return const <MangaChapterSourcePage?>[];
  }
  if (decoded is! Map<String, Object?> || decoded['version'] != 1) {
    return const <MangaChapterSourcePage?>[];
  }
  final Object? pages = decoded['pages'];
  if (pages is! List<Object?>) return const <MangaChapterSourcePage?>[];
  return <MangaChapterSourcePage?>[
    for (final Object? page in pages) _decodeSourcePage(page),
  ];
}

MangaChapterSourcePage? _decodeSourcePage(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final Object? url = raw['url'];
  final Object? width = raw['width'];
  final Object? height = raw['height'];
  final Object? key = raw['key'];
  if (url is! String || width is! int || height is! int || key is! String) {
    return null;
  }
  if (key.isEmpty) return null;
  return (url: url, width: width, height: height, key: key);
}

/// [payload] 第 [index] 页的源端身份：旁注 [pages] 里同页序的那条与这一页的 url
/// 和尺寸都对得上才给，否则（越界、没记、`manga.json` 已换过内容）null。
String? mangaChapterSourcePageKey(
  List<MangaChapterSourcePage?> pages,
  MokuroPayload payload,
  int index,
) {
  if (index < 0 || index >= payload.images.length || index >= pages.length) {
    return null;
  }
  final MangaChapterSourcePage? page = pages[index];
  if (page == null) return null;
  final MokuroImage image = payload.images[index];
  if (normalizeMangaUrl(page.url) != normalizeMangaUrl(image.url) ||
      page.width != image.size.width.round() ||
      page.height != image.size.height.round()) {
    return null;
  }
  return page.key;
}

/// 读章目录 [chapterDir] 的源端页身份旁注；没有 / 读不出按「没有」（空列表）。
///
/// 下载服务用 `writeTextFileAtomically` 写它，所以这里经
/// [readAtomicallyWrittenTextFile] 读（Windows 上与那次替换互斥）。
Future<List<MangaChapterSourcePage?>> readMangaChapterSourcePages(
  Directory chapterDir,
) async {
  final File file = mangaChapterSourcePagesFile(chapterDir);
  final String source;
  try {
    source = await readAtomicallyWrittenTextFile(file);
  } on FileSystemException {
    return const <MangaChapterSourcePage?>[];
  }
  return decodeMangaChapterSourcePages(source);
}

/// 下载服务把一章落盘的 [payload] 与取页时页表的逐页源端身份 [sourceKeys]
/// （`OnlineMangaPageRef.pageKey`，下标 = 页序）配成旁注条目。两边页数不一致
/// （不该发生）时整份不记——宁可退回按文件认页，也不把身份配错页。
List<MangaChapterSourcePage?> mangaChapterSourcePagesOf(
  MokuroPayload payload,
  List<String?> sourceKeys,
) {
  if (payload.images.length != sourceKeys.length) {
    return const <MangaChapterSourcePage?>[];
  }
  return <MangaChapterSourcePage?>[
    for (int index = 0; index < sourceKeys.length; index++)
      switch (sourceKeys[index]) {
        final String key when key.isNotEmpty => (
          url: payload.images[index].url,
          width: payload.images[index].size.width.round(),
          height: payload.images[index].size.height.round(),
          key: key,
        ),
        _ => null,
      },
  ];
}
