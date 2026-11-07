import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/web/web_novel_gate.dart'
    show webNovelReaderActionAvailable;
import 'package:fushi/src/media/video/web_video_browser_return.dart';
import 'package:fushi/src/web_browser/features/open_in_fushi/web_open_in_fushi_action.dart';
import 'package:fushi/src/web_browser/features/open_in_fushi/web_page_content.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tab_view/features/web_novel_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 用户只看到一个浏览器（docs/specs/2026-11-01-one-browser.md）：浏览器工具条按页面内容给
/// 一个上下文按钮，视频「用 Fushi 播放」、漫画 / 小说「用 Fushi 阅读」，同一个入口模型。
void main() {
  WebPageContentProbe probe({int v = 0, int i = 0, int t = 0}) =>
      WebPageContentProbe(largeVideos: v, tallImages: i, textLength: t);

  group('页面内容分类', () {
    test('大视频优先；竖长图多是漫画；正文长是小说；都不像返回 null', () {
      expect(
        classifyWebPageContent(probe(v: 1, t: 5000)),
        WebPageContentKind.video,
      );
      expect(classifyWebPageContent(probe(i: 5)), WebPageContentKind.comic);
      expect(classifyWebPageContent(probe(t: 3000)), WebPageContentKind.novel);
      // 带插图的小说章节：图少、字多 → 小说。
      expect(
        classifyWebPageContent(probe(i: 3, t: 3000)),
        WebPageContentKind.novel,
      );
      // 带对白文字稿的漫画站：竖长图多到压过正文 → 漫画。
      expect(
        classifyWebPageContent(probe(i: kWebPageComicDominantImages, t: 9000)),
        WebPageContentKind.comic,
      );
      expect(classifyWebPageContent(probe(i: 2, t: 800)), isNull);
    });

    test('探针读数：JSON 字符串 / Map 都认，坏数据为 null，缺项按 0', () {
      final WebPageContentProbe? a = WebPageContentProbe.tryParse(
        '{"v":0,"i":4,"t":120}',
      );
      expect(a?.tallImages, 4);
      expect(a?.textLength, 120);
      final WebPageContentProbe? b = WebPageContentProbe.tryParse(<String, int>{
        'v': 2,
      });
      expect(b?.largeVideos, 2);
      expect(b?.tallImages, 0);
      expect(WebPageContentProbe.tryParse('not json'), isNull);
      expect(WebPageContentProbe.tryParse(null), isNull);
    });

    // 反馈 tNQr1gO6_2：canvas / 背景图翻页阅读器一屏只有一两页（跨页里单页约 1/3 屏宽），
    // 竖长图计数（≥ 3 张、宽 ≥ 四成屏）永远数不到。
    group('翻页式阅读器', () {
      const Size desktop = Size(1600, 900);
      const Size phone = Size(400, 860);
      WebPageContentProbe flip(
        List<Size> surfaces, {
        Size viewport = desktop,
        bool scrolls = false,
        int t = 0,
        int i = 0,
      }) => WebPageContentProbe(
        largeVideos: 0,
        tallImages: i,
        textLength: t,
        pageSurfaces: surfaces,
        viewport: viewport,
        scrolls: scrolls,
      );

      test('桌面跨页（两张单页 canvas）→ 漫画', () {
        expect(
          classifyWebPageContent(
            flip(const <Size>[Size(560, 830), Size(560, 830)]),
          ),
          WebPageContentKind.comic,
        );
      });

      test('两页拼成一张图面的跨页 → 漫画', () {
        expect(
          classifyWebPageContent(flip(const <Size>[Size(1180, 850)])),
          WebPageContentKind.comic,
        );
      });

      test('手机竖屏单页铺满宽度 → 漫画', () {
        expect(
          classifyWebPageContent(
            flip(const <Size>[Size(400, 580)], viewport: phone),
          ),
          WebPageContentKind.comic,
        );
      });

      test('长滚动页面、正文多、图面太小或形状不像书页都不算', () {
        const List<Size> pages = <Size>[Size(560, 830)];
        // 插画投稿页：一张竖图但页面能往下滚（评论 / 相关作品）。
        expect(classifyWebPageContent(flip(pages, scrolls: true)), isNull);
        // 正文不少的页面。
        expect(
          classifyWebPageContent(flip(pages, t: kWebPageFlipMaxText)),
          isNull,
        );
        // 太矮：不到视口六成高。
        expect(
          classifyWebPageContent(flip(const <Size>[Size(300, 420)])),
          isNull,
        );
        // 整屏地图 / 游戏画布：16:9 横幅、手机上竖长全屏，都不是书页比例。
        expect(
          classifyWebPageContent(flip(const <Size>[Size(1600, 900)])),
          isNull,
        );
        expect(
          classifyWebPageContent(
            flip(const <Size>[
              Size(1024, 640),
            ], viewport: const Size(1024, 640)),
          ),
          isNull,
        );
        expect(
          classifyWebPageContent(
            flip(const <Size>[Size(400, 860)], viewport: phone),
          ),
          isNull,
        );
        // 没有视口读数（老读数）：不触发。
        expect(
          classifyWebPageContent(flip(pages, viewport: Size.zero)),
          isNull,
        );
      });

      test('读数解析：图面列表 / 视口 / 滚动；缺 s 按会滚动', () {
        final WebPageContentProbe? a = WebPageContentProbe.tryParse(
          '{"v":0,"i":0,"t":12,"p":[[560,830],[560,830],"x",[1]],'
          '"w":1600,"h":900,"s":0}',
        );
        expect(a?.pageSurfaces, const <Size>[Size(560, 830), Size(560, 830)]);
        expect(a?.viewport, desktop);
        expect(a?.scrolls, isFalse);
        expect(classifyWebPageContent(a!), WebPageContentKind.comic);
        final WebPageContentProbe? b = WebPageContentProbe.tryParse(
          '{"p":[[560,830]],"w":1600,"h":900}',
        );
        expect(b?.scrolls, isTrue);
        expect(classifyWebPageContent(b!), isNull);
      });

      test('探针脚本在假 DOM 上收到 canvas / 背景图页面，跳过小图与非图元素', () async {
        final Directory dir = Directory.systemTemp.createTempSync(
          'page-probe-',
        );
        try {
          final File script = File('${dir.path}/probe.js')
            ..writeAsStringSync('''
function el(tag, w, h, extra) {
  var e = Object.assign({tagName: tag, parentElement: null,
    getBoundingClientRect: function () { return {width: w, height: h}; }},
    extra || {});
  return e;
}
var left = el('CANVAS', 560, 830, {height: 1600});
var right = el('DIV', 560, 830, {bg: 'url("blob:x")'});
var smallCanvas = el('CANVAS', 560, 830, {height: 300});
var wrapper = el('DIV', 1600, 900, {bg: 'none'});
global.window = {innerWidth: 1600, innerHeight: 900};
global.getComputedStyle = function (e) { return {backgroundImage: e.bg || ''}; };
global.document = {
  images: [],
  querySelectorAll: function () { return []; },
  elementsFromPoint: function (x, y) {
    return x < 800 ? [left, smallCanvas, wrapper] : [right, wrapper];
  },
  scrollingElement: {scrollHeight: 900},
};
var out = JSON.parse(eval(${_jsString(kWebPageContentProbeScript)}));
var want = JSON.stringify({v:0,i:0,t:0,p:[[560,830],[560,830]],w:1600,h:900,s:0});
if (JSON.stringify(out) !== want) {
  console.error('got ' + JSON.stringify(out));
  process.exit(1);
}
''');
          final ProcessResult result = await Process.run('node', <String>[
            script.path,
          ], runInShell: Platform.isWindows);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    });

    test('探针脚本只读：不写 DOM', () {
      expect(kWebPageContentProbeScript, isNot(contains('.innerHTML=')));
      expect(kWebPageContentProbeScript, isNot(contains('appendChild')));
      expect(kWebPageContentProbeScript, contains('JSON.stringify'));
    });

    test('类别变了才通知壳重建工具栏', () {
      final WebPageContentFeature feature = WebPageContentFeature();
      final WebBrowserTab tab = WebBrowserTab(
        id: 't',
        url: Uri.parse('https://example.com/'),
      );
      int notified = 0;
      feature.actionsChanged.addListener(() => notified++);
      feature.debugSetKind(tab, WebPageContentKind.comic);
      feature.debugSetKind(tab, WebPageContentKind.comic);
      expect(notified, 1);
      expect(feature.kindOf(tab), WebPageContentKind.comic);
      feature.onTabClosed(tab);
      expect(feature.kindOf(tab), isNull);
      feature.dispose();
    });
  });

  group('统一入口动作', () {
    test('页面就是这一类：工具栏 + 不带类别的文案；否则收进「⋯」并带类别', () {
      final WebBrowserAction comic = webOpenInFushiAction(
        kind: WebPageContentKind.comic,
        primary: true,
        onPressed: () {},
      );
      expect(comic.id, 'open_in_fushi.comic');
      expect(comic.placement, WebBrowserActionPlacement.toolbar);
      expect(comic.priority, kWebOpenInFushiToolbarPriority);
      expect(comic.label, t.web_browser_read_in_fushi);

      final WebBrowserAction novelMenu = webOpenInFushiAction(
        kind: WebPageContentKind.novel,
        primary: false,
        onPressed: () {},
      );
      expect(novelMenu.placement, WebBrowserActionPlacement.menu);
      expect(novelMenu.label, t.web_browser_read_in_fushi_as_novel);
      expect(
        webOpenInFushiLabel(WebPageContentKind.comic, primary: false),
        t.web_browser_read_in_fushi_as_comic,
      );
      // 播放不分工具栏 / 菜单都是同一句。
      expect(
        webOpenInFushiLabel(WebPageContentKind.video, primary: false),
        t.web_browser_play_in_fushi,
      );
    });

    test('进行中：显示为选中且不可再点', () {
      final WebBrowserAction busy = webOpenInFushiAction(
        kind: WebPageContentKind.video,
        primary: true,
        busy: true,
        onPressed: () {},
      );
      expect(busy.selected, isTrue);
      expect(busy.onPressed, isNull);
    });

    // 漫画功能的摆放是同一行判据（kindOf == comic），它的动作要读 appProvider，这里只测小说那支。
    testWidgets('小说功能按探针结果决定上工具栏还是收进「⋯」', (WidgetTester tester) async {
      final WebPageContentFeature content = WebPageContentFeature();
      final WebBrowserTab page = WebBrowserTab(
        id: 'p',
        url: Uri.parse('https://example.com/chapter/1'),
      );
      late List<WebBrowserAction> novelActions;
      Future<void> build() => tester.pumpWidget(
        ProviderScope(
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              novelActions = WebNovelFeature(
                ref: ref,
                pageContent: content,
              ).actions(context, page);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      WebBrowserActionPlacement? placementOf(
        List<WebBrowserAction> actions,
        String id,
      ) {
        for (final WebBrowserAction a in actions) {
          if (a.id == id) return a.placement;
        }
        return null;
      }

      content.debugSetKind(page, WebPageContentKind.novel);
      await build();
      if (webNovelReaderActionAvailable()) {
        expect(
          placementOf(novelActions, 'open_in_fushi.novel'),
          WebBrowserActionPlacement.toolbar,
        );
      }

      content.debugSetKind(page, WebPageContentKind.comic);
      await build();
      if (webNovelReaderActionAvailable()) {
        expect(
          placementOf(novelActions, 'open_in_fushi.novel'),
          WebBrowserActionPlacement.menu,
        );
      }
      content.dispose();
    });
  });

  test('播放器层交回浏览器的地址：单槽，取走即清空', () {
    expect(WebVideoBrowserReturn.take(), isNull);
    WebVideoBrowserReturn.offer(Uri.parse('https://www.netflix.com/browse'));
    WebVideoBrowserReturn.offer(Uri.parse('https://www.netflix.com/title/1'));
    expect(
      WebVideoBrowserReturn.take(),
      Uri.parse('https://www.netflix.com/title/1'),
    );
    expect(WebVideoBrowserReturn.take(), isNull);
  });
}

/// Dart 字符串 → JS 字符串字面量（JSON 编码即合法 JS）。
String _jsString(String value) => jsonEncode(value);
