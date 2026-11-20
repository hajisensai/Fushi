import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show StringExpressionOperators, Value;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/sync/online_novel_book.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/novel_online_sources_gate.dart';
import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 在线小说书的重启安全描述符，存在 `EpubBooks.sourceMetadata`。
///
/// 在线阅读不另起数据模型：作品第一次在线打开时建成一本**全章占位**的普通
/// EPUB（章节标题、目录、封面齐全，正文是占位页）进书架，阅读器开到哪一章，
/// 那一章才经插件取正文写回解压树（[LnReaderOnlineChapterLoader]）。所以阅读
/// 位置、查词、制卡、统计、同步全部复用普通书的链路，与在线漫画「点章节即入库」
/// 同一个形态。
///
/// 描述符只含插件 id、作品路径与章节路径 / 标题（**不含** cookie / 请求头）。
@immutable
class LnReaderOnlineBookDescriptor {
  const LnReaderOnlineBookDescriptor({
    required this.pluginId,
    required this.novelPath,
    required this.chapters,
  });

  static const String marker = kLnReaderOnlineBookMarker;
  static const int version = 1;

  final String pluginId;
  final String novelPath;

  /// 章节按 spine 顺序：第 i 项就是 `OEBPS/chapter-(i+1).xhtml`。
  final List<LnReaderChapter> chapters;

  bool isNovel(String otherPluginId, String otherNovelPath) =>
      pluginId == otherPluginId && novelPath == otherNovelPath;

  String encode() => jsonEncode(<String, Object?>{
    'type': marker,
    'version': version,
    'pluginId': pluginId,
    'novelPath': novelPath,
    'chapters': <Map<String, String>>[
      for (final LnReaderChapter chapter in chapters)
        <String, String>{'path': chapter.path, 'name': chapter.name},
    ],
  });

  /// 不是在线小说描述符（普通书 / 在线漫画 / 损坏）一律 null——描述符坏了只该
  /// 让这本书退化成普通书，不该让阅读器或书架炸。
  static LnReaderOnlineBookDescriptor? tryParse(String? value) {
    if (value == null || !value.contains(marker)) return null;
    try {
      final Object? decoded = jsonDecode(value);
      if (decoded is! Map<String, Object?>) return null;
      if (decoded['type'] != marker || decoded['version'] != version) {
        return null;
      }
      final String pluginId = (decoded['pluginId'] ?? '').toString();
      final String novelPath = (decoded['novelPath'] ?? '').toString();
      final Object? rawChapters = decoded['chapters'];
      if (pluginId.isEmpty || rawChapters is! List<Object?>) return null;
      return LnReaderOnlineBookDescriptor(
        pluginId: pluginId,
        novelPath: novelPath,
        chapters: <LnReaderChapter>[
          for (final Object? raw in rawChapters)
            if (raw is Map<String, Object?>)
              LnReaderChapter(
                name: (raw['name'] ?? '').toString(),
                path: (raw['path'] ?? '').toString(),
              ),
        ],
      );
    } on FormatException {
      return null;
    }
  }
}

/// 占位章正文上的标记属性：解压树里的章节文件带它 = 还没取过正文。
const String kLnReaderPendingChapterAttribute = 'data-fushi-lnreader-pending';

/// 占位章正文（`<section>` 内部）。[text] 是给读者看的说明（联网失败时就停在
/// 这一页）。
String lnReaderPendingChapterBody(String text) =>
    '<p $kLnReaderPendingChapterAttribute="1">${_escXml(text)}</p>';

String _escXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 章内插图文件名前缀：按章节路径而不是章序号派生，章节列表变动（站点插入 /
/// 删除章）后重建占位书时，已取过的章原样搬过去也不会和新章的图撞名。
String lnReaderOnlineImagePrefix(String chapterPath) {
  final String digest = sha1
      .convert(utf8.encode(chapterPath))
      .toString()
      .substring(0, 12);
  return 'images/$digest-';
}

