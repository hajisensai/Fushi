import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_chrome_floating.dart';

import '../helpers/source_guard.dart';
import 'reader_hibiki_page_source_corpus.dart';

/// BUG-379：歌词模式（LyricsModeHtml）进度条跑进底栏。
///
/// 歌词页是独立 HTML，没有 `window.fushiReader`，`_applyChromeInsets` 对它整体
/// early-return，正文那套「告诉 WebView 底栏预留高度」的机制对歌词页失效。歌词 WebView
/// 仍 `Positioned.fill` 铺满全屏，底栏（`_buildAudiobookBar`，bottom:0）盖在其上，歌词
/// 文档级 CSS 滚动条（主题化的细条）沿整屏高度绘制，底部一段被绘制进底栏区域 → 看上去
/// 像「进度条跑进底栏」。修复：底栏可见时把歌词 WebView 收缩 `_readerBottomReserve`。
///
/// BUG-1381：**这个守卫本身**曾把契约写成实现拼写
/// `body.contains('EdgeInsets.only(bottom: _readerBottomReserve)')`。PR#670（BUG-1343）
/// 给独立文档补顶部 macOS 标题栏缩进，把顶/底两笔留白合成同一个 `EdgeInsets.only(top:…,
/// bottom:…)`——底部预留分毫未变，守卫却在 develop 上红了。这是本仓已定案的 B 类
/// 「要求型」锚点失效模式：换个匹配器只是把下一次重构的红往后推。
///
/// 所以契约被抬到纯函数 [independentDocumentInsets]：
///  * **行为层**（下面第一组测试）直接钉数值——歌词 + 底栏占位 ⇒ 底部 == 预留高。
///    与写法、参数顺序、包几层 Padding 全部无关，是真正不怕重构的判据。
///  * **接线层**（第二组）只钉一件源码事实：`_buildBody` 的留白必须来自那个纯函数，
///    不得就地拼 `EdgeInsets`。reader 页含真实 `InAppWebView` 平台视图，widget 测试挂
///    不起整页，这一层只能靠源码扫描；但它钉的是「谁负责算」，不是「怎么写」。
void main() {
  group('independentDocumentInsets（独立 HTML 文档留白契约）', () {
    const double reserve = 72;
    const double titlebar = 28;

    EdgeInsets insets({
      required bool lyricsMode,
      bool spreadDocumentLoaded = false,
      required bool chromeOccupiesLayout,
      double bottomReserve = reserve,
      double titlebarInset = 0,
    }) {
      return independentDocumentInsets(
        lyricsMode: lyricsMode,
        spreadDocumentLoaded: spreadDocumentLoaded,
        chromeOccupiesLayout: chromeOccupiesLayout,
        bottomReserve: bottomReserve,
        titlebarInset: titlebarInset,
      );
    }

    test('歌词模式 + 底栏占位：底部预留 == 底栏预留高（BUG-379 本体）', () {
      expect(
        insets(lyricsMode: true, chromeOccupiesLayout: true).bottom,
        reserve,
        reason: '底部预留必须等于 _readerBottomReserve，否则 CSS 滚动条画进底栏',
      );
    });

    test('底栏预留高变了，留白跟着变（不得硬编码常量）', () {
      expect(
        insets(
          lyricsMode: true,
          chromeOccupiesLayout: true,
          bottomReserve: 123.5,
        ).bottom,
        123.5,
      );
      // 悬浮底栏不占正文位置 ⇒ bottomChromeReserve 已为 0，留白也必须为 0。
      expect(
        insets(lyricsMode: true, chromeOccupiesLayout: true, bottomReserve: 0)
            .bottom,
        0,
      );
    });

    test('底栏未占位（_hasEverLoaded && _showChrome 为假）：不留底部', () {
      expect(insets(lyricsMode: true, chromeOccupiesLayout: false).bottom, 0);
    });

    test('正文模式不留底部（正文走 setChromeInsets，重复留白会挖掉一条空白）', () {
      expect(insets(lyricsMode: false, chromeOccupiesLayout: true).bottom, 0);
      expect(
        insets(
          lyricsMode: false,
          spreadDocumentLoaded: true,
          chromeOccupiesLayout: true,
        ).bottom,
        0,
        reason: 'spread 没有文档级滚动条，不需要也不应吃底栏预留',
      );
    });

    test('BUG-1343：歌词 / spread 顶部缩进标题栏高，正文不缩进', () {
      expect(
        insets(
          lyricsMode: true,
          chromeOccupiesLayout: true,
          titlebarInset: titlebar,
        ).top,
        titlebar,
      );
      expect(
        insets(
          lyricsMode: false,
          spreadDocumentLoaded: true,
          chromeOccupiesLayout: false,
          titlebarInset: titlebar,
        ).top,
        titlebar,
      );
      expect(
        insets(
          lyricsMode: false,
          chromeOccupiesLayout: true,
          titlebarInset: titlebar,
        ).top,
        0,
      );
    });

    test('两笔留白都为 0 时返回 EdgeInsets.zero（调用方据此跳过 Padding）', () {
      expect(
        insets(lyricsMode: false, chromeOccupiesLayout: true),
        EdgeInsets.zero,
      );
      expect(
        insets(lyricsMode: true, chromeOccupiesLayout: true, bottomReserve: 0),
        EdgeInsets.zero,
      );
    });
  });

  group('_buildBody 接线', () {
    final String body =
        methodBody(readReaderPageSource(), '  Widget _buildBody()');

    test('留白只能来自 independentDocumentInsets（单一真相源）', () {
      expect(
        containsIdentifierCall(body, 'independentDocumentInsets'),
        isTrue,
        reason: '_buildBody 必须把独立文档留白委托给纯函数，行为契约才有单测钉得住',
      );
      expect(
        containsIdentifierCall(body, 'Padding'),
        isTrue,
        reason: '算出来的留白必须真包成 Padding 作用到 WebView 上',
      );
    });

    test('不得就地拼 EdgeInsets（绕开纯函数 = 绕开上面那组行为断言）', () {
      expect(
        containsIdentifierCall(body, 'EdgeInsets'),
        isFalse,
        reason: '_buildBody 里出现 EdgeInsets 构造（如 EdgeInsets.only(bottom: …)）'
            '意味着留白重新长回页面里，纯函数单测再绿也不代表真实渲染留了空间',
      );
    });
  });
}
