import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/observe_capture.dart';

/// BUG-4479 真 WebView 验证：查词弹窗的制卡快捷键跟随**当前词条**，「＋」带快捷键提示。
///
/// 生产 `assets/popup/popup.js` + `popup.css` 原样塞进真 WebView2，用生产 `renderPopup`
/// 渲染三个真词条，再派发**真 DOM 事件**走生产监听：
///   1. Alt+滚轮下 ×3（默认的「下一个词条」绑定；第一下先落第 1 个词条）→ 当前词条移到第 3 个；
///   2. Ctrl+Enter（popup.js 内置默认的制卡键）→ `mineEntry` 桥收到的必须是第 3 个词条；
///   3. 悬停第 1 个「＋」→ 自绘提示里是宿主注入的快捷键整句。
///
/// 跑法（仓库 fushi/ 下，离屏、不抢焦点、隔离 WebView2 profile / APPDATA）：
///   .\tool\run_windows_itest.ps1 integration_test/popup_mine_focused_entry_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BUG-4479: Ctrl+Enter 制的是 Alt+滚轮移到的词条；「＋」提示快捷键', (
    WidgetTester tester,
  ) async {
    final String popupJs = await rootBundle.loadString('assets/popup/popup.js');
    final String popupCss = await rootBundle.loadString(
      'assets/popup/popup.css',
    );
    final String dictMediaJs = await rootBundle.loadString(
      'assets/popup/dict-media.js',
    );

    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 640,
            child: InAppWebView(
              initialData: InAppWebViewInitialData(
                data:
                    '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
                    '<body><div id="entries-container"></div></body></html>',
              ),
              onLoadStop: (InAppWebViewController controller, WebUri? url) {
                if (!ready.isCompleted) ready.complete(controller);
              },
            ),
          ),
        ),
      ),
    );
    for (int i = 0; i < 150 && !ready.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready.isCompleted, isTrue, reason: 'WebView 15s 内未加载');
    final InAppWebViewController controller = await ready.future;

    // 宿主桥桩：记下每次调用；查重恒为「未制卡」，制卡回执成功。
    await controller.evaluateJavascript(
      source: '''
      window.__calls = [];
      window.flutter_inappwebview = {
        callHandler: function(name, payload) {
          window.__calls.push({ name: name, payload: payload });
          if (name === 'duplicateCheck') return Promise.resolve(false);
          if (name === 'overwriteTargetNoteId') return Promise.resolve(null);
          if (name === 'mineEntry') {
            return Promise.resolve({ ankiConnect: true, noteId: 7 });
          }
          return Promise.resolve(null);
        }
      };
      window.allowDupes = true;
      window.i18nMineShortcutHint = 'Create card (Ctrl+Enter)';
    ''',
    );
    await controller.evaluateJavascript(source: '$dictMediaJs\n$popupJs');

    String gloss(String text) => jsonEncode(<String, Object>{
      'dictionary': 'Test dict',
      'content': <String, Object>{'tag': 'span', 'content': text},
      'definitionTags': '',
      'termTags': '',
    });
    await controller.evaluateJavascript(
      source:
          '''
      (function() {
        var style = document.createElement('style');
        style.textContent = ${jsonEncode(popupCss)};
        document.head.appendChild(style);
        window.kanjiResults = [];
        window.lookupEntries = [
          { expression: '辞書', reading: 'じしょ', glossaries: [${gloss('dictionary')}] },
          { expression: '事典', reading: 'じてん', glossaries: [${gloss('encyclopedia')}] },
          { expression: '事項', reading: 'じこう', glossaries: [${gloss('matter; item')}] }
        ];
        window.renderPopup();
      })();
    ''',
    );
    await tester.pump(const Duration(seconds: 2));

    Future<Map<String, dynamic>> probe(String js) async {
      final Object? raw = await controller.evaluateJavascript(source: js);
      return jsonDecode(raw?.toString() ?? '{}') as Map<String, dynamic>;
    }

    final Map<String, dynamic> rendered = await probe('''
      JSON.stringify({
        entries: document.querySelectorAll('#entries-container > .entry').length,
        mineButtons: document.querySelectorAll('.mine-button').length
      })
    ''');
    debugPrint('[BUG-4479] rendered: ${jsonEncode(rendered)}');
    expect(rendered['entries'], 3, reason: '生产 renderPopup 必须渲染出三个词条');
    expect(rendered['mineButtons'], 3);

    // ① 真滚轮事件：Alt+滚轮下三次。还没有当前词条时第一下落第 1 个（moveEntry 既有语义），
    // 之后每下前进一个 → 第 3 个。
    final Map<String, dynamic> moved = await probe('''
      (function() {
        var target = document.querySelector('#entries-container > .entry');
        for (var i = 0; i < 3; i++) {
          target.dispatchEvent(new WheelEvent('wheel', {
            deltaY: 100, altKey: true, bubbles: true, cancelable: true
          }));
        }
        var entries = document.querySelectorAll('#entries-container > .entry');
        var current = -1;
        for (var j = 0; j < entries.length; j++) {
          if (entries[j].classList.contains('entry-current')) current = j;
        }
        return JSON.stringify({ current: current });
      })()
    ''');
    debugPrint('[BUG-4479] after Alt+wheel x3: ${jsonEncode(moved)}');
    expect(moved['current'], 2, reason: 'Alt+滚轮下三次应聚焦第 3 个词条');

    // ② 真键盘事件：Ctrl+Enter（popup.js 无注入时的内置默认制卡键）。
    await controller.evaluateJavascript(
      source: '''
      document.body.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Enter', code: 'Enter', ctrlKey: true, bubbles: true, cancelable: true
      }));
    ''',
    );
    await tester.pump(const Duration(seconds: 2));
    final Map<String, dynamic> mined = await probe('''
      JSON.stringify({
        mined: window.__calls
          .filter(function(c) { return c.name === 'mineEntry'; })
          .map(function(c) { return c.payload && c.payload.expression; }),
        buttons: Array.prototype.map.call(
          document.querySelectorAll('.mine-button'),
          function(b) { return b.textContent; })
      })
    ''');
    debugPrint('[BUG-4479] after Ctrl+Enter: ${jsonEncode(mined)}');
    expect(mined['mined'], <String>[
      '事項',
    ], reason: 'Ctrl+Enter 必须给当前（第 3 个）词条制卡，且只制一张');

    // ③ 悬停第 1 个「＋」：自绘提示显示宿主注入的快捷键整句。
    await controller.evaluateJavascript(
      source: '''
      document.querySelector('.mine-button').dispatchEvent(
        new PointerEvent('pointerenter', { bubbles: false }));
    ''',
    );
    await tester.pump(const Duration(seconds: 1));
    final Map<String, dynamic> tip = await probe('''
      (function() {
        var b = document.querySelector('.mine-button');
        var tipEl = document.querySelector('.fushi-btn-tip, .inline-button-tip, [class*="tip"].visible');
        return JSON.stringify({
          dataTip: b.dataset.fushiTip || null,
          ariaLabel: b.getAttribute('aria-label'),
          tipText: tipEl ? tipEl.textContent : null
        });
      })()
    ''');
    debugPrint('[BUG-4479] hover tip: ${jsonEncode(tip)}');
    expect(tip['dataTip'], 'Create card (Ctrl+Enter)');
    expect(tip['ariaLabel'], 'Create card (Ctrl+Enter)');

    final Uint8List? png = await controller.takeScreenshot();
    if (png != null && png.isNotEmpty) {
      final String path =
          '${observeScreenshotDir().path}/bug4479-mine-focused-entry.png';
      await File(path).writeAsBytes(png, flush: true);
      debugPrint('[BUG-4479] screenshot: $path (${png.length} bytes)');
    } else {
      debugPrint('[BUG-4479] screenshot: WebView returned no pixels');
    }
  });
}
