import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show StringExpressionOperators, Value;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/web/web_comic_chapter.dart'
    show WebComicCookie;
import 'package:fushi/src/media/manga/web/web_comic_scanner.dart'
    show readWebComicCookies;
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart'
    show lnReaderSafeFileName, removeLnReaderImageReference;
import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart'
    show LnReaderFetchBridge, isLnReaderBlockedHost;
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart'
    show
        kLnReaderPendingChapterAttribute,
        lnReaderOnlineChapterFile,
        lnReaderPendingChapterBody,
        readLnReaderLoadedChapter;
import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi/src/media/novel/web/web_novel_gate.dart';
import 'package:fushi/src/media/novel/web/web_novel_page_fetcher.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一章要写进 EPUB 的内容：正文 XHTML（图片已换成书内文件名）+ 图片字节。
typedef WebNovelChapterContent = ({
  String xhtml,
  List<LnReaderEpubImage> images,
});

/// 取一张正文图（测试缝；生产 = [fetchWebNovelImage]）。取不到返回 null（正文里
/// 删掉这张图的引用，书照样生成）。
typedef WebNovelImageFetch =
    Future<Uint8List?> Function(Uri url, {required Uri referer});

/// 网页小说书的 EPUB 标识（`dc:identifier`）。
String webNovelBookIdentifier(String workKey) => 'web-novel:$workKey';

/// 正文图在书内的文件名：按图片 URL 派生（同一张图跨章只存一份，重建时不撞名）。
String webNovelImageFileName(String url, String mediaType) {
  final String digest = sha1
      .convert(utf8.encode(url))
      .toString()
      .substring(0, 16);
  final String ext = switch (mediaType) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'jpg',
  };
  return 'images/w$digest.$ext';
}

/// 网页小说书的书架侧：建书、并章、就地重建、追更占位。
///
/// 形态与 LNReader 在线书相同（[LnReaderEpubAssembler] 组装、`EpubImporter` 入库 /
/// 就地重建、`sourceMetadata` 存描述符），不另写一套 EPUB 生成。区别只在描述符：
/// 这里存的是 Rust 连载会话的**快照原文**（[WebNovelSnapshot.raw]），章节顺序、去重、
/// 下一章都以它为准。spine 第 i 项 = 快照第 i 章；快照有 `tailNext` 时末尾再挂一个
/// 「下一章」占位页，阅读器读到它时由 [WebNovelChapterLoader] 现取。
class WebNovelLibrary {
  WebNovelLibrary({
    required this.database,
    WebNovelImageFetch? fetchImage,
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
  }) : _fetchImage = fetchImage ?? fetchWebNovelImage,
       _importEpub = importEpub ?? _defaultImport,
       _rebuildInPlace = rebuildInPlace ?? EpubImporter.rebuildExtractedInPlace;

  final FushiDatabase database;
  final WebNovelImageFetch _fetchImage;
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

  /// 书架上这部作品（[workKey] 相同）的网页小说书；没有返回 null。
  Future<EpubBookRow?> findBook(String workKey) async {
    final List<EpubBookRow> rows =
        await (database.select(database.epubBooks)..where(
              (EpubBooks t) =>
                  t.sourceMetadata.like('%${WebNovelSnapshot.type}%'),
            ))
            .get();
    for (final EpubBookRow row in rows) {
      final WebNovelSnapshot? snapshot = WebNovelSnapshot.tryParse(
        row.sourceMetadata,
      );
      if (snapshot != null && snapshot.workKey == workKey) return row;
    }
    return null;
  }

  /// 把一页的提取结果落成可写进书的内容：按序号取正文图（带 Referer / 站点 cookie，
  /// 走全局代理），占位 src 换成书内文件名；取不到的图从正文里删掉引用。
  Future<WebNovelChapterContent> materialize(WebArticle article) async {
    String xhtml = article.xhtml;
    final List<LnReaderEpubImage> images = <LnReaderEpubImage>[];
    final Uri referer = Uri.parse(article.url);
    for (int i = 0; i < article.images.length; i++) {
      final String placeholder = '$kWebArticleImagePlaceholderPrefix$i';
      final Uri? url = Uri.tryParse(article.images[i]);
      final Uint8List? bytes = url == null
          ? null
          : await _fetchImage(url, referer: referer);
      final String? mediaType = bytes == null
          ? null
          : sniffLnReaderImageMediaType(bytes);
      if (bytes == null || mediaType == null) {
        xhtml = removeLnReaderImageReference(xhtml, placeholder);
        continue;
      }
      final String fileName = webNovelImageFileName(
        article.images[i],
        mediaType,
      );
      xhtml = xhtml.replaceAll('src="$placeholder"', 'src="$fileName"');
      images.add((fileName: fileName, bytes: bytes, mediaType: mediaType));
    }
    return (xhtml: xhtml, images: images);
  }

