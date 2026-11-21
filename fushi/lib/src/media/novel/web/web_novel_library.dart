import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
    show webComicCookieHeader;
import 'package:fushi/src/media/manga/web/web_comic_scanner.dart'
    show readWebComicCookies;
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart'
    show lnReaderSafeFileName;
import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart'
    show LnReaderFetchBridge, guardLnReaderConnections, isLnReaderBlockedHost;
import 'package:fushi/src/media/novel/online/lnreader_missing_images.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart'
    show
        kLnReaderPendingChapterAttribute,
        lnReaderOnlineChapterFile,
        lnReaderPendingChapterBody,
        readLnReaderLoadedChapter;
import 'package:fushi/src/media/novel/online/online_novel_chapter_loader.dart';
import 'package:fushi/src/media/novel/online/online_novel_missing_images.dart';
import 'package:fushi/src/media/novel/web/web_novel_gate.dart';
import 'package:fushi/src/media/novel/web/web_novel_page_fetcher.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一章要写进 EPUB 的内容：正文 XHTML（图片已换成书内文件名）+ 图片字节。
typedef WebNovelChapterContent = ({
  String xhtml,
  List<LnReaderEpubImage> images,
});

/// 取一张正文图（测试缝；生产 = [fetchWebNovelImage]）。取不到返回 null（正文里
/// 留缺图占位，书照样生成，阅读器打开时提示并补取）。
typedef WebNovelImageFetch =
    Future<Uint8List?> Function(Uri url, {required Uri referer});

/// 网页小说书的 EPUB 标识（`dc:identifier`）。
String webNovelBookIdentifier(String workKey) => 'web-novel:$workKey';

/// 正文图在书内的文件名：按图片 URL 派生（同一张图跨章只存一份，重建时不撞名）。
String webNovelImageFileName(String url, String mediaType) {
  final String ext = switch (mediaType) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'jpg',
  };
  return '${webNovelImageKey(url)}.$ext';
}

/// [webNovelImageFileName] 去掉扩展名：取不到的图还不知道格式，缺图占位用它当键，
/// 补到后再按格式定真文件名。
String webNovelImageKey(String url) {
  final String digest = sha1
      .convert(utf8.encode(url))
      .toString()
      .substring(0, 16);
  return 'images/w$digest';
}

/// 旧书里按 URL 找已取过的那一章正文；没有（新章 / 旧书缺文件）返回 null。
typedef _LoadedChapterLookup =
    ({String body, List<LnReaderEpubImage> images})? Function(String url);