/// 在线书的建立与章节列表同步。
class LnReaderOnlineLibrary {
  LnReaderOnlineLibrary({
    required this.manager,
    required this.database,
    required this.download,
    Future<String> Function({
      required FushiDatabase db,
      required Uint8List bytes,
      required String fileName,
      required DuplicatePolicy policy,
    })?
    importEpub,
    Future<({int chapterCount, String chaptersJson, String? coverPath})>
    Function({required String epubFilePath, required String extractDir})?
    rebuildInPlace,
  }) : _importEpub = importEpub ?? _defaultImport,
       _rebuildInPlace = rebuildInPlace ?? EpubImporter.rebuildExtractedInPlace;

  final LnReaderManager manager;
  final FushiDatabase database;
  final LnReaderBookDownload download;
  final Future<String> Function({
    required FushiDatabase db,
    required Uint8List bytes,
    required String fileName,
    required DuplicatePolicy policy,
  })
  _importEpub;
  final Future<({int chapterCount, String chaptersJson, String? coverPath})>
  Function({required String epubFilePath, required String extractDir})
  _rebuildInPlace;

  static Future<String> _defaultImport({
    required FushiDatabase db,
    required Uint8List bytes,
    required String fileName,
    required DuplicatePolicy policy,
  }) => EpubImporter.import(
    db: db,
    bytes: bytes,
    fileName: fileName,
    policy: policy,
  );

  /// 这部作品已有的在线书（没有返回 null）。
  Future<EpubBookRow?> findBook(String pluginId, String novelPath) async {
    final List<EpubBookRow> rows =
        await (database.select(database.epubBooks)..where(
              (EpubBooks t) => t.sourceMetadata.like(
                '%${LnReaderOnlineBookDescriptor.marker}%',
              ),
            ))
            .get();
    for (final EpubBookRow row in rows) {
      final LnReaderOnlineBookDescriptor? descriptor =
          LnReaderOnlineBookDescriptor.tryParse(row.sourceMetadata);
      if (descriptor != null && descriptor.isNovel(pluginId, novelPath)) {
        return row;
      }
    }
    return null;
  }

