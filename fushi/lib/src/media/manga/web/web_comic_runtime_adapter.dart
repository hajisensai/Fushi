import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_ad_filter.dart';
import 'package:fushi/src/media/manga/web/web_comic_chapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_scanner.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 取一页字节（测试缝；生产 = [webComicHttpGet]）。
typedef WebComicHttpGet =
    Future<Uint8List> Function(Uri url, Map<String, String> headers);

/// 网页漫画的运行时适配器（[OnlineMangaRuntimeKind.web]）。
///
/// - 页表：章节 raw 里扫到的图还新鲜就直接用；没有图（相邻章占位）或过期了，
///   用 [scanner] 打开章节页重扫一次（失败时退回旧图，总比读不了强）。
/// - 每页是 [HttpMangaPageRef]：Referer 按站点规则，[HttpMangaPageRef.headers]
///   带同站 Cookie（从浏览器 CookieManager 按站点过滤）+ 扫图时的 UA + 规则头。
/// - 取图走 [createAppHttpClient]（全局代理装配），不走 WebView 网络。
/// - 章末广告页剔除（[adFilterEnabled]）：只看最后 10 张、前 3 张不动；判定时
///   取到的字节缓存住，阅读器随后取同一页不再走网络。
class WebComicLibraryAdapter
    implements OnlineMangaRuntimeAdapter, OnlineMangaWebUrlCapable {
  WebComicLibraryAdapter({
    required this.adFilterEnabled,
    WebComicChapterScanner? scanner,
    Future<WebComicRuleSet> Function()? rules,
    Future<List<WebComicCookie>> Function(Uri pageUrl)? cookies,
    WebComicHttpGet? httpGet,
    bool Function(Uint8List bytes)? adDetector,
    int Function()? now,
  }) : _scanner = scanner ?? const HeadlessWebComicChapterScanner(),
       _rules = rules ?? WebComicAssets.rules,
       _cookies = cookies ?? readWebComicCookies,
       _httpGet = httpGet ?? webComicHttpGet,
       _adDetector = adDetector,
       _now = now ?? _wallClock;

  /// 读偏好的函数：每次解析页表时现读，用户在浏览器页里改了开关立即生效。
  final bool Function() adFilterEnabled;
  final WebComicChapterScanner _scanner;
  final Future<WebComicRuleSet> Function() _rules;
  final Future<List<WebComicCookie>> Function(Uri pageUrl) _cookies;
  final WebComicHttpGet _httpGet;

  /// null = 生产判定（后台 isolate 跑 [isWebComicAdImage]）。
  final bool Function(Uint8List bytes)? _adDetector;
  final int Function() _now;

  /// 广告判定时已经取到的页字节（按 URL），被阅读器取走一次即删。
  final Map<String, Uint8List> _prefetched = <String, Uint8List>{};

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.web;

  /// 与在线漫画源同一道 App Store 合规门（iOS 上整个不存在）。
  @override
  bool get isSupportedOnThisPlatform =>
      StoreRestrictedCapability.onlineMangaSource.isAvailable;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async {
    final WebComicRuleSet rules = await _rules();
    final Uri? url = Uri.tryParse(entry.series.raw['url']?.toString() ?? '');
    final WebComicSiteRule? rule = url == null ? null : rules.matchChapter(url);
    return rule?.name ?? entry.sourceId;
  }

  @override
  Future<Uri?> webUrl(OnlineMangaLibraryEntry entry) async {
    final OnlineMangaChapter? chapter = entry.currentChapter;
    final Uri? fromChapter = chapter == null
        ? null
        : WebComicChapterData.fromRaw(chapter.raw)?.url;
    return fromChapter ??
        Uri.tryParse(entry.series.raw['url']?.toString() ?? '');
  }

  /// 网页漫画没有「源站作品详情」可拉：刷新 = 原样返回已知的作品与章节。
  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    final WebComicChapterData? data = WebComicChapterData.fromRaw(chapter.raw);
    if (data == null) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'The chapter has no page URL',
        stage: 'pages',
        sourceLabel: entry.sourceId,
      );
    }
    Uri pageUrl = data.url;
    List<WebComicScannedImage> images = data.images;
    String? userAgent = data.userAgent;
    final bool fresh =
        images.isNotEmpty &&
        data.capturedAt != null &&
        _now() - data.capturedAt! <
            kWebComicCapturedImagesFreshFor.inMilliseconds;
    if (!fresh) {
      try {
        final WebComicScanResult scan = await _scanner.scanChapter(data.url);
        if (scan.images.isNotEmpty) {
          pageUrl = scan.pageUrl;
          images = scan.images;
          userAgent = scan.userAgent ?? userAgent;
        }
      } on Object catch (error, stack) {
        // 重扫失败：有旧图就用旧图（签名可能还没过期），没有才是真失败。
        ErrorLogService.instance.log(
          'WebComicLibraryAdapter.rescan',
          error,
          stack,
        );
        if (images.isEmpty) {
          throw OnlineMangaUnavailable(
            OnlineMangaUnavailableReason.runtimeFailure,
            '$error',
            cause: error,
            stage: 'pages',
            sourceLabel: entry.sourceId,
          );
        }
      }
    }
    if (images.isEmpty) {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'No manga pages were found on ${data.url}',
        stage: 'pages',
        sourceLabel: entry.sourceId,
      );
    }
    final WebComicRuleSet rules = await _rules();
    final WebComicSiteRule? rule =
        rules.byId(data.ruleId) ?? rules.matchChapter(pageUrl);
    List<WebComicCookie> cookies = const <WebComicCookie>[];
    try {
      cookies = await _cookies(pageUrl);
    } on Object catch (error, stack) {
      // 读不到 cookie 不挡取图：公开站不需要，需要的站会在取图时如实失败。
      ErrorLogService.instance.log(
        'WebComicLibraryAdapter.cookies',
        error,
        stack,
      );
    }
    final List<HttpMangaPageRef> pages = buildWebComicPageRefs(
      images: images,
      pageUrl: pageUrl,
      rule: rule,
      userAgent: userAgent,
      cookies: cookies,
    );
    if (!adFilterEnabled()) return pages;
    return _dropAdPages(pages);
  }

  Future<List<OnlineMangaPageRef>> _dropAdPages(
    List<HttpMangaPageRef> pages,
  ) async {
    final Set<int> ads = <int>{};
    for (final int index in webComicAdCandidateIndices(pages.length)) {
      final HttpMangaPageRef page = pages[index];
      try {
        final Uint8List bytes = await _fetch(page);
        _prefetched[page.url] = bytes;
        final bool Function(Uint8List bytes)? detector = _adDetector;
        final bool ad = detector != null
            ? detector(bytes)
            : await Isolate.run(() => isWebComicAdImage(bytes));
        if (ad) {
          ads.add(index);
          _prefetched.remove(page.url);
        }
      } on Object {
        // 取不到 / 判不了的页按正文保留：判广告只许漏判，不许误删。
      }
    }
    if (ads.isEmpty) return pages;
    final List<OnlineMangaPageRef> kept = <OnlineMangaPageRef>[];
    for (final HttpMangaPageRef page in pages) {
      if (ads.contains(page.index)) continue;
      kept.add(
        HttpMangaPageRef(
          index: kept.length,
          url: page.url,
          referer: page.referer,
          headers: page.headers,
        ),
      );
    }
    return kept;
  }

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    if (page is! HttpMangaPageRef) {
      throw ArgumentError.value(page, 'page', 'not a web comic page reference');
    }
    final Uint8List? cached = _prefetched.remove(page.url);
    if (cached != null) return cached;
    return _fetch(page);
  }

  Future<Uint8List> _fetch(HttpMangaPageRef page) =>
      _httpGet(Uri.parse(page.url), <String, String>{
        ...page.headers,
        if (page.referer.isNotEmpty) 'Referer': page.referer,
      });

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async {
    final Uri? pageUrl = Uri.tryParse(
      entry.series.raw['url']?.toString() ?? '',
    );
    final WebComicRuleSet rules = await _rules();
    final WebComicSiteRule? rule = pageUrl == null
        ? null
        : rules.matchChapter(pageUrl);
    final String referer = pageUrl == null
        ? ''
        : webComicRefererFor(rule, pageUrl);
    return _httpGet(Uri.parse(url), <String, String>{
      ...?rule?.headers,
      if (referer.isNotEmpty) 'Referer': referer,
    });
  }
}