  /// 把会话快照 [snapshot]（刚喂进第 [chapterIndex] 章、内容 [content]）落到书架：
  /// 没有这部作品就新建一本，有就**就地重建**（书的身份 / 进度 / 合集 / 标签不变，
  /// 已取过的章按 URL 原样搬过去）。返回 bookKey。
  Future<String> save({
    required WebNovelSnapshot snapshot,
    required int chapterIndex,
    required WebNovelChapterContent content,
    required String pendingText,
    required String nextChapterTitle,
    EpubBookRow? existing,
  }) async {
    final Uint8List bytes = _assemble(
      snapshot: snapshot,
      title: existing?.title ?? _bookTitle(snapshot),
      nextChapterTitle: nextChapterTitle,
      bodyFor: (int i) {
        if (i == chapterIndex) {
          return (body: content.xhtml, images: content.images);
        }
        return existing == null
            ? null
            : _loadedFrom(existing, snapshot.chapters[i].url);
      },
      pendingText: pendingText,
    );
    if (existing == null) {
      final String bookKey = await _importEpub(
        db: database,
        bytes: bytes,
        fileName: '${lnReaderSafeFileName(_bookTitle(snapshot))}.epub',
        // 程序化入库：与同名的已有书并存（加后缀），不打断用户。
        policy: const DuplicatePolicy.suffix(),
      );
      await (database.update(
        database.epubBooks,
      )..where((EpubBooks t) => t.bookKey.equals(bookKey))).write(
        EpubBooksCompanion(sourceMetadata: Value<String?>(snapshot.raw)),
      );
      return bookKey;
    }
    await _rebuild(existing, bytes, snapshot.raw);
    return existing.bookKey;
  }

  /// 阅读器开书前调用：网页小说书的快照有下一章、而 spine 末尾还没有占位页时，
  /// 就地重建补上（追更：读到末尾就能拉下一章）。改了返回 true（调用方重读书行）。
  /// 不是网页小说书 / 合规门关 / 不需要时返回 false。
  Future<bool> ensureTrailingPlaceholder(
    EpubBookRow row, {
    required String pendingText,
    required String nextChapterTitle,
  }) async {
    if (!webNovelReaderActionAvailable()) return false;
    final WebNovelSnapshot? snapshot = WebNovelSnapshot.tryParse(
      row.sourceMetadata,
    );
    if (snapshot == null || snapshot.tailNext == null) return false;
    if (row.chapterCount > snapshot.chapters.length) return false;
    final Uint8List bytes = _assemble(
      snapshot: snapshot,
      title: row.title,
      nextChapterTitle: nextChapterTitle,
      bodyFor: (int i) => _loadedFrom(row, snapshot.chapters[i].url),
      pendingText: pendingText,
    );
    await _rebuild(row, bytes, snapshot.raw);
    return true;
  }

  String _bookTitle(WebNovelSnapshot snapshot) {
    final String? work = snapshot.workTitle?.trim();
    if (work != null && work.isNotEmpty) return work;
    final String first = snapshot.chapters.isEmpty
        ? ''
        : snapshot.chapters.first.title.trim();
    if (first.isNotEmpty) return first;
    return Uri.tryParse(snapshot.chapters.firstOrNull?.url ?? '')?.host ??
        'Web novel';
  }

  /// 旧书里 URL 为 [url] 的那一章的正文（按旧快照的章序找文件）。
  ({String body, List<LnReaderEpubImage> images})? _loadedFrom(
    EpubBookRow row,
    String url,
  ) {
    final WebNovelSnapshot? previous = WebNovelSnapshot.tryParse(
      row.sourceMetadata,
    );
    if (previous == null) return null;
    final int index = previous.chapters.indexWhere(
      (WebNovelChapter c) => c.url == url,
    );
    if (index < 0) return null;
    return readLnReaderLoadedChapter(row.extractDir, index);
  }

  Uint8List _assemble({
    required WebNovelSnapshot snapshot,
    required String title,
    required String nextChapterTitle,
    required ({String body, List<LnReaderEpubImage> images})? Function(int i)
    bodyFor,
    required String pendingText,
  }) {
    final List<LnReaderEpubChapter> chapters = <LnReaderEpubChapter>[];
    for (int i = 0; i < snapshot.chapters.length; i++) {
      final ({String body, List<LnReaderEpubImage> images})? loaded = bodyFor(
        i,
      );
      chapters.add((
        title: snapshot.chapters[i].title,
        // 正文丢了（旧书解压树缺文件）的章留占位：阅读器读到时按它的 URL 现取。
        xhtmlBody: loaded?.body ?? lnReaderPendingChapterBody(pendingText),
        images: loaded?.images ?? const <LnReaderEpubImage>[],
      ));
    }
    if (snapshot.tailNext != null) {
      chapters.add((
        title: nextChapterTitle,
        xhtmlBody: lnReaderPendingChapterBody(pendingText),
        images: const <LnReaderEpubImage>[],
      ));
    }
    return LnReaderEpubAssembler.build(
      title: title,
      languageTag: snapshot.lang ?? '',
      identifier: webNovelBookIdentifier(snapshot.workKey ?? title),
      author: snapshot.author,
      chapters: chapters,
    );
  }