  /// 找到或建好这部作品的在线书，返回 bookKey。
  ///
  /// 已有的书在站点章节列表变了（连载更新）时就地重建占位树：取过的章按章节
  /// 路径原样搬过去，书的身份（bookKey / uid / 合集 / 标签）不变。[pendingText]
  /// 是占位页上给读者看的说明。
  Future<String> ensureBook({
    required LnReaderInstalledPlugin plugin,
    required LnReaderNovel novel,
    required String pendingText,
  }) async {
    if (novel.chapters.isEmpty) {
      throw ArgumentError.value(novel.chapters, 'novel.chapters', 'empty');
    }
    final EpubBookRow? existing = await findBook(plugin.id, novel.path);
    if (existing != null) {
      await _syncChapters(existing, plugin, novel, pendingText);
      return existing.bookKey;
    }
    final LnReaderPluginInfo info = await manager.load(plugin);
    final HttpClient client = download.openClient();
    final LnReaderEpubImage? cover;
    try {
      cover = await download.fetchCover(
        client: client,
        plugin: plugin,
        info: info,
        novel: novel,
      );
    } finally {
      client.close(force: true);
    }
    final String title = novel.name.trim().isEmpty
        ? novel.chapters.first.name
        : novel.name.trim();
    final Uint8List bytes = await buildLnReaderOnlineEpubInBackground(
      _request(
        plugin: plugin,
        novel: novel,
        title: title,
        pendingText: pendingText,
        cover: cover,
      ),
    );
    final String bookKey = await _importEpub(
      db: database,
      bytes: bytes,
      fileName: '${lnReaderSafeFileName(title)}.epub',
      // 程序化入库：与已下载的同名书并存（加后缀），不打断用户。
      policy: const DuplicatePolicy.suffix(),
    );
    await (database.update(
      database.epubBooks,
    )..where((EpubBooks t) => t.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(
        sourceMetadata: Value<String?>(
          LnReaderOnlineBookDescriptor(
            pluginId: plugin.id,
            novelPath: novel.path,
            chapters: novel.chapters,
          ).encode(),
        ),
      ),
    );
    return bookKey;
  }

  Future<void> _syncChapters(
    EpubBookRow row,
    LnReaderInstalledPlugin plugin,
    LnReaderNovel novel,
    String pendingText,
  ) async {
    final LnReaderOnlineBookDescriptor? descriptor =
        LnReaderOnlineBookDescriptor.tryParse(row.sourceMetadata);
    if (descriptor == null) return;
    if (listEquals(
      descriptor.chapters.map((LnReaderChapter c) => c.path).toList(),
      novel.chapters.map((LnReaderChapter c) => c.path).toList(),
    )) {
      return;
    }
    final String extractDir = row.extractDir;
    // 逐章读已取过的正文与插图、读封面、整本重新打 ZIP 都与章数 / 图量成正比
    // （几百章带图的连载是几十 MB 的同步读盘 + 压缩），整段放后台 isolate。
    final Uint8List bytes = await buildLnReaderOnlineEpubInBackground(
      _request(
        plugin: plugin,
        novel: novel,
        title: row.title,
        pendingText: pendingText,
        reuse: (
          extractDir: extractDir,
          previousChapterPaths: <String>[
            for (final LnReaderChapter chapter in descriptor.chapters)
              chapter.path,
          ],
          coverPath: row.coverPath,
        ),
      ),
    );
    final Directory temp = await Directory.systemTemp.createTemp(
      'fushi-lnreader-',
    );
    try {
      final File epub = File(p.join(temp.path, 'book.epub'));
      await epub.writeAsBytes(bytes, flush: true);
      final ({int chapterCount, String chaptersJson, String? coverPath})
      rebuilt = await _rebuildInPlace(
        epubFilePath: epub.path,
        extractDir: extractDir,
      );
      await database.updateEpubBookMihonState(
        row.bookKey,
        sourceMetadata: LnReaderOnlineBookDescriptor(
          pluginId: plugin.id,
          novelPath: novel.path,
          chapters: novel.chapters,
        ).encode(),
        chapterCount: rebuilt.chapterCount,
        chaptersJson: rebuilt.chaptersJson,
      );
    } finally {
      try {
        await temp.delete(recursive: true);
      } on FileSystemException {
        // 临时目录删不掉不影响书本身。
      }
    }
  }

  LnReaderOnlineEpubRequest _request({
    required LnReaderInstalledPlugin plugin,
    required LnReaderNovel novel,
    required String title,
    required String pendingText,
    LnReaderEpubImage? cover,
    LnReaderOnlineEpubReuse? reuse,
  }) => LnReaderOnlineEpubRequest(
    title: title,
    languageTag: lnReaderLanguageTag(plugin.lang),
    identifier: lnReaderBookIdentifier(plugin.id, novel.path),
    author: novel.author,
    description: novel.summary == null
        ? null
        : stripLnReaderHtml(novel.summary!),
    chapters: <({String name, String path})>[
      for (final LnReaderChapter chapter in novel.chapters)
        (name: chapter.name, path: chapter.path),
    ],
    pendingText: pendingText,
    cover: cover,
    reuse: reuse,
  );
}

/// 就地重建时从旧解压树搬已取过的章：旧树位置、旧描述符的章节路径（第 i 项
/// 就是旧树里的 `chapter-(i+1).xhtml`）、旧封面（相对 [extractDir]）。
typedef LnReaderOnlineEpubReuse = ({
  String extractDir,
  List<String> previousChapterPaths,
  String? coverPath,
});

/// 建 / 重建在线书 EPUB 的全部输入。只含可跨 isolate 的值（字符串、列表、
/// 记录、字节），交给 [buildLnReaderOnlineEpubInBackground]。
@immutable
class LnReaderOnlineEpubRequest {
  const LnReaderOnlineEpubRequest({
    required this.title,
    required this.languageTag,
    required this.identifier,
    required this.chapters,
    required this.pendingText,
    this.author,
    this.description,
    this.cover,
    this.reuse,
  });