/// 网页小说书的书架侧：建书、并章、就地重建、追更占位。
///
/// 形态与 LNReader 在线书相同（[LnReaderEpubAssembler] 组装、`EpubImporter` 入库 /
/// 就地重建、`sourceMetadata` 存描述符），不另写一套 EPUB 生成。区别只在描述符：
/// 这里存的是 Rust 连载会话的**快照原文**（[WebNovelSnapshot.raw]），章节顺序、去重、
/// 下一章都以它为准。spine 第 i 项 = 快照第 i 章；快照有 `tailNext` 时末尾再挂一个
/// 「下一章」占位页，阅读器读到它时由 [WebNovelChapterLoader] 现取，取回后它在
/// spine 末尾接着挂下一个占位（阅读器会话内续拉，novel-d6）。
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
  /// 走全局代理），占位 src 换成书内文件名；取不到的图换成缺图占位（记下原图地址
  /// 与引用页，阅读器打开时提示并补取，见 [WebNovelChapterLoader.retryMissingImages]）。
  Future<WebNovelChapterContent> materialize(WebArticle article) async {
    String xhtml = article.xhtml;
    final List<LnReaderEpubImage> images = <LnReaderEpubImage>[];
    final Uri referer = Uri.parse(article.url);
    for (int i = 0; i < article.images.length; i++) {
      final String placeholder = '$kWebArticleImagePlaceholderPrefix$i';
      final String source = article.images[i];
      final LnReaderEpubImage? image = await _fetchInto(
        source,
        referer: referer,
      );
      if (image == null) {
        xhtml = replaceLnReaderImageWithMissingMarker(
          xhtml,
          fileName: webNovelImageKey(source),
          src: placeholder,
          url: source,
          referer: article.url,
        );
        continue;
      }
      xhtml = xhtml.replaceAll('src="$placeholder"', 'src="${image.fileName}"');
      images.add(image);
    }
    return (xhtml: xhtml, images: images);
  }

  /// 补取一张缺图（[WebNovelChapterLoader] 用）：与 [materialize] 同一条取图路径，
  /// 引用页取占位里记下的，没有就用 [fallbackReferer]（这一章的页地址）。
  Future<LnReaderEpubImage?> fetchMissingImage(
    LnReaderMissingImage image, {
    required String fallbackReferer,
  }) {
    final Uri? referer = Uri.tryParse(image.referer ?? fallbackReferer);
    if (referer == null) return Future<LnReaderEpubImage?>.value();
    return _fetchInto(image.url, referer: referer);
  }

  /// 取 [source] 这张图、嗅探格式、定书内文件名；取不到 / 不是图片返回 null。
  Future<LnReaderEpubImage?> _fetchInto(
    String source, {
    required Uri referer,
  }) async {
    final Uri? url = Uri.tryParse(source);
    if (url == null) return null;
    final Uint8List? bytes = await _fetchImage(url, referer: referer);
    if (bytes == null) return null;
    final String? mediaType = sniffLnReaderImageMediaType(bytes);
    if (mediaType == null) return null;
    return (
      fileName: webNovelImageFileName(source, mediaType),
      bytes: bytes,
      mediaType: mediaType,
    );
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
    final Uint8List bytes = await buildWebNovelEpubInBackground(
      WebNovelEpubRequest(
        snapshot: snapshot,
        title: existing?.title ?? _bookTitle(snapshot),
        nextChapterTitle: nextChapterTitle,
        pendingText: pendingText,
        previous: existing == null
            ? null
            : (
                sourceMetadata: existing.sourceMetadata,
                extractDir: existing.extractDir,
              ),
        fresh: (index: chapterIndex, content: content),
      ),
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
    final Uint8List bytes = await buildWebNovelEpubInBackground(
      WebNovelEpubRequest(
        snapshot: snapshot,
        title: row.title,
        nextChapterTitle: nextChapterTitle,
        pendingText: pendingText,
        previous: (
          sourceMetadata: row.sourceMetadata,
          extractDir: row.extractDir,
        ),
      ),
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

/// 一次「组装网页小说书 EPUB」要的全部输入（都是可跨 isolate 拷贝的纯数据）。
@immutable
class WebNovelEpubRequest {
  const WebNovelEpubRequest({
    required this.snapshot,
    required this.title,
    required this.nextChapterTitle,
    required this.pendingText,
    this.previous,
    this.fresh,
  });

  /// spine 以它为准：第 i 项 = 快照第 i 章，有 `tailNext` 时末尾挂「下一章」占位。
  final WebNovelSnapshot snapshot;
  final String title;
  final String nextChapterTitle;
  final String pendingText;

  /// 就地重建时的旧书：旧快照原文（`sourceMetadata`）与解压树。已取过的章按 URL
  /// 从旧树里原样搬过来；没有（新建书）为 null。
  final ({String? sourceMetadata, String extractDir})? previous;

  /// 刚取回的那一章（第 `index` 章用它，不读旧树）。
  final ({int index, WebNovelChapterContent content})? fresh;
}

/// 组装网页小说书的 EPUB 字节：逐章从旧解压树读已取过的正文（含图片）、打 ZIP。
///
/// 读盘 + 打包是同步的，章数 / 图片一多就是几百毫秒到几秒，只能在后台 isolate 里跑
/// （[buildWebNovelEpubInBackground]）；公开给测试直接调。
Uint8List buildWebNovelEpub(WebNovelEpubRequest request) {
  final WebNovelSnapshot snapshot = request.snapshot;
  final _LoadedChapterLookup? loadedFrom = request.previous == null
      ? null
      : _loadedChapterLookup(
          request.previous!.sourceMetadata,
          request.previous!.extractDir,
        );
  final ({int index, WebNovelChapterContent content})? fresh = request.fresh;
  final List<LnReaderEpubChapter> chapters = <LnReaderEpubChapter>[];
  for (int i = 0; i < snapshot.chapters.length; i++) {
    final ({String body, List<LnReaderEpubImage> images})? loaded =
        fresh != null && fresh.index == i
        ? (body: fresh.content.xhtml, images: fresh.content.images)
        : loadedFrom?.call(snapshot.chapters[i].url);
    chapters.add((
      title: snapshot.chapters[i].title,
      // 正文丢了（旧书解压树缺文件）的章留占位：阅读器读到时按它的 URL 现取。
      xhtmlBody:
          loaded?.body ?? lnReaderPendingChapterBody(request.pendingText),
      images: loaded?.images ?? const <LnReaderEpubImage>[],
    ));
  }
  if (snapshot.tailNext != null) {
    chapters.add((
      title: request.nextChapterTitle,
      xhtmlBody: lnReaderPendingChapterBody(request.pendingText),
      images: const <LnReaderEpubImage>[],
    ));
  }
  return LnReaderEpubAssembler.build(
    title: request.title,
    languageTag: snapshot.lang ?? '',
    identifier: webNovelBookIdentifier(snapshot.workKey ?? request.title),
    author: snapshot.author,
    chapters: chapters,
  );
}

/// [buildWebNovelEpub] 放进一次性后台 isolate（#3722 c40 遗留：以前网页小说书的
/// 新建 / 就地重建在 UI isolate 上同步读旧解压树的每一章、再同步打 ZIP，长连载
/// 追一章界面就停一下）。产物经 `Isolate.exit` 交回，不拷贝。
Future<Uint8List> buildWebNovelEpubInBackground(WebNovelEpubRequest request) =>
    Isolate.run<Uint8List>(
      () => buildWebNovelEpub(request),
      debugName: 'web-novel-epub',
    );

/// 旧书的「URL → 那一章已取过的正文」查找（按旧快照的章序找文件）。
///
/// 旧快照只解析一次、建好 URL → 章序表再逐章查：重建要对新快照的每一章各查
/// 一次，逐章重新解析快照 + 线性找 URL 是章数的平方（gap-novelmisc-5）。同一
/// URL 在旧快照里重复时取第一次出现的章序（与原先 `indexWhere` 一致）。
_LoadedChapterLookup _loadedChapterLookup(
  String? previousSourceMetadata,
  String extractDir,
) {
  final WebNovelSnapshot? previous = WebNovelSnapshot.tryParse(
    previousSourceMetadata,
  );
  if (previous == null) return (String url) => null;
  final Map<String, int> indexByUrl = <String, int>{};
  for (int i = 0; i < previous.chapters.length; i++) {
    indexByUrl.putIfAbsent(previous.chapters[i].url, () => i);
  }
  return (String url) {
    final int? index = indexByUrl[url];
    return index == null ? null : readLnReaderLoadedChapter(extractDir, index);
  };
}

/// 生产取图：带页面 Referer 与该站 cookie（与浏览器同一份），走全局代理；重定向
/// 手动跟、每一跳过本机判据（正文图 URL 是页面给的不可信数据）。
Future<Uint8List?> fetchWebNovelImage(Uri url, {required Uri referer}) async {
  final HttpClient client = createAppHttpClient();
  // 名字层判据挡不住解析到本机的外部域名：建连接时按解析后的地址再判一次。
  guardLnReaderConnections(client);
  try {
    // Cookie 取正文页（[referer]）站点的，再按 RFC 6265 对图片地址筛：直接按图片
    // URL 读 cookie 的话，页面放一张指向别的站的 <img>，Fushi 就会带着那个站的全部
    // cookie 去请求（跨站请求伪造）。
    String? cookieHeader;
    try {
      cookieHeader = webComicCookieHeader(
        imageUrl: url,
        pageUrl: referer,
        cookies: await readWebComicCookies(referer),
      );
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
      if (cookieHeader != null && hop == 0) {
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
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
/// [pendingText] / [nextChapterTitle] 与开书补占位（[prepareWebNovelBookForReading]）
/// 用同一套文案：取回末尾一章后在 spine 末尾续挂的新占位页用它们。
WebNovelChapterLoader? webNovelChapterLoaderFor({
  required EpubBookRow? row,
  required String extractDir,
  required FushiDatabase database,
  required String pendingText,
  required String nextChapterTitle,
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
    pendingText: pendingText,
    nextChapterTitle: nextChapterTitle,
  );
}

/// 网页小说书的按需取章：阅读器请求到一章的正文文件而它还是占位页（多半是末尾的
/// 「下一章」）时，用无界面 WebView 取那一页的 HTML，喂给 Rust 连载会话，把正文与
/// 插图写回解压树、把新快照写回书行。
///
/// 取的是末尾的「下一章」占位、站点又给出了再下一章时，在 spine 末尾**追加**一个
/// 新的占位（novel-d6）：只新增一个章节文件、给目录三件套各加一项（顺带把刚取回
/// 那一章的目录标题从占位标题换成章名），已有章的文件一个不动——阅读器正开着
/// 这本书、正从这棵解压树取文件，不能像 [WebNovelLibrary.save] 那样整本就地重建。
/// 结果里带上新的全书字数（[OnlineNovelChapterLoaded.grownSpineCharacters]），
/// 阅读器据此把新章并进已打开的书，读完这一章就能接着翻，不用重开书。
///
/// 同一章并发请求只取一次；不同章串行取（骨架见
/// [SerialOnlineNovelChapterLoader]）。不预取：每取一页要起一个无界面 WebView，
/// 目标地址又靠上一章 ingest 出来的 `tailNext`，提前取既贵又会改快照。
///
/// 正文图单张没取到时章节文件里留缺图占位（[WebNovelLibrary.materialize]），阅读器
/// 经 [OnlineNovelMissingImagesRetrier] 查缺图、补取（只重取图，不重取页）。
class WebNovelChapterLoader extends SerialOnlineNovelChapterLoader
    implements OnlineNovelMissingImagesRetrier {
  WebNovelChapterLoader({
    required this.database,
    required this.library,
    required this.fetcher,
    required this.bookKey,
    required this.extractDir,
    required this.pendingText,
    required this.nextChapterTitle,
    FushiWebCoreLibrary? core,
  }) : _core = core;

  final FushiDatabase database;
  final WebNovelLibrary library;
  final WebNovelPageFetcher fetcher;
  final String bookKey;
  @override
  final String extractDir;

  /// spine 末尾续挂的新占位页的正文文案与目录标题（见类注释）。
  final String pendingText;
  final String nextChapterTitle;
  final FushiWebCoreLibrary? _core;

  @override
  Future<OnlineNovelChapterLoaded?> ensureLoaded(String filePath) {
    final int? index = chapterIndexForFile(filePath);
    if (index == null) return Future<OnlineNovelChapterLoaded?>.value();
    return ensureChapter(index);
  }

  @override
  Future<OnlineNovelChapterLoaded?> loadChapter(int index) async {
    final File file = lnReaderOnlineChapterFile(extractDir, index);
    if (!file.existsSync()) return null;
    final bool pending = (await file.readAsString()).contains(
      kLnReaderPendingChapterAttribute,
    );
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    final WebNovelSnapshot? snapshot = WebNovelSnapshot.tryParse(
      row?.sourceMetadata,
    );
    if (row == null || snapshot == null) return null;
    // 「这一章已取过」以快照为准，不以文件为准：取章是先写正文文件、后写书行
    // （快照），两步之间失败 / 被杀时，末尾「下一章」的文件已是正文而快照里还没有
    // 这一章。只看文件就会永远短路——快照停在旧章数、`tailNext` 永远指着这一章，
    // 开书补占位也因 spine 比快照多一项而不补，这本书再也追不了更（BUG-4970）。
    // 这种不一致按占位处理：重新取页并章，把快照补齐。
    final bool snapshotBehindFile =
        index == snapshot.chapters.length && snapshot.tailNext != null;
    if (!pending && !snapshotBehindFile) return null;
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
      return null;
    }
    // 取的是末尾那一章（spine 里它是「下一章」占位）：目录标题换成章名；站点又
    // 给了再下一章就在 spine 末尾续挂新占位。补丁先算好再落盘：目录不是本装配器
    // 的格式时只放弃续挂（下次开书照旧由 ensureTrailingPlaceholder 整本补），
    // 正文照常写。
    final bool tail = index == snapshot.chapters.length;
    final bool grows = tail && updated.tailNext != null;
    final _PackagePatch? package = tail
        ? await _patchPackage(
            index: index,
            title: updated.chapters[index].title,
            grows: grows,
          )
        : null;
    for (final LnReaderEpubImage image in content.images) {
      await writeAtomically(
        File(p.join(extractDir, 'OEBPS', image.fileName)),
        image.bytes,
      );
    }
    await writeAtomically(
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
    if (package != null) await _writePackage(package, updated.lang ?? '');
    final ({int chapterCount, String chaptersJson, String? coverPath})
    reparsed = await EpubImporter.reparseExtractedBook(extractDir);
    await database.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: updated.raw,
      chapterCount: reparsed.chapterCount,
      chaptersJson: reparsed.chaptersJson,
    );
    final List<int?> counts = _chapterCharacters(reparsed.chaptersJson);
    final bool grew = package?.placeholderNumber != null;
    return OnlineNovelChapterLoaded(
      index: index,
      characters: index < counts.length ? counts[index] : null,
      grownSpineCharacters: grew && !counts.contains(null)
          ? List<int>.unmodifiable(counts.cast<int>())
          : null,
    );
  }

  /// 补取串行：同一章的两轮（自动 + 手动）不并发读改写同一个章节文件。
  final MissingImagesRetryQueue _retries = MissingImagesRetryQueue();

  @override
  Future<OnlineNovelMissingImages> missingImages(int index) async =>
      summarizeChapterMissingImages(
        index,
        index < 0
            ? const <LnReaderMissingImage>[]
            : await readChapterMissingImages(
                lnReaderOnlineChapterFile(extractDir, index),
                pendingAttribute: kLnReaderPendingChapterAttribute,
              ),
      );

  @override
  Future<OnlineNovelMissingImagesRetry> retryMissingImages(
    int index, {
    required bool automatic,
  }) => _retries.run(() => _retryMissingImages(index, automatic: automatic));

  Future<OnlineNovelMissingImagesRetry> _retryMissingImages(
    int index, {
    required bool automatic,
  }) async {
    // 这一章在快照里的页地址：取图的兜底引用页，也是「回来后还是不是这一章」
    // 的判据（取图期间浏览器里可能又并进了章、整本就地重建过）。
    final String? chapterUrl = await _snapshotChapterUrl(index);
    if (chapterUrl == null) {
      // 不在快照里（末尾「下一章」占位 / 书行已不在）：没有已取的正文，也就没有缺图。
      return OnlineNovelMissingImagesRetry(
        index: index,
        recovered: 0,
        remaining: (await missingImages(index)).count,
      );
    }
    return retryChapterMissingImages(
      index: index,
      extractDir: extractDir,
      file: lnReaderOnlineChapterFile(extractDir, index),
      automatic: automatic,
      pendingAttribute: kLnReaderPendingChapterAttribute,
      write: writeAtomically,
      fetch:
          (
            LnReaderMissingImage image,
            void Function(String reason) onFailure,
          ) async {
            final LnReaderEpubImage? fetched = await library.fetchMissingImage(
              image,
              fallbackReferer: chapterUrl,
            );
            if (fetched == null) {
              onFailure(Uri.tryParse(image.url)?.host ?? 'invalid url');
            }
            return fetched;
          },
      stillValid: () async => await _snapshotChapterUrl(index) == chapterUrl,
      onStillMissing: (int failed, int attempted, String? firstFailure) {
        ErrorLogService.instance.log(
          'WebNovelChapterLoader.retryMissingImages',
          '$chapterUrl: still missing $failed of $attempted images '
              '(first: $firstFailure)',
        );
      },
    );
  }

  /// 书行快照里第 [index] 章的页地址；不在快照里 / 书行已不在为 null。
  Future<String?> _snapshotChapterUrl(int index) async {
    final WebNovelSnapshot? snapshot = WebNovelSnapshot.tryParse(
      (await database.getEpubBook(bookKey))?.sourceMetadata,
    );
    if (snapshot == null || index < 0 || index >= snapshot.chapters.length) {
      return null;
    }
    return snapshot.chapters[index].url;
  }

  File _packageFile(String name) => File(p.join(extractDir, 'OEBPS', name));

  /// 算好刚取回的末尾第 [index] 章（0 基）对应的目录补丁：标题换成 [title]，
  /// [grows] 时再追加下一个占位。读不到目录 / 不是本装配器的格式返回 null（记日志）。
  Future<_PackagePatch?> _patchPackage({
    required int index,
    required String title,
    required bool grows,
  }) async {
    try {
      LnReaderPackageDocuments docs = (
        opf: await _packageFile('content.opf').readAsString(),
        ncx: await _packageFile('toc.ncx').readAsString(),
        nav: await _packageFile('nav.xhtml').readAsString(),
      );
      docs = LnReaderEpubAssembler.retitleChapter(
        docs,
        number: index + 1,
        title: title,
      );
      if (grows) {
        docs = LnReaderEpubAssembler.appendChapter(
          docs,
          number: index + 2,
          title: nextChapterTitle,
        );
      }
      return (docs: docs, placeholderNumber: grows ? index + 2 : null);
    } on FileSystemException catch (error, stack) {
      ErrorLogService.instance.log(
        'WebNovelChapterLoader.package',
        error,
        stack,
      );
      return null;
    } on FormatException catch (error, stack) {
      ErrorLogService.instance.log(
        'WebNovelChapterLoader.package',
        error,
        stack,
      );
      return null;
    }
  }

  /// 落盘顺序：新占位章文件 → nav → NCX → OPF。spine 以 OPF 为准，它最后写：
  /// 中途被杀只会留下一个没进 spine 的占位文件或多出一项的目录，书照样能开；
  /// 下次取这一章时（快照还没写上，BUG-4970 的那条路）补丁会重放，追加可重放。
  Future<void> _writePackage(_PackagePatch package, String languageTag) async {
    final int? placeholder = package.placeholderNumber;
    if (placeholder != null) {
      final File file = lnReaderOnlineChapterFile(extractDir, placeholder - 1);
      if (!await file.exists()) {
        await writeAtomically(
          file,
          utf8.encode(
            LnReaderEpubAssembler.chapterXhtml(
              title: nextChapterTitle,
              body: lnReaderPendingChapterBody(pendingText),
              languageTag: languageTag,
            ),
          ),
        );
      }
    }
    await writeAtomically(
      _packageFile('nav.xhtml'),
      utf8.encode(package.docs.nav),
    );
    await writeAtomically(
      _packageFile('toc.ncx'),
      utf8.encode(package.docs.ncx),
    );
    await writeAtomically(
      _packageFile('content.opf'),
      utf8.encode(package.docs.opf),
    );
  }

  /// 重解析出的 `chaptersJson` 里每章的字数（阅读器据此换掉内存里那一章的
  /// 字数）；条目形状不对的章为 null，整体形状不对返回空表。
  static List<int?> _chapterCharacters(String chaptersJson) {
    final Object? decoded = jsonDecode(chaptersJson);
    if (decoded is! List<Object?>) return const <int?>[];
    return <int?>[
      for (final Object? entry in decoded)
        if (entry is Map<String, Object?> &&
            entry['characters'] is int &&
            (entry['characters']! as int) >= 0)
          entry['characters']! as int
        else
          null,
    ];
  }
}

/// [WebNovelChapterLoader] 末尾取章时要落盘的目录补丁；[placeholderNumber] 是
/// 续挂的新占位章（1 基），不续挂为 null。
typedef _PackagePatch = ({
  LnReaderPackageDocuments docs,
  int? placeholderNumber,
});

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