  Future<void> _rebuild(EpubBookRow row, Uint8List bytes, String raw) async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'fushi-web-novel-',
    );
    try {
      final File epub = File(p.join(temp.path, 'book.epub'));
      await epub.writeAsBytes(bytes, flush: true);
      final ({int chapterCount, String chaptersJson, String? coverPath})
      rebuilt = await _rebuildInPlace(
        epubFilePath: epub.path,
        extractDir: row.extractDir,
      );
      await database.updateEpubBookMihonState(
        row.bookKey,
        sourceMetadata: raw,
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
}

/// 生产取图：带页面 Referer 与该站 cookie（与浏览器同一份），走全局代理；重定向
/// 手动跟、每一跳过本机 / 内网判据（正文图 URL 是页面给的不可信数据）。
Future<Uint8List?> fetchWebNovelImage(Uri url, {required Uri referer}) async {
  final HttpClient client = createAppHttpClient();
  try {
    List<WebComicCookie> cookies = const <WebComicCookie>[];
    try {
      cookies = await readWebComicCookies(url);
    } on Object {
      // 读不到 cookie（平台没实现 / 环境未建）：不带 cookie 照取。
    }
    Uri uri = url;
    late HttpClientResponse response;
    for (int hop = 0; ; hop++) {
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          isLnReaderBlockedHost(uri.host)) {
        return null;
      }
      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.userAgentHeader, LnReaderFetchBridge.defaultUserAgent)
        ..set(HttpHeaders.acceptHeader, 'image/*,*/*;q=0.8')
        ..set(HttpHeaders.refererHeader, referer.toString());
      if (cookies.isNotEmpty && hop == 0) {
        request.headers.set(
          HttpHeaders.cookieHeader,
          cookies.map((WebComicCookie c) => '${c.name}=${c.value}').join('; '),
        );
      }
      response = await request.close().timeout(const Duration(seconds: 30));
      final String? location = response.headers.value(
        HttpHeaders.locationHeader,
      );
      if (!response.isRedirect || location == null) break;
      await response.drain<void>();
      if (hop >= 5) return null;
      uri = uri.resolve(location);
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final BytesBuilder buffer = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 60),
    )) {
      buffer.add(chunk);
      if (buffer.length > 20 * 1024 * 1024) return null;
    }
    return buffer.takeBytes();
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 网页小说书没有下一章可取（快照里没有、或站点的「下一章」指回了目录）。
class WebNovelNoNextChapter implements Exception {
  const WebNovelNoNextChapter();

  @override
  String toString() => 'No next chapter is known for this web novel yet';
}

/// 取回的页没能并进这部作品（正文没取到 / 不是这部作品 / 章序对不上）。
class WebNovelChapterRejected implements Exception {
  const WebNovelChapterRejected(this.status);

  final WebNovelIngestStatus status;

  @override
  String toString() => 'Fetched page was not accepted: ${status.name}';
}

/// 阅读器开书时调用：[row] 是网页小说书就给出它的按需取章加载器，否则 null。
/// 合规门关（iOS）时一律 null：快照会随备份恢复过去，开书不得因此联网取页。
WebNovelChapterLoader? webNovelChapterLoaderFor({
  required EpubBookRow? row,
  required String extractDir,
  required FushiDatabase database,
  WebNovelPageFetcher fetcher = const HeadlessWebNovelPageFetcher(),
}) {
  if (row == null || !webNovelReaderActionAvailable()) return null;
  if (WebNovelSnapshot.tryParse(row.sourceMetadata) == null) return null;
  return WebNovelChapterLoader(
    database: database,
    library: WebNovelLibrary(database: database),
    fetcher: fetcher,
    bookKey: row.bookKey,
    extractDir: extractDir,
  );
}

/// 网页小说书的按需取章：阅读器请求到一章的正文文件而它还是占位页（多半是末尾的
/// 「下一章」）时，用无界面 WebView 取那一页的 HTML，喂给 Rust 连载会话，把正文与
/// 插图写回解压树、把新快照写回书行。spine 不在这里改（阅读器正开着这本书）：新的
/// 「下一章」占位在下次开书时由 [WebNovelLibrary.ensureTrailingPlaceholder] 补上。
///
/// 同一章并发请求只取一次；不同章串行取。
class WebNovelChapterLoader implements OnlineNovelChapterLoader {
  WebNovelChapterLoader({
    required this.database,
    required this.library,
    required this.fetcher,
    required this.bookKey,
    required this.extractDir,
    FushiWebCoreLibrary? core,
  }) : _core = core;