  final String title;
  final String languageTag;
  final String identifier;
  final String? author;
  final String? description;

  /// 新章节列表（spine 顺序）。
  final List<({String name, String path})> chapters;

  /// 占位页上给读者看的说明。
  final String pendingText;

  /// 首次建书时取回的封面；就地重建时为 null，封面从 [reuse] 的旧树读。
  final LnReaderEpubImage? cover;

  /// null = 首次建书（全章占位）。
  final LnReaderOnlineEpubReuse? reuse;
}

/// 按 [request] 组装在线书 EPUB（同步）。就地重建时已取过的章按章节路径从旧
/// 解压树原样搬过去，其余章是占位页。
Uint8List buildLnReaderOnlineEpub(LnReaderOnlineEpubRequest request) {
  final LnReaderOnlineEpubReuse? reuse = request.reuse;
  final Map<String, int> oldIndexByPath = <String, int>{
    if (reuse != null)
      for (int i = 0; i < reuse.previousChapterPaths.length; i++)
        reuse.previousChapterPaths[i]: i,
  };
  final LnReaderEpubImage? cover =
      request.cover ??
      (reuse == null
          ? null
          : _readLnReaderCover(reuse.extractDir, reuse.coverPath));
  return LnReaderEpubAssembler.build(
    title: request.title,
    languageTag: request.languageTag,
    identifier: request.identifier,
    author: request.author,
    description: request.description,
    cover: cover,
    chapters: <LnReaderEpubChapter>[
      for (final ({String name, String path}) chapter in request.chapters)
        () {
          final int? oldIndex = oldIndexByPath[chapter.path];
          final ({String body, List<LnReaderEpubImage> images})? loaded =
              reuse == null || oldIndex == null
              ? null
              : readLnReaderLoadedChapter(reuse.extractDir, oldIndex);
          return (
            title: chapter.name,
            xhtmlBody:
                loaded?.body ?? lnReaderPendingChapterBody(request.pendingText),
            images: loaded?.images ?? const <LnReaderEpubImage>[],
          );
        }(),
    ],
  );
}

/// [buildLnReaderOnlineEpub] 放进一次性后台 isolate；产物经 `Isolate.exit` 交回。
///
/// 顶层函数：闭包只捕获 [request]，不把调用方（持有数据库句柄的
/// [LnReaderOnlineLibrary]）带过 isolate 边界。
Future<Uint8List> buildLnReaderOnlineEpubInBackground(
  LnReaderOnlineEpubRequest request,
) => Isolate.run<Uint8List>(
  () => buildLnReaderOnlineEpub(request),
  debugName: 'LnReaderOnlineEpub.build',
);

LnReaderEpubImage? _readLnReaderCover(String extractDir, String? coverPath) {
  if (coverPath == null || coverPath.isEmpty) return null;
  final File file = File(p.join(extractDir, coverPath));
  if (!file.existsSync()) return null;
  final Uint8List bytes = file.readAsBytesSync();
  final String? mediaType = sniffLnReaderImageMediaType(bytes);
  if (mediaType == null) return null;
  return (fileName: p.basename(coverPath), bytes: bytes, mediaType: mediaType);
}

/// 解压树里第 [index] 章（0 基）的正文文件。
File lnReaderOnlineChapterFile(String extractDir, int index) =>
    File(p.join(extractDir, 'OEBPS', 'chapter-${index + 1}.xhtml'));

/// 读一章已取过的正文（`<section>` 内部）与它引用的插图；占位章 / 读不到返回
/// null。在线书与网页小说书就地重建解压树时用它把已取过的章原样搬过去。
({String body, List<LnReaderEpubImage> images})? readLnReaderLoadedChapter(
  String extractDir,
  int index,
) {
  final File file = lnReaderOnlineChapterFile(extractDir, index);
  if (!file.existsSync()) return null;
  final String xhtml = file.readAsStringSync();
  if (xhtml.contains(kLnReaderPendingChapterAttribute)) return null;
  final int start = xhtml.indexOf('<section>\n');
  final int end = xhtml.lastIndexOf('\n</section>');
  if (start < 0 || end <= start) return null;
  final String body = xhtml.substring(start + '<section>\n'.length, end);
  final List<LnReaderEpubImage> images = <LnReaderEpubImage>[];
  for (final RegExpMatch match in RegExp(
    r'src="(images/[^"]+)"',
  ).allMatches(body)) {
    final String name = match.group(1)!;
    final File image = File(p.join(extractDir, 'OEBPS', name));
    if (!image.existsSync()) continue;
    final Uint8List bytes = image.readAsBytesSync();
    final String? mediaType = sniffLnReaderImageMediaType(bytes);
    if (mediaType == null) continue;
    images.add((fileName: name, bytes: bytes, mediaType: mediaType));
  }
  return (body: body, images: images);
}

/// 在线书的插件没装 / 被删了：章节取不到。
class LnReaderOnlinePluginMissing implements Exception {
  const LnReaderOnlinePluginMissing(this.pluginId);

