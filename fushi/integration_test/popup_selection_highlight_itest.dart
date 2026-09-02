import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 选中制卡高亮的**真 DOM** 验证：在查词弹窗里选中的释义段，必须在制卡导出的
/// 释义 HTML 里被 `<mark class="fushi-selection">` 标在**同一个位置**上。
///
/// 为什么只能在真 WebView 里测：这条链路的全部风险在「屏幕 DOM 上算出的字符区间
/// 能不能在**另一棵重新渲染出来的导出树**上定位到同一段文字」，依赖的是真实的
/// `Range.comparePoint` / `compareBoundaryPoints` / `TreeWalker` / `splitText`
/// 语义。`test/utils/misc/popup_asset_behavior_test.js` 的手写 fake DOM 没有这些
/// 原语，补一套出来只会变成「用我自己的假设验证我自己的假设」的假绿。
///
/// 三条断言各自钉一个独立的失败模式：
///   1. 跨元素选中 → 每个文本节点各自成 mark，拼起来逐字等于选中文本，且只落在
///      被选中的那一条义项上（位置对，不是「文本里搜到就标」）。
///   2. 图片后面的文本 → 导出端在不嵌媒体时会把图片 alt 写成**可见文本**
///      （createDefinitionImage 的 `image.textContent = alt`），屏幕端只有
///      `<img>` 不产文本。两侧不一起跳过 `.gloss-image-link` 的话，这一条的
///      mark 必然整体后移 alt 的长度。
///   3. 选中落在释义之外（词头）→ 一个 mark 都不该有，且 popupSelectionText
///      必须原样保留，用户的选中不能凭空消失。
///   4. 高亮落地 → payload 如实上报 `glossarySelectionHighlighted: true`，而
///      `popupSelectionText` **照样原样带着**。SelectionText 要不要让位是 Dart
///      层的决定（只有那一层知道笔记类型和字段映射，见
///      `BaseAnkiRepository.shouldYieldSelectionText` 与
///      `packages/fushi_anki/test/selection_text_yield_test.dart`）。
///
/// 跑法（仓库 fushi/ 下，离屏、不抢焦点、隔离 WebView2 profile）：
///   .\tool\run_windows_itest.ps1 integration_test\popup_selection_highlight_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('选中的释义段在导出的卡片释义里被 mark 标在同一位置',
      (WidgetTester tester) async {
    final String popupJs = await rootBundle.loadString('assets/popup/popup.js');
    final String dictMediaJs =
        await rootBundle.loadString('assets/popup/dict-media.js');

    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
                '<body><div class="overlay"></div>'
                '<div id="entries-container"></div></body></html>',
          ),
          onLoadStop: (InAppWebViewController controller, WebUri? url) {
            if (!ready.isCompleted) ready.complete(controller);
          },
        ),
      ),
    ));
    for (int i = 0; i < 150 && !ready.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready.isCompleted, isTrue, reason: 'WebView 15s 内未加载');
    final InAppWebViewController controller = await ready.future;

    await controller.evaluateJavascript(source: '''
      window.flutter_inappwebview = {
        callHandler: function() { return Promise.resolve(true); }
      };
    ''');
    // alias 必须与加载在同一次 eval 里，否则后续 eval 拿不到顶层函数。
    await controller.evaluateJavascript(
      source: '$dictMediaJs\n$popupJs\n'
          'window.__t = { buildEntryElement: buildEntryElement, '
          'snapshotSelection: snapshotSelection, '
          'constructSingleGlossaryHtml: constructSingleGlossaryHtml, '
          'constructGlossaryHtml: constructGlossaryHtml, '
          'buildMinePayload: buildMinePayload };',
    );

    // 三条义项同属一本词典，故屏幕侧走 ol/li 分支、导出侧合并成一个 html：
    //   [0] 纯文本，用来验证「没被选中的义项不许染上 mark」
    //   [1] 例句拆成三个文本节点（span / em / span），验证跨元素选中
    //   [2] 图片 + 文本，验证导出端多出来的图片 alt 文本不会把偏移顶偏
    await controller.evaluateJavascript(source: '''
      window.hiddenDictionaryNames = [];
      window.dictionaryStyles = {};
      window.compactGlossaries = false;
      window.compactGlossariesAnki = false;
      window.useAnkiConnect = false;
      window.embedMedia = false;
      window.audioSources = [];
      window.needsAudio = false;
      window.lookupEntries = [{
        expression: 'に',
        reading: 'に',
        glossaries: [
          {
            dictionary: 'TestDict',
            content: {tag: 'div', content: '別の語義。'},
            definitionTags: '',
            termTags: ''
          },
          {
            dictionary: 'TestDict',
            content: {tag: 'div', content: [
              {tag: 'span', content: '一日に'},
              {tag: 'em', content: '三回'},
              {tag: 'span', content: '食べる'}
            ]},
            definitionTags: '',
            termTags: ''
          },
          {
            dictionary: 'TestDict',
            content: {tag: 'div', content: [
              {tag: 'img', path: 'figure.png', title: 'ALTALTALT'},
              {tag: 'span', content: '図のあとの本文'}
            ]},
            definitionTags: '',
            termTags: ''
          }
        ]
      }];
      var el0 = window.__t.buildEntryElement(window.lookupEntries[0], 0);
      document.getElementById('entries-container').appendChild(el0);
      window.__t.helpers = {
        textNodes: function(root) {
          var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          var out = [];
          var n;
          while ((n = w.nextNode())) out.push(n);
          return out;
        },
        host: function(glossIndex) {
          return document.querySelector('[data-fushi-gloss="' + glossIndex + '"]');
        },
        select: function(startNode, startOff, endNode, endOff) {
          var r = document.createRange();
          r.setStart(startNode, startOff);
          r.setEnd(endNode, endOff);
          var s = window.getSelection();
          s.removeAllRanges();
          s.addRange(r);
          return r.toString();
        },
        marks: function(html) {
          var d = document.createElement('div');
          d.innerHTML = html;
          return Array.prototype.map.call(
            d.querySelectorAll('mark.fushi-selection'),
            function(m) { return m.textContent; });
        },
        markedItems: function(html) {
          var d = document.createElement('div');
          d.innerHTML = html;
          var lis = d.querySelectorAll('li[data-dictionary]');
          var out = [];
          for (var i = 0; i < lis.length; i++) {
            if (lis[i].querySelector('mark.fushi-selection')) out.push(i);
          }
          return out;
        },
        markStyle: function(html) {
          var d = document.createElement('div');
          d.innerHTML = html;
          var m = d.querySelector('mark.fushi-selection');
          return m ? (m.getAttribute('style') || '') : '';
        }
      };
    ''');

    // 屏幕 DOM 真的带上了坐标锚点，否则后面一切都是空转。
    final Object? anchors = await controller.evaluateJavascript(
        source: "document.querySelectorAll('[data-fushi-gloss]').length");
    expect(int.parse('$anchors'), 3,
        reason: '三条义项都必须带 data-fushi-gloss 锚点');

    // ---- 1. 跨元素选中 -------------------------------------------------
    final Object? crossRaw = await controller.evaluateJavascript(source: '''
      (function() {
        var h = window.__t.helpers;
        var host = h.host(1);
        var nodes = h.textNodes(host);
        var picked = h.select(nodes[0], 0, nodes[nodes.length - 1],
            nodes[nodes.length - 1].nodeValue.length);
        window.__t.snapshotSelection();
        var single = window.__t.constructSingleGlossaryHtml(0);
        var html = single['TestDict'];
        var all = window.__t.constructGlossaryHtml(0);
        return JSON.stringify({
          picked: picked,
          nodeCount: nodes.length,
          marks: h.marks(html),
          markedItems: h.markedItems(html),
          glossaryMarks: h.marks(all.glossary || all),
          style: h.markStyle(html)
        });
      })()
    ''');
    final Map<String, dynamic> cross =
        jsonDecode('$crossRaw') as Map<String, dynamic>;

    expect(cross['picked'], '一日に三回食べる',
        reason: '测试自身的前提：选中的确实是跨三个文本节点的整句');
    expect(cross['nodeCount'], 3, reason: '这一条义项必须真的由三个文本节点组成');
    final List<dynamic> marks = cross['marks'] as List<dynamic>;
    expect(marks.join(), '一日に三回食べる',
        reason: '导出的释义里，mark 拼起来必须逐字等于选中的文本');
    expect(marks.length, 3,
        reason: '跨元素选中不能把结构压平，应当每个文本节点各自成 mark');
    expect(cross['markedItems'], <int>[1],
        reason: '高亮只能落在被选中的那一条义项上，不能污染其它义项');
    expect((cross['glossaryMarks'] as List<dynamic>).join(), '一日に三回食べる',
        reason: 'Glossary 字段（全部词典）与 MainDefinition 必须同样带高亮');
    expect('${cross['style']}'.contains('background-color'), isTrue,
        reason: '出厂默认色必须写成 inline style，不能依赖笔记类型 CSS 存在');
    expect('${cross['style']}'.contains('color: inherit'), isTrue,
        reason: '不显式写 color 的话 <mark> 的浏览器默认前景色在暗色卡上是黑字');

    // ---- 2. 图片之后的文本（导出端多出 alt 文本的缺口）------------------
    final Object? afterImageRaw = await controller.evaluateJavascript(source: '''
      (function() {
        var h = window.__t.helpers;
        var host = h.host(2);
        var nodes = h.textNodes(host);
        var target = nodes[nodes.length - 1];
        var picked = h.select(target, 0, target, 4);
        window.__t.snapshotSelection();
        var html = window.__t.constructSingleGlossaryHtml(0)['TestDict'];
        return JSON.stringify({
          picked: picked,
          marks: h.marks(html),
          markedItems: h.markedItems(html),
          exportHasAlt: html.indexOf('ALTALTALT') >= 0
        });
      })()
    ''');
    final Map<String, dynamic> afterImage =
        jsonDecode('$afterImageRaw') as Map<String, dynamic>;

    expect(afterImage['picked'], '図のあと',
        reason: '测试自身的前提：选中的是图片后面那段文本的前三个字');
    expect(afterImage['exportHasAlt'], isTrue,
        reason:
            '这一条测试的意义全在于导出树确实多出了图片 alt 文本；不再多出时说明 '
            'createDefinitionImage 变了，本用例要重新设计而不是删掉');
    expect((afterImage['marks'] as List<dynamic>).join(), '図のあと',
        reason: '图片 alt 只存在于导出树，不跳过它就会把 mark 整体顶偏 alt 的长度');
    expect(afterImage['markedItems'], <int>[2],
        reason: '高亮必须落在含图片的那一条义项上');

    // ---- 3. 选中落在释义之外 -------------------------------------------
    final Object? outsideRaw = await controller.evaluateJavascript(source: '''
      (function() {
        var h = window.__t.helpers;
        var header = document.querySelector('.expression');
        var nodes = h.textNodes(header);
        var picked = nodes.length
          ? h.select(nodes[0], 0, nodes[0], nodes[0].nodeValue.length)
          : '';
        window.__t.snapshotSelection();
        var html = window.__t.constructSingleGlossaryHtml(0)['TestDict'];
        window.__payload = null;
        window.__t.buildMinePayload('に', 'に', [], [], [], 'に', 0, picked)
          .then(function(p) { window.__payload = p; });
        return JSON.stringify({
          picked: picked,
          marks: h.marks(html)
        });
      })()
    ''');
    final Map<String, dynamic> outside =
        jsonDecode('$outsideRaw') as Map<String, dynamic>;
    expect('${outside['picked']}'.isNotEmpty, isTrue,
        reason: '测试自身的前提：词头上确实选中了文本');
    expect(outside['marks'], isEmpty,
        reason: '选中落在释义之外时一个 mark 都不该有');

    for (int i = 0; i < 50; i++) {
      final Object? done = await controller.evaluateJavascript(
          source: 'window.__payload ? 1 : 0');
      if ('$done' == '1') break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Object? keptRaw = await controller.evaluateJavascript(
        source: 'window.__payload ? window.__payload.popupSelectionText : null');
    expect('$keptRaw'.isNotEmpty && '$keptRaw' != 'null', isTrue,
        reason: '没落下高亮时必须原样保留 popupSelectionText，否则用户的选中凭空消失');
    final Object? notFlagged = await controller.evaluateJavascript(
        source: 'window.__payload ? '
            'String(window.__payload.glossarySelectionHighlighted) : "MISSING"');
    expect('$notFlagged', 'false',
        reason: '一个 mark 都没落下就报 true，Dart 层会白白让位、选中真的消失');

    // ---- 4. 高亮落地时如实上报标志，正文照旧原样带着 --------------------
    final Object? clearedRaw = await controller.evaluateJavascript(source: '''
      (function() {
        var h = window.__t.helpers;
        var host = h.host(1);
        var nodes = h.textNodes(host);
        var picked = h.select(nodes[0], 0, nodes[nodes.length - 1],
            nodes[nodes.length - 1].nodeValue.length);
        window.__t.snapshotSelection();
        window.__payload2 = null;
        window.__t.buildMinePayload('に', 'に', [], [], [], 'に', 0, picked)
          .then(function(p) { window.__payload2 = p; });
        return JSON.stringify({picked: picked});
      })()
    ''');
    expect('$clearedRaw'.contains('一日に三回食べる'), isTrue);

    for (int i = 0; i < 50; i++) {
      final Object? done = await controller.evaluateJavascript(
          source: 'window.__payload2 ? 1 : 0');
      if ('$done' == '1') break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Object? keptWhenHighlighted = await controller.evaluateJavascript(
        source:
            'window.__payload2 ? window.__payload2.popupSelectionText : "MISSING"');
    expect('$keptWhenHighlighted'.contains('一日に三回食べる'), isTrue,
        reason: 'popup.js 不许自作主张清空——它不知道用户的笔记类型和字段映射，'
            '清了就可能让选中的内容凭空消失');
    final Object? flagged = await controller.evaluateJavascript(
        source: 'window.__payload2 ? '
            'String(window.__payload2.glossarySelectionHighlighted) : "MISSING"');
    expect('$flagged', 'true',
        reason: '高亮落地这件客观事实必须上报，Dart 层据此决定 SelectionText 让不让位');
    final Object? clearedGlossary = await controller.evaluateJavascript(
        source: 'window.__payload2 ? '
            'window.__payload2.glossary.indexOf("fushi-selection") >= 0 : false');
    expect('$clearedGlossary', 'true',
        reason: '让位的前提是高亮真的在 payload 的释义里');
  });
}
