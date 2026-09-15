/// BUG-2553 / BUG-2554：查词弹窗开着时连点换词 + 被查词高亮。
///
/// 两条链都跨 Flutter（dismiss barrier）与 WebView（覆盖层 JS），widget 测试
/// 驱动不到真 WebView，所以分三层钉：
/// 1. 覆盖层文档契约：barrier 转发入口存在、三态返回值、`::highlight` 规则；
/// 2. 纯函数 `barrierTapClosesPopup`：三态 → 关不关栈；
/// 3. 页面源码守卫：钩子真的覆写了、坐标真的逆映了、高亮真的 eval 了。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import '../../helpers/source_guard.dart';

const List<MokuroImage> _pages = <MokuroImage>[
  MokuroImage(
    url: 'p001.jpg',
    size: MokuroSize(1000, 1600),
    blocks: <MokuroBlock>[],
  ),
];

String _document() {
  return mangaWindowDocument(
    _pages,
    const <String>['https://manga.local/img/p001.jpg'],
    mode: MangaReadingMode.spread,
    spreadDirection: 'rtl',
    inlineSelectionJs: '/* selection */',
  );
}

void main() {
  group('BUG-2553 覆盖层：barrier 转发入口', () {
    test('暴露 __mangaBarrierTapAt / __mangaBarrierHoverAt', () {
      final String doc = _document();
      expect(doc, contains('window.__mangaBarrierTapAt = function(x, y)'));
      expect(doc, contains('window.__mangaBarrierHoverAt = function(x, y)'));
    });

    test('点击入口回三态字符串，悬停入口走 fromHover=true', () {
      final String doc = _document();
      final String tap = methodBody(
        doc,
        'window.__mangaBarrierTapAt = function(x, y)',
        lexicon: SourceLexicon.js,
      );
      expect(tap, contains('_selectOcrCharDetail(x, y, false)'));
      expect(tap, contains("return 'miss'"), reason: '异常也要回 miss，Dart 才会关栈');
      final String hover = methodBody(
        doc,
        'window.__mangaBarrierHoverAt = function(x, y)',
        lexicon: SourceLexicon.js,
      );
      expect(hover, contains('_selectOcrChar(x, y, true)'));
    });

    test('_selectOcrCharDetail 三态：miss / same / hit', () {
      final String doc = _document();
      final String body = methodBody(
        doc,
        'function _selectOcrCharDetail(x, y, fromHover)',
        lexicon: SourceLexicon.js,
      );
      expect(body, contains("return 'miss'"));
      expect(body, contains("return 'same'"));
      expect(body, contains("return 'hit'"));
      // 只有真选中新字才 fire onTextSelected 的那条路径（selectFromPosition）。
      expect(body, contains('selection.selectFromPosition(node, 0, 40, x, y)'));
    });

    test('原有 _selectOcrChar 仍是布尔封装（点击/悬停/回放路径不变）', () {
      final String doc = _document();
      final String body = methodBody(
        doc,
        'function _selectOcrChar(x, y, fromHover)',
        lexicon: SourceLexicon.js,
      );
      expect(
          body, contains("_selectOcrCharDetail(x, y, fromHover) !== 'miss'"));
      final String tap = methodBody(
        doc,
        'function _onTap(x, y)',
        lexicon: SourceLexicon.js,
      );
      expect(tap, contains('_selectOcrChar(x, y, false)'),
          reason: 'WebView 内的原生点击路径仍走布尔封装，不受三态改动影响');
    });
  });

  group('BUG-2554 覆盖层：被查词高亮样式', () {
    test('文档带 ::highlight(fushi-selection) 规则', () {
      final String doc = _document();
      expect(doc, contains('::highlight(fushi-selection){background-color:'));
    });
  });

  group('BUG-2553 纯函数 barrierTapClosesPopup', () {
    test('命中新字（裸串 / JSON 引号串）保留弹窗', () {
      expect(MangaFushiPage.barrierTapClosesPopup('hit'), isFalse);
      expect(MangaFushiPage.barrierTapClosesPopup('"hit"'), isFalse);
      expect(MangaFushiPage.barrierTapClosesPopup(' hit '), isFalse);
    });

    test('同字 / 空白 / 未知值 / 非字符串一律关栈', () {
      expect(MangaFushiPage.barrierTapClosesPopup('same'), isTrue);
      expect(MangaFushiPage.barrierTapClosesPopup('miss'), isTrue);
      expect(MangaFushiPage.barrierTapClosesPopup('"miss"'), isTrue);
      expect(MangaFushiPage.barrierTapClosesPopup(''), isTrue);
      expect(MangaFushiPage.barrierTapClosesPopup(null), isTrue);
      expect(MangaFushiPage.barrierTapClosesPopup(true), isTrue);
      expect(MangaFushiPage.barrierTapClosesPopup(42), isTrue);
    });
  });

  group('页面源码守卫（私有 State 方法，行为测试够不到）', () {
    final String source = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final String code = maskComments(source);

    test('BUG-2553：覆写 onDismissBarrierTap，逆映坐标后转发覆盖层，miss 才关栈', () {
      final String body = methodBody(
        code,
        'void onDismissBarrierTap(Offset globalPos)',
      );
      expect(body, contains('_webViewLocalFromGlobal(globalPos)'));
      expect(body, contains('clearDictionaryResult();'),
          reason: 'WebView 不可用时必须退回默认关栈，不能让弹窗卡死');
      expect(body, contains('_forwardBarrierTap(controller, local)'));

      final String forward = methodBody(
        code,
        'Future<void> _forwardBarrierTap(',
      );
      expect(forward, contains('window.__mangaBarrierTapAt('));
      expect(forward, contains('MangaFushiPage.barrierTapClosesPopup(raw)'));
      expect(forward, contains('clearDictionaryResult()'));
    });

    test('BUG-2553：坐标逆映走 WebView 宿主 RenderBox 的 globalToLocal', () {
      final String body = methodBody(
        code,
        'Offset? _webViewLocalFromGlobal(Offset globalPos)',
      );
      expect(body, contains('_webViewHostKey.currentContext'));
      expect(body, contains('obj.globalToLocal(globalPos)'));
      // 宿主 key 必须包在死亡守卫重建子树外面（否则重建时 GlobalKey 被 reparent）。
      expect(
        code,
        contains('KeyedSubtree(key: _webViewHostKey, child: _buildWebView())'),
      );
    });

    test('BUG-2553：覆写 onDismissBarrierHover（Shift 悬停连查）', () {
      final String body = methodBody(
        code,
        'void onDismissBarrierHover(PointerHoverEvent event)',
      );
      expect(body, contains('HardwareKeyboard.instance.isShiftPressed'));
      expect(body, contains('window.__mangaBarrierHoverAt('));
    });

    test('BUG-2554：查词返回的 highlightCount 必须喂给高亮 eval', () {
      final String body = methodBody(
        code,
        'Future<void> processMangaSelection(ReaderSelectionData data)',
      );
      expect(
        body,
        contains('final int highlightCount = await searchDictionaryResult('),
        reason: '此前返回值被直接丢弃，覆盖层永远不画高亮',
      );
      expect(body, contains('_highlightMangaSelection(highlightCount)'));

      final String highlight = methodBody(
        code,
        'Future<void> _highlightMangaSelection(int highlightCount)',
      );
      expect(
        highlight,
        contains('ReaderSelectionScripts.highlightInvocation(highlightCount)'),
      );
    });

    test('BUG-2554：整栈关闭时清覆盖层高亮', () {
      final String body = methodBody(code, 'void onAllPopupsDismissed()');
      expect(body, contains('_clearMangaSelectionHighlight()'));
      final String clear = methodBody(
        code,
        'Future<void> _clearMangaSelectionHighlight()',
      );
      expect(clear, contains('ReaderSelectionScripts.clearInvocation()'));
    });
  });
}