  final String pluginId;

  @override
  String toString() => 'LNReader plugin not installed: $pluginId';
}

/// 阅读器开书时调用：[row] 是在线小说书就给出它的按需取章加载器，否则 null。
///
/// [manager] 是惰性的——普通书不该为了这个判断把 LNReader 运行时（一个
/// headless WebView）拉起来。
///
/// [onlineSourcesAvailable] 没过（iOS 合规门 / 无 headless WebView 的平台）时一律
/// null：描述符会随备份恢复到这些平台，开书不得因此拉起在线小说宿主联网，书退化
/// 成普通书（没取过的章停在占位页）。
LnReaderOnlineChapterLoader? lnReaderOnlineChapterLoaderFor({
  required EpubBookRow? row,
  required String extractDir,
  required FushiDatabase database,
  required LnReaderManager Function() manager,
  bool? onlineSourcesAvailable,
}) {
  if (!(onlineSourcesAvailable ?? isNovelOnlineSourcesAvailable)) return null;
  final LnReaderOnlineBookDescriptor? descriptor =
      LnReaderOnlineBookDescriptor.tryParse(row?.sourceMetadata);
  if (row == null || descriptor == null) return null;
  final LnReaderManager resolved = manager();
  return LnReaderOnlineChapterLoader(
    manager: resolved,
    database: database,
    download: LnReaderBookDownload(
      manager: resolved,
      database: database,
      httpClientFactory: createAppHttpClient,
    ),
    bookKey: row.bookKey,
    extractDir: extractDir,
    descriptor: descriptor,
  );
}

/// 阅读器侧的按需取章：WebView 请求到一章的正文文件而它还是占位页时，经插件
/// 取正文、插图写回解压树，再把书行里这一章的字数补上。
///
/// 同一章并发请求只取一次；不同章串行取（骨架见
/// [SerialOnlineNovelChapterLoader]）。这一章有了正文就顺手预取下一章，顺序阅读
/// 翻到下一章时不用等网络。
class LnReaderOnlineChapterLoader extends SerialOnlineNovelChapterLoader {
  LnReaderOnlineChapterLoader({
    required this.manager,
    required this.database,
    required this.download,
    required this.bookKey,
    required this.extractDir,
    required this.descriptor,
  });