  final FushiDatabase database;
  final WebNovelLibrary library;
  final WebNovelPageFetcher fetcher;
  final String bookKey;
  final String extractDir;
  final FushiWebCoreLibrary? _core;

  final Map<int, Future<bool>> _inflight = <int, Future<bool>>{};
  Future<void> _queue = Future<void>.value();

  /// 排队中的取章全部结束。
  @visibleForTesting
  Future<void> whenIdle() async {
    Future<void> seen;
    do {
      seen = _queue;
      await seen;
    } while (!identical(seen, _queue));
  }

  @override
  int? chapterIndexForFile(String filePath) {
    final String relative = p
        .relative(p.normalize(filePath), from: p.normalize(extractDir))
        .replaceAll(r'\', '/');
    final RegExpMatch? match = RegExp(
      r'^OEBPS/chapter-(\d+)\.xhtml$',
    ).firstMatch(relative);
    if (match == null) return null;
    final int index = int.parse(match.group(1)!) - 1;
    return index < 0 ? null : index;
  }

  @override
  Future<bool> ensureLoaded(String filePath) {
    final int? index = chapterIndexForFile(filePath);
    if (index == null) return Future<bool>.value(false);
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
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    final WebNovelSnapshot? snapshot = WebNovelSnapshot.tryParse(
      row?.sourceMetadata,
    );
    if (row == null || snapshot == null) return false;
    final String? target = index < snapshot.chapters.length
        ? snapshot.chapters[index].url
        : (index == snapshot.chapters.length ? snapshot.tailNext : null);
    if (target == null) throw const WebNovelNoNextChapter();

    final WebNovelFetchedPage page = await fetcher.fetch(Uri.parse(target));
    final WebNovelSession session = WebNovelSession.open(
      snapshot: snapshot.raw,
      library: _core,
    );
    final WebNovelIngest ingest;
    final WebNovelSnapshot updated;
    try {
      ingest = await session.ingest(page.html, page.url);
      updated = session.snapshot();
    } finally {
      session.close();
    }
    // 只认「这一页恰好落在请求的那个位置」：站点的下一章链接绕回旧章、或取回的是
    // 验证页时，写进来就是正文错位。
    if (!ingest.status.accepted || ingest.index != index) {
      throw WebNovelChapterRejected(ingest.status);
    }
    final WebNovelChapterContent content = await library.materialize(
      ingest.article,
    );
    // 取页要等网络：这期间书行可能被别处改过（浏览器里又并进了一章），以当前书行
    // 为准再核一次，对不上就放弃这次结果。
    final EpubBookRow? current = await database.getEpubBook(bookKey);
    if (current == null || current.sourceMetadata != snapshot.raw) {
      return false;
    }
    for (final LnReaderEpubImage image in content.images) {
      await _writeAtomically(
        File(p.join(extractDir, 'OEBPS', image.fileName)),
        image.bytes,
      );
    }
    await _writeAtomically(
      file,
      utf8.encode(
        LnReaderEpubAssembler.chapterXhtml(
          title: ingest.article.title.trim().isEmpty
              ? '${index + 1}'
              : ingest.article.title,
          body: content.xhtml,
          languageTag: updated.lang ?? '',
        ),
      ),
    );
    final ({int chapterCount, String chaptersJson, String? coverPath})
    reparsed = await EpubImporter.reparseExtractedBook(extractDir);
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.raw,
      chapterCount: reparsed.chapterCount,
      chaptersJson: reparsed.chaptersJson,
    );
    return true;
  }

  static Future<void> _writeAtomically(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final File temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  }
}

/// 开书前的准备（阅读器调用）：网页小说书补末尾「下一章」占位。失败只记日志、
/// 不挡开书。返回更新后的书行（没改返回原行）。
Future<EpubBookRow?> prepareWebNovelBookForReading({
  required FushiDatabase database,
  required EpubBookRow? row,
  required String pendingText,
  required String nextChapterTitle,
  WebNovelLibrary? library,
}) async {
  if (row == null || WebNovelSnapshot.tryParse(row.sourceMetadata) == null) {
    return row;
  }
  try {
    final bool changed = await (library ?? WebNovelLibrary(database: database))
        .ensureTrailingPlaceholder(
          row,
          pendingText: pendingText,
          nextChapterTitle: nextChapterTitle,
        );
    if (!changed) return row;
    return await database.getEpubBook(row.bookKey) ?? row;
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('prepareWebNovelBookForReading', error, stack);
    return row;
  }
}
