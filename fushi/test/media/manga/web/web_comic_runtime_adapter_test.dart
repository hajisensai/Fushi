import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_chapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_runtime_adapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_scanner.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

const WebComicSiteRule _rule = WebComicSiteRule(
  id: 'demo',
  name: 'Demo',
  hosts: <String>['*.demo.test'],
  chapterUrlPattern: r'^/c/(?<id>\d+)',
  seriesKeyPattern: r'/s/(\w+)/',
  images: WebComicDomImageSource(selector: 'img', attributes: <String>['src']),
  referer: WebComicRefererMode.origin,
  headers: <String, String>{'X-Site': '1'},
);

WebComicScanResult _scan({
  String url = 'https://www.demo.test/c/2',
  int pages = 3,
  String? next = 'https://www.demo.test/c/3',
  String? prev = 'https://www.demo.test/c/1',
}) => WebComicScanResult(
  pageUrl: Uri.parse(url),
  title: 'Ch 2',
  images: <WebComicScannedImage>[
    for (int i = 0; i < pages; i++)
      WebComicScannedImage(url: 'https://img.demo.test/p$i.jpg'),
  ],
  nextChapterUrl: next == null ? null : Uri.parse(next),
  prevChapterUrl: prev == null ? null : Uri.parse(prev),
  ruleId: 'demo',
  userAgent: 'UA/1',
);

class _FakeScanner implements WebComicChapterScanner {
  _FakeScanner(this.result);

  final WebComicScanResult result;
  final List<Uri> calls = <Uri>[];

  @override
  Future<WebComicScanResult> scanChapter(Uri url) async {
    calls.add(url);
    return result;
  }
}

/// 最小 JPEG 魔数，够过 [looksLikeWebComicImage]。
Uint8List _jpeg(int tag) =>
    Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, tag, 0, 0, 0, 0, 0, 0, 0]);