  final LnReaderManager manager;
  final FushiDatabase database;
  final LnReaderBookDownload download;
  final String bookKey;
  @override
  final String extractDir;
  final LnReaderOnlineBookDescriptor descriptor;

  /// 已把占位页换成正文、但阅读器还没经 [ensureLoaded] 确认过的章。后台预取的
  /// 章也记在这里：阅读器自己的相邻章预热可能在正文落盘前就把占位页读进了缓存，
  /// 翻到这一章时必须据此丢缓存、换字数，不能只看「这一次调用有没有亲手取」。
  final Map<int, OnlineNovelChapterLoaded> _unacknowledged =
      <int, OnlineNovelChapterLoaded>{};

  @override
  int get chapterLimit => descriptor.chapters.length;

  /// 确保 [filePath] 这一章已有正文。返回非 null = 占位页换成正文之后调用方还
  /// 没确认过（本次亲手取的，或后台预取的；调用方据此丢掉缓存、换上新字数）；
  /// 不是本书正文文件 / 早已确认过返回 null。取不到抛出。
  @override
  Future<OnlineNovelChapterLoaded?> ensureLoaded(String filePath) async {
    final int? index = chapterIndexForFile(filePath);
    if (index == null) return null;
    final OnlineNovelChapterLoaded? loaded = await ensureChapter(index);
    final OnlineNovelChapterLoaded? prefetched = _unacknowledged.remove(index);
    OnlineNovelChapterLoaded? result = loaded;
    if (result == null && prefetched != null) {
      // 预取时记下的字数是那一刻这个文件的。作品页之后可能已按新章节列表就地
      // 重建了解压树（连载更新），第 index 个文件换成了别的章 / 占位页：旧字数
      // 不能再交给阅读器写进进度与统计的坐标系。缓存照样要丢（文件确实变过），
      // 字数报「未知」；其余预取记录同样过期，一并作废。
      if (await _isStillChapter(index)) {
        result = prefetched;
      } else {
        _unacknowledged.clear();
        result = OnlineNovelChapterLoaded(index: index, characters: null);
      }
    }
    // 预取看的是「这一章现在有正文、阅读器正要读它」，不是「这一次亲手取了」：
    // 翻到已被预取的章时本次什么都没取，照样要接着预取再下一章，否则预取隔一章
    // 才生效一次。
    if (result != null && index + 1 < descriptor.chapters.length) {
      unawaited(
        ensureChapter(index + 1, background: true).then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            // 预取失败不打断阅读（翻到那一章时前台再取、再报），但要留痕。
            ErrorLogService.instance.log(
              'LnReaderOnlineChapterLoader.prefetch',
              error,
              stack,
            );
          },
        ),
      );
    }
    return result;
  }

  @override
  Future<OnlineNovelChapterLoaded?> loadChapter(int index) async {
    final File file = lnReaderOnlineChapterFile(extractDir, index);
    if (!file.existsSync()) return null;
    if (!(await file.readAsString()).contains(
      kLnReaderPendingChapterAttribute,
    )) {
      return null;
    }
    // ensureReady 而不是 initialise：state.json 读不出来时 initialise 不抛、已装
    // 列表是空占位，下面就会误报「插件没装」，把读盘错误藏起来。
    await manager.ensureReady();
    LnReaderInstalledPlugin? plugin;
    for (final LnReaderInstalledPlugin candidate in manager.installed) {
      if (candidate.id == descriptor.pluginId) plugin = candidate;
    }
    if (plugin == null) throw LnReaderOnlinePluginMissing(descriptor.pluginId);
    final LnReaderPluginInfo info = await manager.load(plugin);
    final LnReaderChapter chapter = descriptor.chapters[index];
    final HttpClient client = download.openClient();
    final LnReaderEpubChapter fetched;
    try {
      fetched = await download.fetchChapter(
        client: client,
        plugin: plugin,
        info: info,
        chapter: chapter,
        imagePrefix: lnReaderOnlineImagePrefix(chapter.path),
      );
    } finally {
      client.close(force: true);
    }
    // 取正文要等网络，这期间作品页可能已按新章节列表就地重建了解压树（连载
    // 更新）：第 index 章已不是这一章，写进去就是正文错位。以书行里的当前
    // 描述符为准再核一次，对不上就放弃这次结果（重进这一章会按新序号再取）。
    if (!await _isStillChapter(index) || !file.existsSync()) {
      // 之前预取时记下的字数也都是旧章节序号下的，一并作废。
      _unacknowledged.clear();
      return null;
    }
    for (final LnReaderEpubImage image in fetched.images) {
      await writeAtomically(
        File(p.join(extractDir, 'OEBPS', image.fileName)),
        image.bytes,
      );
    }
    await writeAtomically(
      file,
      utf8.encode(
        LnReaderEpubAssembler.chapterXhtml(
          title: chapter.name.trim().isEmpty ? '${index + 1}' : chapter.name,
          body: fetched.xhtmlBody,
          languageTag: lnReaderLanguageTag(plugin.lang),
        ),
      ),
    );
    final OnlineNovelChapterLoaded result = OnlineNovelChapterLoaded(
      index: index,
      characters: await _updateCharacterCount(index),
    );
    _unacknowledged[index] = result;
    return result;
  }

  /// 书行里的当前描述符第 [index] 章还是不是本加载器开书时认的那一章。
  Future<bool> _isStillChapter(int index) async {
    final LnReaderOnlineBookDescriptor? current =
        LnReaderOnlineBookDescriptor.tryParse(
          (await database.getEpubBook(bookKey))?.sourceMetadata,
        );
    return current != null &&
        index < current.chapters.length &&
        current.chapters[index].path == descriptor.chapters[index].path;
  }

  /// 书行里这一章的字数从占位页的换成正文的（书架总字数 / 进度百分比用它），
  /// 口径与导入时同一个函数（[EpubBook.chapterCharacterCount]）。返回新字数
  /// （阅读器据此换掉内存里那一章的字数）；书行已不在返回 null。
  Future<int?> _updateCharacterCount(int index) async {
    if (await database.getEpubBook(bookKey) == null) return null;
    final int count = await _chapterCharacterCountInBackground(
      extractDir,
      index,
    );
    // 读改写放进事务：阅读器后台整本重算的写回（`persistRecomputedChapterCharCounts`）
    // 也是对同一行 chaptersJson 的读改写。不串行的话，一方读到旧行、另一方中途
    // 写入、前者再整列写回，就把后者的值盖掉（正文字数被写回成占位页字数，或口径
    // 标记被冲掉）。数字在事务外算好，事务里只有两条 SQL。
    return database.transaction(() async {
      final EpubBookRow? row = await database.getEpubBook(bookKey);
      if (row == null) return null;
      final Object? decoded = jsonDecode(row.chaptersJson);
      if (decoded is! List<Object?> || index >= decoded.length) return count;
      final Object? entry = decoded[index];
      if (entry is! Map<String, Object?>) return count;
      entry['characters'] = count;
      await database.updateEpubBookChaptersJson(bookKey, jsonEncode(decoded));
      return count;
    });
  }
}

/// 后台 isolate 里数解压树第 [index] 章的字数（[EpubBook.chapterCharacterCount]）。
///
/// 顶层函数：方法里的 `Isolate.run` 闭包会和同一方法里引用 `this` 的闭包（事务）
/// 共享捕获上下文，把持有数据库句柄的加载器带过 isolate 边界、发送失败。
Future<int> _chapterCharacterCountInBackground(String extractDir, int index) =>
    Isolate.run(
      () => EpubParser.parseFromExtracted(
        extractDir,
      ).chapterCharacterCount(index),
    );
