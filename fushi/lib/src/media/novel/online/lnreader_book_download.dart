import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';

import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_runtime.dart';

/// 用户中途取消下载。
class LnReaderDownloadCancelled implements Exception {
  const LnReaderDownloadCancelled();
}

/// 某一章抓取失败：带章节序号与名字，让用户知道从哪接着下。
class LnReaderChapterDownloadException implements Exception {
  const LnReaderChapterDownloadException({
    required this.index,
    required this.chapter,
    required this.cause,
  });

  /// 在本次所选范围里的 0 基序号。
  final int index;
  final LnReaderChapter chapter;
  final Object cause;

  @override
  String toString() => '${chapter.name}: $cause';
}

/// 下载进度：已完成章数 / 总章数。
typedef LnReaderDownloadProgress = void Function(int done, int total);

/// 把一部网文（选定章节）抓下来 → 打成 EPUB → 走既有 EPUB 导入进书架。
///
/// 入库后就是一本普通 EPUB：阅读器、查词、制卡、统计、同步全部复用，不另起一套
/// 「在线书」数据模型。章节按顺序逐章抓（网文站普遍限流，并发只会换来 429）。
/// 任何一章失败整次中止并报出是哪一章——**不静默跳章**，缺章的书比没有书更糟。
/// 插图单张失败只丢那一张图（正文完整优先）。
class LnReaderBookDownload {
  LnReaderBookDownload({
    required this.manager,
    required this.database,
    required HttpClient Function() httpClientFactory,
    this.isBlockedHost = isLnReaderBlockedHost,
    this.isBlockedAddress = isLnReaderBlockedAddress,
    Future<String> Function({
      required FushiDatabase db,
      required Uint8List bytes,
      required String fileName,
      required DuplicatePolicy policy,
    })?
    importEpub,
  }) : _httpClientFactory = httpClientFactory,
       _importEpub = importEpub ?? _defaultImport;

  final LnReaderManager manager;
  final FushiDatabase database;
  final HttpClient Function() _httpClientFactory;

  /// 插图 / 封面的主机拦截判据，与宿主桥同一条（插图地址同样来自插件）。
  final bool Function(String host) isBlockedHost;

  /// 连接层（解析后地址）拦截判据，与宿主桥同一条（[guardLnReaderConnections]）。
  final bool Function(InternetAddress address) isBlockedAddress;
  final Future<String> Function({
    required FushiDatabase db,
    required Uint8List bytes,
    required String fileName,
    required DuplicatePolicy policy,
  })
  _importEpub;

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

