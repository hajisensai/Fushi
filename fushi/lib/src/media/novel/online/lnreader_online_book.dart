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
    final Uint8List bytes = _assemble(
      plugin: plugin,
      novel: novel,
      title: title,
      cover: cover,
      bodyFor: (LnReaderChapter chapter) => (
        body: lnReaderPendingChapterBody(pendingText),
        images: const <LnReaderEpubImage>[],
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
    final Map<String, int> oldIndexByPath = <String, int>{
      for (int i = 0; i < descriptor.chapters.length; i++)
        descriptor.chapters[i].path: i,
    };
    final LnReaderEpubImage? cover = _readCover(row);
    final Uint8List bytes = _assemble(
      plugin: plugin,
      novel: novel,
      title: row.title,
      cover: cover,
      bodyFor: (LnReaderChapter chapter) {
        final int? oldIndex = oldIndexByPath[chapter.path];
        final ({String body, List<LnReaderEpubImage> images})? loaded =
            oldIndex == null ? null : _readLoadedChapter(extractDir, oldIndex);
        return loaded ??
            (
              body: lnReaderPendingChapterBody(pendingText),
              images: const <LnReaderEpubImage>[],
            );
      },
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

  Uint8List _assemble({
    required LnReaderInstalledPlugin plugin,
    required LnReaderNovel novel,
    required String title,
    required LnReaderEpubImage? cover,
    required ({String body, List<LnReaderEpubImage> images}) Function(
      LnReaderChapter chapter,
    )
    bodyFor,
  }) {
    return LnReaderEpubAssembler.build(
      title: title,
      languageTag: lnReaderLanguageTag(plugin.lang),
      identifier: lnReaderBookIdentifier(plugin.id, novel.path),
      author: novel.author,
      description: novel.summary == null
          ? null
          : stripLnReaderHtml(novel.summary!),
      cover: cover,
      chapters: <LnReaderEpubChapter>[
        for (final LnReaderChapter chapter in novel.chapters)
          () {
            final ({String body, List<LnReaderEpubImage> images}) content =
                bodyFor(chapter);
            return (
              title: chapter.name,
              xhtmlBody: content.body,
              images: content.images,
            );
          }(),
      ],
    );
  }

  LnReaderEpubImage? _readCover(EpubBookRow row) {
    final String? coverPath = row.coverPath;
    if (coverPath == null || coverPath.isEmpty) return null;
    final File file = File(p.join(row.extractDir, coverPath));
    if (!file.existsSync()) return null;
    final Uint8List bytes = file.readAsBytesSync();
    final String? mediaType = sniffLnReaderImageMediaType(bytes);
    if (mediaType == null) return null;
    return (
      fileName: p.basename(coverPath),
      bytes: bytes,
      mediaType: mediaType,
    );
  }
}

/// 解压树里第 [index] 章（0 基）的正文文件。
File lnReaderOnlineChapterFile(String extractDir, int index) =>
    File(p.join(extractDir, 'OEBPS', 'chapter-${index + 1}.xhtml'));

/// 读一章已取过的正文（`<section>` 内部）与它引用的插图；占位章 / 读不到返回
/// null。
({String body, List<LnReaderEpubImage> images})? _readLoadedChapter(
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
/// [onlineSourcesAvailable] 没过（iOS 合规门 / Linux 无 headless WebView）时一律
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
/// 同一章并发请求只取一次；不同章串行取（网文站普遍限流，并发只换来 429）。
/// 取完一章顺手预取下一章，顺序阅读翻到下一章时不用等网络。
class LnReaderOnlineChapterLoader {
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
  final String extractDir;
  final LnReaderOnlineBookDescriptor descriptor;

  final Map<int, Future<bool>> _inflight = <int, Future<bool>>{};

  /// 已把占位页换成正文、但阅读器还没经 [ensureLoaded] 确认过的章。后台预取的
  /// 章也记在这里：阅读器自己的相邻章预热可能在正文落盘前就把占位页读进了缓存，
  /// 翻到这一章时必须据此丢缓存，不能只看「这一次调用有没有亲手取」。
  final Set<int> _unacknowledged = <int>{};
  Future<void> _queue = Future<void>.value();

  /// 排队中的取章（含后台预取）全部结束。
  @visibleForTesting
  Future<void> whenIdle() async {
    Future<void> seen;
    do {
      seen = _queue;
      await seen;
    } while (!identical(seen, _queue));
  }

  /// [filePath] 对应的章（0 基）；不是本书的正文文件返回 null。
  int? chapterIndexForFile(String filePath) {
    final String relative = p
        .relative(p.normalize(filePath), from: p.normalize(extractDir))
        .replaceAll(r'\', '/');
    final RegExpMatch? match = RegExp(
      r'^OEBPS/chapter-(\d+)\.xhtml$',
    ).firstMatch(relative);
    if (match == null) return null;
    final int index = int.parse(match.group(1)!) - 1;
    if (index < 0 || index >= descriptor.chapters.length) return null;
    return index;
  }

  /// 确保 [filePath] 这一章已有正文。返回 true = 占位页换成正文之后调用方还
  /// 没确认过（本次亲手取的，或后台预取的；调用方据此丢掉缓存）；不是本书正文
  /// 文件 / 早已确认过返回 false。取不到抛出。
  Future<bool> ensureLoaded(String filePath) async {
    final int? index = chapterIndexForFile(filePath);
    if (index == null) return false;
    final bool loaded = await _ensureIndex(index);
    final bool unacknowledged = _unacknowledged.remove(index);
    if (loaded && index + 1 < descriptor.chapters.length) {
      unawaited(
        _ensureIndex(index + 1).then<void>(
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
    return loaded || unacknowledged;
  }

  Future<bool> _ensureIndex(int index) {
    final Future<bool>? running = _inflight[index];
    if (running != null) return running;
    final Completer<bool> completer = Completer<bool>();
    _inflight[index] = completer.future;
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _load(index));
      } on Object catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _inflight.remove(index);
      }
    });
    return completer.future;
  }

  Future<bool> _load(int index) async {
    final File file = lnReaderOnlineChapterFile(extractDir, index);
    if (!file.existsSync()) return false;
    if (!(await file.readAsString()).contains(
      kLnReaderPendingChapterAttribute,
    )) {
      return false;
    }
    await manager.initialise();
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
    final LnReaderOnlineBookDescriptor? current =
        LnReaderOnlineBookDescriptor.tryParse(
          (await database.getEpubBook(bookKey))?.sourceMetadata,
        );
    if (current == null ||
        index >= current.chapters.length ||
        current.chapters[index].path != chapter.path ||
        !file.existsSync()) {
      return false;
    }
    for (final LnReaderEpubImage image in fetched.images) {
      await _writeAtomically(
        File(p.join(extractDir, 'OEBPS', image.fileName)),
        image.bytes,
      );
    }
    await _writeAtomically(
      file,
      utf8.encode(
        LnReaderEpubAssembler.chapterXhtml(
          title: chapter.name.trim().isEmpty ? '${index + 1}' : chapter.name,
          body: fetched.xhtmlBody,
          languageTag: lnReaderLanguageTag(plugin.lang),
        ),
      ),
    );
    await _updateCharacterCount(index);
    _unacknowledged.add(index);
    return true;
  }

  /// 书行里这一章的字数从占位页的换成正文的（书架总字数 / 进度百分比用它），
  /// 口径与导入时同一个函数（[EpubBook.chapterCharacterCount]）。
  Future<void> _updateCharacterCount(int index) async {
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    if (row == null) return;
    final String dir = extractDir;
    final int count = await Isolate.run(
      () => EpubParser.parseFromExtracted(dir).chapterCharacterCount(index),
    );
    final Object? decoded = jsonDecode(row.chaptersJson);
    if (decoded is! List<Object?> || index >= decoded.length) return;
    final Object? entry = decoded[index];
    if (entry is! Map<String, Object?>) return;
    entry['characters'] = count;
    await database.updateEpubBookChaptersJson(bookKey, jsonEncode(decoded));
  }

  static Future<void> _writeAtomically(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final File temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  }
}
