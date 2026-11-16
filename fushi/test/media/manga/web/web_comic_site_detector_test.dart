import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/web/web_comic_chapter.dart';
import 'package:fushi/src/media/manga/web/web_comic_scan.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_detector.dart';
import 'package:fushi/src/media/manga/web/web_comic_site_rule.dart';

/// 只实现 `callAsyncJavaScript` 的假 WebView：记下调用次数，按 [respond] 回结果。
class _FakeDetectController implements InAppWebViewController {
  _FakeDetectController(this.respond);

  final CallAsyncJavaScriptResult? Function(String functionBody) respond;
  final List<String> bodies = <String>[];

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    ContentWorld? contentWorld,
  }) async {
    bodies.add(functionBody);
    return respond(functionBody);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WebComicScanResult _hitomiScan(String url) => WebComicScanResult(
  pageUrl: Uri.parse(url).removeFragment(),
  title: 'Gallery 42',
  images: const <WebComicScannedImage>[
    WebComicScannedImage(url: 'https://w1.example/42/aa.webp'),
  ],
  ruleId: 'hitomi',
);

/// 拍板台 PWWovB_nw2：内置浏览器打开 hitomi 的画廊页 / 阅读页认不出漫画。照 ComicRead 的
/// hitomi 站点适配：页面数据 `galleryinfo.files`（非 anime）判定漫画页，页图用站点自己的
/// `url_from_url_from_hash(id, file, 'webp')` 拼。
void main() {
  final WebComicRuleSet rules = WebComicRuleSet.parse(
    File('assets/web_comic/site_rules.json').readAsStringSync(),
  );
  final WebComicSiteRule hitomi = rules.byId('hitomi')!;

  /// 在 node 里跑一段 JS（[prelude] 布置假页面），脚本最后打印的 JSON 为结果。
  Future<Object?> runNode(String source) async {
    final Directory dir = Directory.systemTemp.createTempSync('comic-detect-');
    try {
      final File script = File('${dir.path}/run.js')..writeAsStringSync(source);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      return jsonDecode((result.stdout as String).trim());
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// 跑 hitomi 规则的 detect（经真实的限时轮询包装）。
  Future<Object?> detect(String prelude) => runNode('''
global.window = global;
$prelude
(async function () {
${webComicDetectFunctionBody(hitomi.detect!, budget: const Duration(milliseconds: 800), interval: const Duration(milliseconds: 50))}
})().then(function (v) { console.log(JSON.stringify(v)); });
''');

  group('hitomi 站点规则', () {
    test('画廊页（含 imageset）与阅读页都命中，动画页 / 列表页 / 首页不命中', () {
      for (final String url in <String>[
        'https://hitomi.la/imageset/%E9%80%9A%E5%85%B3-%E4%B8%AD%E6%96%87-4333260.html#1',
        'https://hitomi.la/doujinshi/some-title-japanese-4333260.html',
        'https://hitomi.la/manga/x-123.html',
        'https://hitomi.la/reader/4333260.html#3',
      ]) {
        expect(rules.matchChapter(Uri.parse(url))?.id, 'hitomi', reason: url);
      }
      for (final String url in <String>[
        'https://hitomi.la/anime/x-4333260.html',
        'https://hitomi.la/type/imageset-all.html',
        'https://hitomi.la/tag/female%3Aponytail-all.html',
        'https://hitomi.la/',
      ]) {
        expect(rules.matchChapter(Uri.parse(url)), isNull, reason: url);
      }
    });

    test('画廊页与阅读页是同一本（作品身份只认画廊 id）', () {
      expect(
        hitomi.seriesKeyOf(
          Uri.parse(
            'https://hitomi.la/imageset/t-%E4%B8%AD%E6%96%87-42.html#1',
          ),
        ),
        'hitomi.la/42',
      );
      expect(
        hitomi.seriesKeyOf(Uri.parse('https://hitomi.la/reader/42.html#7')),
        'hitomi.la/42',
      );
    });

    test('画廊页与阅读页是同一章：先后从两个入口入库只留一个章节', () {
      const String gallery =
          'https://hitomi.la/doujinshi/some-title-japanese-42.html';
      const String reader = 'https://hitomi.la/reader/42.html#3';
      expect(hitomi.chapterKeyOf(Uri.parse(gallery)), 'hitomi.la/42');
      expect(hitomi.chapterKeyOf(Uri.parse(reader)), 'hitomi.la/42');
      expect(
        webComicChapterKey(Uri.parse(reader), rule: hitomi),
        webComicChapterKey(Uri.parse(gallery), rule: hitomi),
      );

      OnlineMangaLibraryEntry entryOf(String url) => webComicEntryFromScan(
        _hitomiScan(url),
        rule: hitomi,
        nowMs: 1000,
        nextLabel: 'next',
        prevLabel: 'prev',
      );
      final OnlineMangaLibraryEntry first = entryOf(gallery);
      final OnlineMangaLibraryEntry second = entryOf(reader);
      expect(second.series.key, first.series.key);
      final List<OnlineMangaChapter> merged = mergeWebComicChapters(
        first.chapters,
        second.chapters,
        currentKey: webComicChapterKey(
          _hitomiScan(reader).pageUrl,
          rule: hitomi,
        ),
      );
      expect(merged, hasLength(1));
      // 就地换成最近一次扫到的（地址跟着最近的入口走，扫图仍可用）。
      expect(
        WebComicChapterData.fromRaw(merged.single.raw)!.url.toString(),
        'https://hitomi.la/reader/42.html',
      );
    });

    test('没写 chapterKeyPattern 的规则：章节身份仍是去掉 fragment 的地址', () {
      const WebComicSiteRule plain = WebComicSiteRule(
        id: 'p',
        name: 'P',
        hosts: <String>['p.test'],
        chapterUrlPattern: r'^/c/\d+$',
        images: WebComicDomImageSource(
          selector: 'img',
          attributes: <String>['src'],
        ),
      );
      expect(plain.chapterKeyOf(Uri.parse('https://p.test/c/1')), isNull);
      expect(
        webComicChapterKey(Uri.parse('https://p.test/c/1#p3'), rule: plain),
        'https://p.test/c/1',
      );
      expect(
        webComicChapterKey(Uri.parse('https://p.test/c/1#p3')),
        'https://p.test/c/1',
      );
    });

    test('页图取自站点自己的 URL 构造（ComicRead 同款），带站点 Referer', () async {
      expect(hitomi.referer, WebComicRefererMode.origin);
      expect(hitomi.images, isA<WebComicScriptImageSource>());
      final String code = (hitomi.images as WebComicScriptImageSource).code;
      final Object? urls = await runNode('''
global.window = global;
var galleryinfo = {id: 42, type: 'imageset', files: [{hash: 'aa'}, {hash: 'bb'}]};
global.galleryinfo = galleryinfo;
global.url_from_url_from_hash = function (id, f, dir) {
  return 'https://w1.example/' + id + '/' + f.hash + '.' + dir;
};
(async function (ctx) {
$code
})({}).then(function (v) { console.log(JSON.stringify(v)); });
''');
      expect(urls, <String>[
        'https://w1.example/42/aa.webp',
        'https://w1.example/42/bb.webp',
      ]);
    });
  });

  group('页面侧判据（detect）', () {
    test('数据已在页面上：是漫画页', () async {
      expect(
        webComicDetectVerdict(
          await detect(
            "global.galleryinfo = {type: 'imageset', files: [{hash: 'a'}]};",
          ),
        ),
        isTrue,
      );
    });

    test('数据异步到（阅读页 \$.getScript）：等到了就是', () async {
      expect(
        webComicDetectVerdict(
          await detect(
            "setTimeout(function () { global.galleryinfo = {type: 'manga', "
            "files: [{hash: 'a'}]}; }, 200);",
          ),
        ),
        isTrue,
      );
    });

    test('动画画廊 / 没有页 / 到点也没数据：不是', () async {
      expect(
        webComicDetectVerdict(
          await detect(
            "global.galleryinfo = {type: 'anime', files: [{hash: 'a'}]};",
          ),
        ),
        isFalse,
      );
      expect(
        webComicDetectVerdict(
          await detect("global.galleryinfo = {type: 'manga', files: []};"),
        ),
        isFalse,
      );
      expect(webComicDetectVerdict(await detect('')), isFalse);
    });

    test('detect 抛错按「还不是」处理，不冒出去', () async {
      final Object? value = await runNode('''
(async function () {
${webComicDetectFunctionBody('throw new Error("boom");', budget: const Duration(milliseconds: 100), interval: const Duration(milliseconds: 20))}
})().then(function (v) { console.log(JSON.stringify(v)); });
''');
      expect(webComicDetectVerdict(value), isFalse);
    });

    test('回传值解码：1 / "1" / true 为是，其余为否', () {
      expect(webComicDetectVerdict(1), isTrue);
      expect(webComicDetectVerdict('1'), isTrue);
      expect(webComicDetectVerdict(true), isTrue);
      expect(webComicDetectVerdict(0), isFalse);
      expect(webComicDetectVerdict(null), isFalse);
      expect(webComicDetectVerdict('true'), isFalse);
    });

    test('规则解析带上 detect；空串当没有', () {
      final WebComicRuleSet parsed = WebComicRuleSet.parse('''
{"rules": [
  {"id": "a", "name": "A", "hosts": ["a.com"], "chapterUrlPattern": "^/c/",
   "images": {"mode": "dom", "selector": "img"}, "detect": "return true;"},
  {"id": "b", "name": "B", "hosts": ["b.com"], "chapterUrlPattern": "^/c/",
   "images": {"mode": "dom", "selector": "img"}, "detect": "  "}
]}''');
      expect(parsed.byId('a')!.detect, 'return true;');
      expect(parsed.byId('b')!.detect, isNull);
    });

    test('chapterKeyPattern 编译不过：整条规则丢弃', () {
      final WebComicRuleSet parsed = WebComicRuleSet.parse('''
{"rules": [
  {"id": "a", "name": "A", "hosts": ["a.com"], "chapterUrlPattern": "^/c/",
   "images": {"mode": "dom", "selector": "img"}, "chapterKeyPattern": "("}
]}''');
      expect(parsed.byId('a'), isNull);
    });
  });

  group('站点判定接线（WebComicSiteComicDetector.isComicPage）', () {
    final WebComicRuleSet demoRules = WebComicRuleSet.parse(r'''
{"rules": [
  {"id": "plain", "name": "Plain", "hosts": ["plain.test"],
   "chapterUrlPattern": "^/c/\\d+$", "images": {"mode": "dom", "selector": "img"}},
  {"id": "checked", "name": "Checked", "hosts": ["checked.test"],
   "chapterUrlPattern": "^/g/\\d+$", "images": {"mode": "dom", "selector": "img"},
   "detect": "return window.ok;"}
]}''');
    WebComicSiteComicDetector detector() =>
        WebComicSiteComicDetector(rules: () async => demoRules);

    test('地址没被规则覆盖：null，不跑页面脚本', () async {
      final _FakeDetectController controller = _FakeDetectController(
        (_) => fail('不该跑页面脚本'),
      );
      expect(
        await detector().isComicPage(
          controller,
          Uri.parse('https://plain.test/list'),
        ),
        isNull,
      );
      expect(
        await detector().isComicPage(
          controller,
          Uri.parse('https://other.test/c/1'),
        ),
        isNull,
      );
      expect(controller.bodies, isEmpty);
    });

    test('规则没写 detect：命中地址就是漫画页，不跑页面脚本', () async {
      final _FakeDetectController controller = _FakeDetectController(
        (_) => fail('不该跑页面脚本'),
      );
      expect(
        await detector().isComicPage(
          controller,
          Uri.parse('https://plain.test/c/7'),
        ),
        isTrue,
      );
      expect(controller.bodies, isEmpty);
    });

    test('写了 detect：照页面回传判定；脚本报错 / 无结果当不是', () async {
      Future<bool?> run(CallAsyncJavaScriptResult? result) async {
        final _FakeDetectController controller = _FakeDetectController(
          (_) => result,
        );
        final bool? verdict = await detector().isComicPage(
          controller,
          Uri.parse('https://checked.test/g/3'),
        );
        expect(controller.bodies, hasLength(1));
        expect(controller.bodies.single, contains('return window.ok;'));
        return verdict;
      }

      expect(await run(CallAsyncJavaScriptResult(value: 1)), isTrue);
      expect(await run(CallAsyncJavaScriptResult(value: 0)), isFalse);
      expect(
        await run(CallAsyncJavaScriptResult(error: 'ReferenceError')),
        isFalse,
      );
      expect(await run(null), isFalse);
    });
  });
}