  /// 执行下载并入库，返回书的 bookKey。
  ///
  /// [isCancelled] 在每章之间检查；取消抛 [LnReaderDownloadCancelled]。
  /// 标题冲突按 [policy] 处理（交互入口传 `.ask(cb)`）。
  Future<String> run({
    required LnReaderInstalledPlugin plugin,
    required LnReaderNovel novel,
    required List<LnReaderChapter> chapters,
    required DuplicatePolicy policy,
    LnReaderDownloadProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (chapters.isEmpty) {
      throw ArgumentError.value(chapters, 'chapters', 'must not be empty');
    }
    final LnReaderPluginInfo info = await manager.load(plugin);
    final HttpClient client = openClient();
    try {
      final List<LnReaderEpubChapter> built = <LnReaderEpubChapter>[];
      onProgress?.call(0, chapters.length);
      for (int i = 0; i < chapters.length; i++) {
        if (isCancelled?.call() ?? false) {
          throw const LnReaderDownloadCancelled();
        }
        final LnReaderChapter chapter = chapters[i];
        try {
          built.add(
            await fetchChapter(
              client: client,
              plugin: plugin,
              info: info,
              chapter: chapter,
              imagePrefix: 'images/c${i + 1}-',
            ),
          );
        } on LnReaderDownloadCancelled {
          rethrow;
        } on Object catch (error) {
          throw LnReaderChapterDownloadException(
            index: i,
            chapter: chapter,
            cause: error,
          );
        }
        onProgress?.call(i + 1, chapters.length);
      }
      if (isCancelled?.call() ?? false) throw const LnReaderDownloadCancelled();

      final LnReaderEpubImage? cover = await fetchCover(
        client: client,
        plugin: plugin,
        info: info,
        novel: novel,
      );
      final String title = novel.name.trim().isEmpty
          ? chapters.first.name
          : novel.name.trim();
      final Uint8List bytes = LnReaderEpubAssembler.build(
        title: title,
        languageTag: lnReaderLanguageTag(plugin.lang),
        identifier: lnReaderBookIdentifier(plugin.id, novel.path),
        author: novel.author,
        description: novel.summary == null
            ? null
            : stripLnReaderHtml(novel.summary!),
        cover: cover,
        chapters: built,
      );
      return await _importEpub(
        db: database,
        bytes: bytes,
        fileName: '${lnReaderSafeFileName(title)}.epub',
        policy: policy,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 抓取用的 HttpClient：连接层按解析后地址拦本机（[guardLnReaderConnections]）。
  /// 调用方负责 `close`。
  HttpClient openClient() {
    final HttpClient client = _httpClientFactory();
    guardLnReaderConnections(client, isBlockedAddress: isBlockedAddress);
    return client;
  }

  /// 抓一章：插件取正文 → 规整成 XHTML 片段 → 逐张下插图（图片落在
  /// `$imagePrefix<n>.<ext>`）。插图单张失败只丢那一张（正文完整优先）；正文取
  /// 不到直接抛，由调用方决定是中止整次下载还是只报这一章。
  Future<LnReaderEpubChapter> fetchChapter({
    required HttpClient client,
    required LnReaderInstalledPlugin plugin,
    required LnReaderPluginInfo info,
    required LnReaderChapter chapter,
    required String imagePrefix,
  }) async {
    final LnReaderRuntime runtime = manager.runtime;
    final String html = await runtime.chapter(plugin.id, chapter.path);
    final String baseUrl = await runtime.resolveUrl(
      plugin.id,
      chapter.path,
      isNovel: false,
    );
    final LnReaderXhtml xhtml = await runtime.toXhtml(
      html,
      baseUrl: baseUrl,
      imagePrefix: imagePrefix,
    );
    final List<LnReaderEpubImage> images = <LnReaderEpubImage>[];
    String body = xhtml.xhtml;
    for (final ({String url, String fileName}) image in xhtml.images) {
      final LnReaderEpubImage? fetched = await _fetchImage(
        client,
        image.url,
        fileName: image.fileName,
        headers: <String, String>{
          ...info.imageHeaders,
          if (!info.imageHeaders.keys.any(
            (String key) => key.toLowerCase() == 'referer',
          ))
            'Referer': baseUrl,
        },
      );
      if (fetched == null) {
        body = removeLnReaderImageReference(body, image.fileName);
      } else {
        images.add(fetched);
      }
    }
    return (title: chapter.name, xhtmlBody: body, images: images);
  }

  /// 下封面；插件占位图 / 取不到返回 null（书照样生成，只是没封面）。
  Future<LnReaderEpubImage?> fetchCover({
    required HttpClient client,
    required LnReaderInstalledPlugin plugin,
    required LnReaderPluginInfo info,
    required LnReaderNovel novel,
  }) async {
    final String? coverUrl = novel.cover;
    if (coverUrl == null || isLnReaderPlaceholderCover(coverUrl)) return null;
    final Uri? uri = Uri.tryParse(coverUrl);
    if (uri == null) return null;
    return _fetchImage(
      client,
      coverUrl,
      fileName: 'cover',
      // 与书架外的封面网格同一套头：防盗链图床只认浏览器 UA + 站点 Referer。
      headers: lnReaderImageHeaders(
        uri: uri,
        referer: plugin.site,
        pluginHeaders: info.imageHeaders,
        cloudflare: manager.cloudflare,
      ),
    );
  }

  Future<LnReaderEpubImage?> _fetchImage(
    HttpClient client,
    String url, {
    required String fileName,
    required Map<String, String> headers,
  }) async {
    try {
      // 重定向手动跟：HttpClient 自动跟随时只有首跳过名字判据，一个 302 指向
      // 127.0.0.1 就能打到本机（审查 B1）。每一跳重新过判据；连接层另有
      // [guardLnReaderConnections] 按解析后地址兜底。
      Uri uri = Uri.parse(url);
      late HttpClientResponse response;
      for (int hop = 0; ; hop++) {
        if ((uri.scheme != 'http' && uri.scheme != 'https') ||
            isBlockedHost(uri.host)) {
          return null;
        }
        final HttpClientRequest request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          LnReaderFetchBridge.defaultUserAgent,
        );
        headers.forEach(request.headers.set);
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
      final Uint8List bytes = buffer.takeBytes();
      final String? mediaType = sniffLnReaderImageMediaType(bytes);
      if (mediaType == null) return null;
      // 封面的文件名要带扩展名（部分阅读器按扩展名判类型）。
      final String name = fileName == 'cover'
          ? 'cover.${mediaType.split('/').last.replaceAll('jpeg', 'jpg')}'
          : fileName;
      return (fileName: name, bytes: bytes, mediaType: mediaType);
    } on Object {
      return null;
    }
  }
}

/// EPUB `dc:identifier`：同一插件的同一部作品恒同一个值（下载与在线阅读共用）。
String lnReaderBookIdentifier(String pluginId, String novelPath) =>
    'lnreader:$pluginId:$novelPath';

/// 书名 → 导入用文件名（去 Windows 非法字符、限长）。
String lnReaderSafeFileName(String title) {
  final String cleaned = safeWindowsFileName(title).trim();
  if (cleaned.isEmpty) return 'novel';
  return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
}

/// 插件用来占位的「无封面」图：不值得下载进 EPUB。
bool isLnReaderPlaceholderCover(String url) =>
    url.contains('coverNotAvailable');

/// 下载失败的插图：把引用它的 `<img>` 从 XHTML 里摘掉，免得 EPUB 里留断链。
String removeLnReaderImageReference(String xhtml, String fileName) {
  final String escaped = RegExp.escape(fileName);
  return xhtml.replaceAll(
    RegExp('<img\\b[^>]*\\ssrc="$escaped"[^>]*/?>', caseSensitive: false),
    '',
  );
}

/// 简介里常见的 HTML 片段 → 纯文本（EPUB `dc:description` 与详情页用）。
String stripLnReaderHtml(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();
