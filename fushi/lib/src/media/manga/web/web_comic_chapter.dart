import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';

/// 网页漫画章节 `raw` 的字段名（进用户库的 sourceMetadata，改名 = 旧条目失配）。
abstract final class WebComicChapterRaw {
  static const String url = 'url';
  static const String title = 'title';
  static const String images = 'images';
  static const String capturedAt = 'capturedAt';
  static const String ruleId = 'ruleId';
  static const String next = 'next';
  static const String prev = 'prev';
  static const String userAgent = 'userAgent';
}

/// 一条章节 raw 的读视图。
class WebComicChapterData {
  const WebComicChapterData({
    required this.url,
    required this.images,
    this.capturedAt,
    this.ruleId,
    this.next,
    this.prev,
    this.userAgent,
  });

  final Uri url;
  final List<WebComicScannedImage> images;
  final int? capturedAt;
  final String? ruleId;
  final Uri? next;
  final Uri? prev;
  final String? userAgent;

  /// 章节 raw → 读视图；没有可用的章节页 URL 返回 null。
  static WebComicChapterData? fromRaw(Map<String, Object?> raw) {
    final Uri? url = Uri.tryParse(
      raw[WebComicChapterRaw.url]?.toString() ?? '',
    );
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) {
      return null;
    }
    final Object? rawImages = raw[WebComicChapterRaw.images];
    return WebComicChapterData(
      url: url,
      images: rawImages is List
          ? <WebComicScannedImage>[
              for (final Object? item in rawImages)
                ?WebComicScannedImage.fromJson(item),
            ]
          : const <WebComicScannedImage>[],
      capturedAt: (raw[WebComicChapterRaw.capturedAt] as num?)?.toInt(),
      ruleId: raw[WebComicChapterRaw.ruleId]?.toString(),
      next: Uri.tryParse(raw[WebComicChapterRaw.next]?.toString() ?? ''),
      prev: Uri.tryParse(raw[WebComicChapterRaw.prev]?.toString() ?? ''),
      userAgent: raw[WebComicChapterRaw.userAgent]?.toString(),
    );
  }
}

/// 扫到的图在多久内视为新鲜：很多站的图片 URL 带时效签名（MangaDex 的
/// at-home 节点约 15 分钟），过期就该重扫章节页而不是拿旧地址硬取。
const Duration kWebComicCapturedImagesFreshFor = Duration(minutes: 10);

/// 把一次扫图结果做成章节：当前章带图，上 / 下章只带链接（换章时再扫）。
OnlineMangaChapter webComicChapterFromScan(
  WebComicScanResult scan, {
  required int nowMs,
}) => OnlineMangaChapter(
  key: scan.pageUrl.toString(),
  name: scan.title,
  raw: <String, Object?>{
    WebComicChapterRaw.url: scan.pageUrl.toString(),
    WebComicChapterRaw.title: scan.title,
    WebComicChapterRaw.images: <Map<String, Object?>>[
      for (final WebComicScannedImage image in scan.images) image.toJson(),
    ],
    WebComicChapterRaw.capturedAt: nowMs,
    if (scan.ruleId != null) WebComicChapterRaw.ruleId: scan.ruleId,
    if (scan.nextChapterUrl != null)
      WebComicChapterRaw.next: scan.nextChapterUrl.toString(),
    if (scan.prevChapterUrl != null)
      WebComicChapterRaw.prev: scan.prevChapterUrl.toString(),
    if (scan.userAgent != null) WebComicChapterRaw.userAgent: scan.userAgent,
  },
);

/// 只知道链接的相邻章（名字暂用链接，阅读器换过去时再扫）。
OnlineMangaChapter webComicPlaceholderChapter(
  Uri url, {
  required String name,
  String? ruleId,
}) => OnlineMangaChapter(
  key: url.toString(),
  name: name,
  raw: <String, Object?>{
    WebComicChapterRaw.url: url.toString(),
    WebComicChapterRaw.ruleId: ?ruleId,
  },
);

/// 一次扫图 → 书架条目（章节新→旧：`[下一章?, 本章, 上一章?]`）。
///
/// [nextLabel] / [prevLabel] 是相邻章的占位名（UI 文案由调用方给）。
OnlineMangaLibraryEntry webComicEntryFromScan(
  WebComicScanResult scan, {
  required WebComicSiteRule? rule,
  required int nowMs,
  required String nextLabel,
  required String prevLabel,
}) {
  final String seriesKey =
      rule?.seriesKeyOf(scan.pageUrl) ?? scan.pageUrl.toString();
  final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    if (scan.nextChapterUrl != null)
      webComicPlaceholderChapter(
        scan.nextChapterUrl!,
        name: nextLabel,
        ruleId: scan.ruleId,
      ),
    webComicChapterFromScan(scan, nowMs: nowMs),
    if (scan.prevChapterUrl != null)
      webComicPlaceholderChapter(
        scan.prevChapterUrl!,
        name: prevLabel,
        ruleId: scan.ruleId,
      ),
  ];
  return OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.web,
    extensionPackage: kWebComicMangaPackage,
    sourceId: scan.pageUrl.host.toLowerCase(),
    series: OnlineMangaSeries(
      key: seriesKey,
      title: scan.title,
      coverUrl: scan.images.isEmpty ? null : scan.images.first.url,
      raw: <String, Object?>{'url': scan.pageUrl.toString()},
    ),
    chapters: chapters,
  );
}

