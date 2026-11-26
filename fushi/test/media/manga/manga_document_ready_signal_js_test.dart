import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-5495（反馈 eMhRJkkQOW / wMp05jI72s / p8PxXVb-xH）：窗口文档要在脚本跑完时
/// 自报 generation，而不是只等 `onLoadStop`——后者跟着 load 事件，要等首屏 eager
/// 页图全部经 `shouldInterceptRequest` 取完、转码完，Android 上动辄超过 10 秒，
/// 导航锁一直挂着，翻页全被挡住。
void main() {
  String documentFor(int generation, MangaReadingMode mode) =>
      mangaWindowDocument(
        const <MokuroImage>[
          MokuroImage(
            url: 'page.png',
            size: MokuroSize(1000, 1414),
            blocks: <MokuroBlock>[],
          ),
        ],
        const <String>['page.png'],
        mode: mode,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        currentSpread: 0,
        documentGeneration: generation,
      );

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-doc-ready-',
    );
    try {
      final File script = File('${dir.path}/verify.js')
        ..writeAsStringSync(code);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test('就绪信号把本文档的 generation 报给宿主的 onMangaDocumentReady', () async {
    await runJs('''
const assert=require('node:assert/strict');
const calls=[];
const window={
  __mangaDocumentGeneration: 42,
  flutter_inappwebview:{callHandler:(...args)=>{calls.push(args);return Promise.resolve();}},
};
$mangaDocumentReadySignalJs
assert.deepEqual(calls,[['$kMangaDocumentReadyHandler',42]]);
''');
  });

  test('桥还没注入时不抛错（交给 onLoadStop 兜底）', () async {
    await runJs('''
const window={__mangaDocumentGeneration: 3};
$mangaDocumentReadySignalJs
const window2={__mangaDocumentGeneration: 3, flutter_inappwebview:{}};
(function(window){ $mangaDocumentReadySignalJs })(window2);
''');
  });

  test('宿主注册 onMangaDocumentReady 并经同一个认领闸门收尾', () {
    final String page = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    final int handler = page.indexOf('handlerName: kMangaDocumentReadyHandler');
    expect(handler, greaterThan(0), reason: '宿主必须接住文档的就绪信号');
    expect(
      page.substring(handler, handler + 400).contains('_markWindowReady('),
      isTrue,
      reason: '就绪信号与 onLoadStop 走同一个收尾入口',
    );
    expect(
      page.contains('_windowGate.claimReady('),
      isTrue,
      reason: '两路信号必须经认领去重，不能各跑一遍收尾',
    );
  });

  for (final MangaReadingMode mode in <MangaReadingMode>[
    MangaReadingMode.spread,
    MangaReadingMode.webtoon,
  ]) {
    test('${mode.name}：信号排在 generation 与全部窗口钩子之后、不等 load 事件', () {
      final String doc = documentFor(9, mode);
      final int signal = doc.indexOf(mangaDocumentReadySignalJs);
      expect(signal, greaterThan(0), reason: '窗口文档必须带就绪信号');
      expect(
        doc.indexOf(mangaDocumentReadySignalJs, signal + 1),
        -1,
        reason: '只发一次',
      );
      // 宿主收尾要调这些钩子，它们必须在信号发出前就装好。
      for (final String hook in <String>[
        'window.__mangaDocumentGeneration=9;',
        'window.__mangaApplyTranslate = function',
        'window.__mangaScrollToSpread = function',
        'window.__mangaReplaceOcr = function',
        'window.__mangaVisiblePages = function',
      ]) {
        final int at = doc.indexOf(hook);
        expect(at, greaterThan(0), reason: '找不到 $hook');
        expect(at, lessThan(signal), reason: '$hook 必须在就绪信号之前定义');
      }
      // 信号同步跑在文档脚本末尾，不包进 load / DOMContentLoaded 监听。
      final String tail = doc.substring(signal);
      expect(tail.indexOf('</script>'), greaterThan(0));
      expect(tail.contains("addEventListener('load'"), isFalse);
    });
  }
}