void main() {
  const int now = 1000000;

  group('书架条目', () {
    test('章节新→旧：[下一章, 本章, 上一章]，本章带图，邻章只带链接', () {
      final OnlineMangaLibraryEntry entry = webComicEntryFromScan(
        _scan(),
        rule: null,
        nowMs: now,
        nextLabel: 'next',
        prevLabel: 'prev',
      );
      expect(entry.runtime, OnlineMangaRuntimeKind.web);
      expect(entry.extensionPackage, kWebComicMangaPackage);
      expect(entry.sourceId, 'www.demo.test');
      expect(entry.series.key, 'https://www.demo.test/c/2');
      expect(entry.chapters.map((OnlineMangaChapter c) => c.name), <String>[
        'next',
        'Ch 2',
        'prev',
      ]);
      final WebComicChapterData current = WebComicChapterData.fromRaw(
        entry.chapters[1].raw,
      )!;
      expect(current.images, hasLength(3));
      expect(current.capturedAt, now);
      expect(current.userAgent, 'UA/1');
      expect(
        WebComicChapterData.fromRaw(entry.chapters[0].raw)!.images,
        isEmpty,
      );
    });

    test('规则推得出作品身份时同作品各章共用一个 series key', () {
      final OnlineMangaLibraryEntry entry = webComicEntryFromScan(
        _scan(url: 'https://www.demo.test/s/abc/c/2'),
        rule: const WebComicSiteRule(
          id: 'demo',
          name: 'Demo',
          hosts: <String>['*.demo.test'],
          chapterUrlPattern: r'/c/\d+',
          seriesKeyPattern: r'/s/(\w+)/',
          images: WebComicDomImageSource(
            selector: 'img',
            attributes: <String>['src'],
          ),
        ),
        nowMs: now,
        nextLabel: 'n',
        prevLabel: 'p',
      );
      expect(entry.series.key, 'www.demo.test/abc');
    });

    test('合并：已有本章就地换新，邻章缺的补在两侧，带图的章不被占位覆盖', () {
      OnlineMangaChapter ch(String key, {bool images = false}) =>
          OnlineMangaChapter(
            key: key,
            name: key,
            raw: <String, Object?>{
              'url': key,
              if (images) 'images': <Object?>['x'],
            },
          );
      final List<OnlineMangaChapter> existing = <OnlineMangaChapter>[
        ch('c3', images: true),
        ch('c2'),
      ];
      final List<OnlineMangaChapter> merged = mergeWebComicChapters(
        existing,
        <OnlineMangaChapter>[ch('c3'), ch('c2', images: true), ch('c1')],
        currentKey: 'c2',
      );
      expect(merged.map((OnlineMangaChapter c) => c.key), <String>[
        'c3',
        'c2',
        'c1',
      ]);
      expect(merged[0].raw['images'], isNotNull, reason: '已有带图的 c3 保留');
      expect(merged[1].raw['images'], isNotNull, reason: 'c2 换成新扫的');

      // 本章不在表里、但它的下一章在：插在下一章之后（更旧）。
      final List<OnlineMangaChapter> afterNext = mergeWebComicChapters(
        <OnlineMangaChapter>[ch('c5'), ch('c4')],
        <OnlineMangaChapter>[ch('c4'), ch('c3', images: true), ch('c2')],
        currentKey: 'c3',
      );
      expect(afterNext.map((OnlineMangaChapter c) => c.key), <String>[
        'c5',
        'c4',
        'c3',
        'c2',
      ]);

      // 关系未知：新的一组放最前。
      final List<OnlineMangaChapter> unrelated = mergeWebComicChapters(
        <OnlineMangaChapter>[ch('x')],
        <OnlineMangaChapter>[ch('c2', images: true)],
        currentKey: 'c2',
      );
      expect(unrelated.map((OnlineMangaChapter c) => c.key), <String>[
        'c2',
        'x',
      ]);
    });
  });

  group('请求头', () {
    test('Cookie 只带作用域覆盖图片 host 的条目；host-only 只对页面 host', () {
      final Uri pageUrl = Uri.parse('https://www.demo.test/c/2');
      const List<WebComicCookie> cookies = <WebComicCookie>[
        WebComicCookie(name: 'sid', value: '1', domain: '.demo.test'),
        WebComicCookie(name: 'host', value: '2', domain: null),
        WebComicCookie(name: 'ads', value: '3', domain: 'tracker.example'),
        WebComicCookie(name: 'sid', value: 'dup', domain: '.demo.test'),
      ];
      expect(
        webComicCookieHeader(
          imageUrl: Uri.parse('https://img.demo.test/p.jpg'),
          pageUrl: pageUrl,
          cookies: cookies,
        ),
        'sid=1',
      );
      expect(
        webComicCookieHeader(
          imageUrl: Uri.parse('https://www.demo.test/p.jpg'),
          pageUrl: pageUrl,
          cookies: cookies,
        ),
        'sid=1; host=2',
      );
      expect(
        webComicCookieHeader(
          imageUrl: Uri.parse('https://cdn.other.test/p.jpg'),
          pageUrl: pageUrl,
          cookies: cookies,
        ),
        isNull,
      );
    });

    test('Cookie 按 RFC 6265 的 path-match 与 Secure 规则筛', () {
      final Uri pageUrl = Uri.parse('https://www.demo.test/comic/c/2');
      const List<WebComicCookie> cookies = <WebComicCookie>[
        WebComicCookie(
          name: 'root',
          value: '1',
          domain: 'demo.test',
          path: '/',
        ),
        WebComicCookie(
          name: 'comic',
          value: '2',
          domain: 'demo.test',
          path: '/comic',
        ),
        WebComicCookie(
          name: 'sec',
          value: '3',
          domain: 'demo.test',
          secure: true,
        ),
        WebComicCookie(
          name: 'plain',
          value: '4',
          domain: 'demo.test',
          secure: false,
        ),
        WebComicCookie(name: 'unknown', value: '5', domain: 'demo.test'),
      ];
      expect(
        webComicCookieHeader(
          imageUrl: Uri.parse('https://img.demo.test/comic/1.jpg'),
          pageUrl: pageUrl,
          cookies: cookies,
        ),
        'root=1; comic=2; sec=3; plain=4; unknown=5',
      );
      // /comicx 不在 /comic 之下（path-match 要求边界是 /）。
      expect(
        webComicCookieHeader(
          imageUrl: Uri.parse('https://img.demo.test/comicx/1.jpg'),
          pageUrl: pageUrl,
          cookies: cookies,
        ),
        'root=1; sec=3; plain=4; unknown=5',
      );
      // 明文 http：Secure 的不带；平台没报 Secure 而页面是 https 的，按可能 Secure 不降级。
      expect(
        webComicCookieHeader(
          imageUrl: Uri.parse('http://img.demo.test/comic/1.jpg'),
          pageUrl: pageUrl,
          cookies: cookies,
        ),
        'plain=4',
      );
    });

    test('path-match 边界', () {
      expect(webComicCookiePathMatches('/a/b', '/a'), isTrue);
      expect(webComicCookiePathMatches('/a/b', '/a/'), isTrue);
      expect(webComicCookiePathMatches('/a', '/a'), isTrue);
      expect(webComicCookiePathMatches('/ab', '/a'), isFalse);
      expect(webComicCookiePathMatches('/x', null), isTrue);
      expect(webComicCookiePathMatches('', '/'), isTrue);
    });

    test('Referer 四种模式', () {
      final Uri pageUrl = Uri.parse('https://www.demo.test/c/2?x=1');
      expect(webComicRefererFor(null, pageUrl), pageUrl.toString());
      expect(webComicRefererFor(_rule, pageUrl), 'https://www.demo.test/');
      const WebComicSiteRule none = WebComicSiteRule(
        id: 'n',
        name: 'n',
        hosts: <String>['x'],
        chapterUrlPattern: '^/',
        images: WebComicDomImageSource(selector: 'img', attributes: <String>[]),
        referer: WebComicRefererMode.none,
      );
      expect(webComicRefererFor(none, pageUrl), '');
      const WebComicSiteRule fixed = WebComicSiteRule(
        id: 'f',
        name: 'f',
        hosts: <String>['x'],
        chapterUrlPattern: '^/',
        images: WebComicDomImageSource(selector: 'img', attributes: <String>[]),
        referer: WebComicRefererMode.fixed,
        refererUrl: 'https://fixed.test/',
      );
      expect(webComicRefererFor(fixed, pageUrl), 'https://fixed.test/');
    });

    test('页引用带上 Referer、规则头、UA 与同站 Cookie', () {
      final List<HttpMangaPageRef> pages = buildWebComicPageRefs(
        images: const <WebComicScannedImage>[
          WebComicScannedImage(url: 'https://img.demo.test/1.jpg'),
          WebComicScannedImage(url: 'https://cdn.other.test/2.jpg'),
        ],
        pageUrl: Uri.parse('https://www.demo.test/c/2'),
        rule: _rule,
        userAgent: 'UA/1',
        cookies: const <WebComicCookie>[
          WebComicCookie(name: 'sid', value: '1', domain: 'demo.test'),
        ],
      );
      expect(pages.map((HttpMangaPageRef p) => p.index), <int>[0, 1]);
      expect(pages[0].referer, 'https://www.demo.test/');
      expect(pages[0].headers, <String, String>{
        'X-Site': '1',
        'User-Agent': 'UA/1',
        'Cookie': 'sid=1',
      });
      expect(pages[1].headers.containsKey('Cookie'), isFalse);
    });
  });

  group('适配器', () {
    OnlineMangaLibraryEntry entryFor(WebComicScanResult scan) =>
        webComicEntryFromScan(
          scan,
          rule: _rule,
          nowMs: now,
          nextLabel: 'n',
          prevLabel: 'p',
        );

    test('扫到的图还新鲜就直接出页表，不重扫；取图把头原样交给 HTTP', () async {
      final _FakeScanner scanner = _FakeScanner(_scan());
      final List<(Uri, Map<String, String>)> requests =
          <(Uri, Map<String, String>)>[];
      final WebComicLibraryAdapter adapter = WebComicLibraryAdapter(
        adFilterEnabled: () => false,
        scanner: scanner,
        rules: () async => const WebComicRuleSet(<WebComicSiteRule>[_rule]),
        cookies: (Uri _) async => const <WebComicCookie>[
          WebComicCookie(name: 'sid', value: '1', domain: 'demo.test'),
        ],
        httpGet: (Uri url, Map<String, String> headers) async {
          requests.add((url, headers));
          return _jpeg(1);
        },
        now: () => now + 1000,
      );
      final OnlineMangaLibraryEntry entry = entryFor(_scan());
      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: entry,
        chapter: entry.chapters[1],
      );
      expect(scanner.calls, isEmpty);
      expect(pages, hasLength(3));
      await adapter.fetchChapterPage(pages[0]);
      expect(requests.single.$1.toString(), 'https://img.demo.test/p0.jpg');
      expect(requests.single.$2, <String, String>{
        'X-Site': '1',
        'User-Agent': 'UA/1',
        'Cookie': 'sid=1',
        'Referer': 'https://www.demo.test/',
      });
    });

    test('邻章占位（没有图）换章时用扫描器打开章节页重扫', () async {
      final _FakeScanner scanner = _FakeScanner(
        _scan(url: 'https://www.demo.test/c/3', pages: 5),
      );
      final WebComicLibraryAdapter adapter = WebComicLibraryAdapter(
        adFilterEnabled: () => false,
        scanner: scanner,
        rules: () async => const WebComicRuleSet(<WebComicSiteRule>[_rule]),
        cookies: (Uri _) async => const <WebComicCookie>[],
        httpGet: (Uri _, Map<String, String> _) async => _jpeg(1),
        now: () => now,
      );
      final OnlineMangaLibraryEntry entry = entryFor(_scan());
      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: entry,
        chapter: entry.chapters[0],
      );
      expect(scanner.calls.single.toString(), 'https://www.demo.test/c/3');
      expect(pages, hasLength(5));
    });

    test('扫到的图过期了也重扫', () async {
      final _FakeScanner scanner = _FakeScanner(_scan(pages: 4));
      final WebComicLibraryAdapter adapter = WebComicLibraryAdapter(
        adFilterEnabled: () => false,
        scanner: scanner,
        rules: () async => WebComicRuleSet.empty,
        cookies: (Uri _) async => const <WebComicCookie>[],
        httpGet: (Uri _, Map<String, String> _) async => _jpeg(1),
        now: () => now + kWebComicCapturedImagesFreshFor.inMilliseconds + 1,
      );
      final OnlineMangaLibraryEntry entry = entryFor(_scan());
      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: entry,
        chapter: entry.chapters[1],
      );
      expect(scanner.calls, hasLength(1));
      expect(pages, hasLength(4));
    });

    test('广告页剔除：只判最后 10 张、前 3 张不判，判过的字节复用不再取', () async {
      final List<String> fetched = <String>[];
      final List<String> judged = <String>[];
      final _FakeAdDetector detector = _FakeAdDetector((Uint8List bytes) {
        judged.add('p${bytes[4]}');
        return bytes[4] == 13 || bytes[4] == 14;
      });
      final WebComicLibraryAdapter adapter = WebComicLibraryAdapter(
        adFilterEnabled: () => true,
        scanner: _FakeScanner(_scan()),
        rules: () async => WebComicRuleSet.empty,
        cookies: (Uri _) async => const <WebComicCookie>[],
        httpGet: (Uri url, Map<String, String> _) async {
          fetched.add(url.pathSegments.last);
          final int n = int.parse(
            url.pathSegments.last.replaceAll(RegExp(r'\D'), ''),
          );
          return _jpeg(n);
        },
        // 第 13、14 张（0 起）是广告。判哪几张由原生库的真规则决定，判定本身用假的。
        adDetector: detector,
        now: () => now,
      );
      final OnlineMangaLibraryEntry entry = entryFor(_scan(pages: 15));
      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: entry,
        chapter: entry.chapters[1],
      );
      expect(judged, <String>[for (int i = 5; i < 15; i++) 'p$i']);
      expect(detector.batches, 1, reason: '整章末尾一次批量判定');
      expect(pages, hasLength(13));
      expect(
        pages.map((OnlineMangaPageRef p) => p.index),
        List<int>.generate(13, (int i) => i),
        reason: '剔除后页序重新连续',
      );
      fetched.clear();
      await adapter.fetchChapterPage(pages[12]);
      expect(fetched, isEmpty, reason: '判定时取到的字节直接复用');
      await adapter.fetchChapterPage(pages[0]);
      expect(fetched, <String>['p0.jpg']);
    });

    test('短章（≤3 张）一张都不判', () async {
      int judged = 0;
      final WebComicLibraryAdapter adapter = WebComicLibraryAdapter(
        adFilterEnabled: () => true,
        scanner: _FakeScanner(_scan()),
        rules: () async => WebComicRuleSet.empty,
        cookies: (Uri _) async => const <WebComicCookie>[],
        httpGet: (Uri _, Map<String, String> _) async => _jpeg(0),
        adDetector: _FakeAdDetector((Uint8List _) {
          judged++;
          return true;
        }),
        now: () => now,
      );
      final OnlineMangaLibraryEntry entry = entryFor(_scan());
      final List<OnlineMangaPageRef> pages = await adapter.resolveChapterPages(
        entry: entry,
        chapter: entry.chapters[1],
      );
      expect(judged, 0);
      expect(pages, hasLength(3));
    });

    test('魔数判定：HTML 错误页不是图', () {
      expect(looksLikeWebComicImage(_jpeg(0)), isTrue);
      expect(
        looksLikeWebComicImage(
          Uint8List.fromList('<!doctype html><html>'.codeUnits),
        ),
        isFalse,
      );
    });
  });
}

/// 判哪几张走原生库的真规则（[ComicAdDetector.candidateIndices]），判定结果由 [judge] 给。
class _FakeAdDetector extends ComicAdDetector {
  _FakeAdDetector(this.judge);

  final bool Function(Uint8List bytes) judge;
  int batches = 0;

  @override
  Future<List<ComicAdVerdict>> detect(List<Uint8List> images) async {
    batches++;
    return <ComicAdVerdict>[
      for (final Uint8List b in images)
        judge(b) ? ComicAdVerdict.ad : ComicAdVerdict.content,
    ];
  }
}