/// 扫到的图 → 页引用（Referer + 同站 Cookie + UA + 规则头）。
List<HttpMangaPageRef> buildWebComicPageRefs({
  required List<WebComicScannedImage> images,
  required Uri pageUrl,
  required WebComicSiteRule? rule,
  required String? userAgent,
  required List<WebComicCookie> cookies,
}) {
  final String referer = webComicRefererFor(rule, pageUrl);
  return <HttpMangaPageRef>[
    for (int index = 0; index < images.length; index++)
      HttpMangaPageRef(
        index: index,
        url: images[index].url,
        referer: referer,
        headers: webComicImageHeaders(
          rule: rule,
          userAgent: userAgent,
          cookieHeader: webComicCookieHeader(
            imageUrl: Uri.parse(images[index].url),
            pageUrl: pageUrl,
            cookies: cookies,
          ),
        ),
      ),
  ];
}

/// 生产取图：应用代理出口的 [HttpClient]，非 2xx / 不是图片一律抛。
Future<Uint8List> webComicHttpGet(Uri url, Map<String, String> headers) async {
  final HttpClient client = createAppHttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'image/*,*/*;q=0.8');
    headers.forEach(request.headers.set);
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 60),
    );
    final BytesBuilder builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    final Uint8List bytes = builder.takeBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    if (!looksLikeWebComicImage(bytes)) {
      // 防盗链 / 验证页返回的是 HTML，交给阅读器只会是一张坏图。
      throw HttpException('Response is not an image', uri: url);
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

/// 按魔数认 JPEG / PNG / GIF / WebP / AVIF / BMP。
bool looksLikeWebComicImage(Uint8List bytes) {
  if (bytes.length < 12) return false;
  bool starts(List<int> magic, [int offset = 0]) {
    for (int i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  return starts(<int>[0xFF, 0xD8, 0xFF]) ||
      starts(<int>[0x89, 0x50, 0x4E, 0x47]) ||
      starts(<int>[0x47, 0x49, 0x46, 0x38]) ||
      (starts(<int>[0x52, 0x49, 0x46, 0x46]) &&
          starts(<int>[0x57, 0x45, 0x42, 0x50], 8)) ||
      starts(<int>[0x66, 0x74, 0x79, 0x70], 4) ||
      starts(<int>[0x42, 0x4D]);
}