/// 把新扫到的章节并进已有的章节表（同一作品在不同章节页各打开过一次）。
///
/// [fresh] 是 [webComicEntryFromScan] 产出的 `[下一章?, 本章, 上一章?]`，
/// [currentKey] 是其中本章的 key。规则：
/// - 已有表里有本章：就地换成新的（带新图），缺的上 / 下章插在它两侧；
/// - 没有本章但有它的下一章：本章插在下一章之后（更旧），上一章再往后；
/// - 没有本章但有它的上一章：本章插在上一章之前（更新），下一章再往前；
/// - 都没有：新的一组放在最前（关系未知，至少本次能读）。
///
/// 已有表里带图的章节不会被占位章覆盖。
List<OnlineMangaChapter> mergeWebComicChapters(
  List<OnlineMangaChapter> existing,
  List<OnlineMangaChapter> fresh, {
  required String currentKey,
}) {
  final int freshCurrent = fresh.indexWhere(
    (OnlineMangaChapter c) => c.key == currentKey,
  );
  if (freshCurrent < 0) return List<OnlineMangaChapter>.of(existing);
  final OnlineMangaChapter current = fresh[freshCurrent];
  final OnlineMangaChapter? next = freshCurrent > 0
      ? fresh[freshCurrent - 1]
      : null;
  final OnlineMangaChapter? prev = freshCurrent + 1 < fresh.length
      ? fresh[freshCurrent + 1]
      : null;
  final List<OnlineMangaChapter> out = List<OnlineMangaChapter>.of(existing);
  int indexOf(String key) =>
      out.indexWhere((OnlineMangaChapter c) => c.key == key);

  int at = indexOf(current.key);
  if (at >= 0) {
    out[at] = current;
  } else if (next != null && indexOf(next.key) >= 0) {
    at = indexOf(next.key) + 1;
    out.insert(at, current);
  } else if (prev != null && indexOf(prev.key) >= 0) {
    at = indexOf(prev.key);
    out.insert(at, current);
  } else {
    return <OnlineMangaChapter>[...fresh, ...out];
  }
  if (next != null && indexOf(next.key) < 0) {
    out.insert(at, next);
    at++;
  }
  if (prev != null && indexOf(prev.key) < 0) {
    out.insert(at + 1, prev);
  }
  return out;
}

/// 浏览器里的一条 cookie（与平台 WebView 的 Cookie 类型解耦，便于测试）。
typedef WebComicCookie = ({String name, String value, String? domain});

/// 给 [imageUrl] 拼 `Cookie` 头：只带**作用域覆盖图片 host** 的条目——章节页所在
/// 站点的 cookie 才可能对它有效，第三方 CDN / 统计域的 cookie 一概不带。
///
/// host-only cookie（浏览器不报 domain）的作用域是 [pageUrl] 的 host 本身。
/// 同名取第一条。没有可带的返回 null。
String? webComicCookieHeader({
  required Uri imageUrl,
  required Uri pageUrl,
  required Iterable<WebComicCookie> cookies,
}) {
  final String host = imageUrl.host.toLowerCase();
  final Map<String, String> picked = <String, String>{};
  for (final WebComicCookie cookie in cookies) {
    final String name = cookie.name.trim();
    if (name.isEmpty || picked.containsKey(name)) continue;
    final String reported = cookie.domain?.trim() ?? '';
    final String domain = MangaCookie.canonicalizeDomain(
      reported.isEmpty ? pageUrl.host : reported,
    );
    final bool hostOnly = reported.isEmpty;
    final bool applies = hostOnly
        ? host == domain
        : MangaCookie.hostMatchesDomain(host, domain);
    if (!applies) continue;
    picked[name] = cookie.value;
  }
  if (picked.isEmpty) return null;
  return picked.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join('; ');
}

/// 一页图的 Referer（按规则的模式；无规则 = 章节页 URL）。空串 = 不带。
String webComicRefererFor(WebComicSiteRule? rule, Uri pageUrl) {
  switch (rule?.referer ?? WebComicRefererMode.page) {
    case WebComicRefererMode.page:
      return pageUrl.toString();
    case WebComicRefererMode.origin:
      return '${pageUrl.origin}/';
    case WebComicRefererMode.fixed:
      return rule?.refererUrl ?? pageUrl.toString();
    case WebComicRefererMode.none:
      return '';
  }
}

/// 取图请求的额外头（Referer 单列在页引用里，这里不含）：规则要求的头、扫图
/// WebView 的 UA、同站 Cookie。
Map<String, String> webComicImageHeaders({
  required WebComicSiteRule? rule,
  required String? userAgent,
  required String? cookieHeader,
}) => <String, String>{
  ...?rule?.headers,
  if (userAgent != null && userAgent.isNotEmpty) 'User-Agent': userAgent,
  if (cookieHeader != null && cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
};
