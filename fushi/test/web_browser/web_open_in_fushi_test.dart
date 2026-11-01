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
