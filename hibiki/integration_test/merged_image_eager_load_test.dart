import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// TODO-1339 端到端（live WebView）：图片合并把「前导单图片 run」折进后随文本章后，
/// 注入的插图（`.hoshi-merged-image` 内）必须保持 **eager**，不能被 `_sharedInitImages`
/// 挂 `loading="lazy"`。否则离屏（离首个文本落点较远的**第一张**）永不进入懒加载视口
/// margin → 永不 load → 保持 0 尺寸 → 被 buildPaginationMetrics 的 firstContentEdge 排除
/// → 章首落点锚到最近的已加载图（**最后一张**），跳过第一张 =「两张连续图只有最后一张
/// 合并进章节」（用户报告的原始症状）。本用例在真实 WebView 引擎里跑 **真实**
/// `_sharedInitImages` 脚本，断言：
///   1. 两张合并注入的前导插图 loading 都不是 lazy（eager）。
///   2. 普通正文大图仍是 lazy（不回退 TODO-1074 懒加载）。
///   3. gaiji 内联小图仍是 eager（既有行为不变）。
///
/// Run (PowerShell, from hibiki/)：
///   $env:HIBIKI_TEST_HIDDEN = "1"
///   flutter test integration_test/merged_image_eager_load_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 1x1 透明 PNG data URI —— 无需网络、无需资源拦截即可 load。
  const String tinyPng =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

  // 复刻 webview.part.dart _injectMergedChapterImages 的注入形状：每张合并前导图是
  // `<div class="hoshi-merged-image"><img class="block-img"></div>`，插在正文最前。
  const String html = '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body>'
      '<div class="hoshi-merged-image"><img id="lead1" class="block-img" src="$tinyPng"/></div>'
      '<div class="hoshi-merged-image"><img id="lead2" class="block-img" src="$tinyPng"/></div>'
      '<p id="txt">本文のテスト文字列</p>'
      '<img id="normal" class="block-img" src="$tinyPng"/>'
      '<img id="gaijiimg" class="gaiji" src="$tinyPng"/>'
      '</body></html>';

  testWidgets(
      'merge-injected leading illustrations stay eager; normal images stay lazy',
      (WidgetTester tester) async {
    final Completer<void> driven = Completer<void>();
    String? lead1Loading;
    String? lead2Loading;
    String? normalLoading;
    String? gaijiLoading;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(data: html),
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            // 跑真实产品脚本（_sharedInitImages 的公开测试壳）。
            await controller.evaluateJavascript(
                source: ReaderPaginationScripts.initImagesScriptForTesting());
            Future<String?> loadingOf(String id) async {
              final Object? v = await controller.evaluateJavascript(source: '''
                (function(){
                  var el = document.getElementById('$id');
                  if (!el) return 'MISSING';
                  var l = el.getAttribute('loading');
                  return l === null ? 'eager' : l;
                })();
              ''');
              return v?.toString();
            }

            lead1Loading = await loadingOf('lead1');
            lead2Loading = await loadingOf('lead2');
            normalLoading = await loadingOf('normal');
            gaijiLoading = await loadingOf('gaijiimg');
            if (!driven.isCompleted) driven.complete();
          },
        ),
      ),
    ));

    for (int i = 0; i < 150 && !driven.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(driven.isCompleted, isTrue,
        reason: 'WebView did not load + run init within 15s');

    debugPrint('[merge-eager] lead1=$lead1Loading lead2=$lead2Loading '
        'normal=$normalLoading gaiji=$gaijiLoading');

    // 核心修复：两张合并前导图都必须 eager（不是 lazy），否则第一张会被章首锚跳过。
    expect(lead1Loading, isNot('lazy'),
        reason: '第一张合并前导插图必须 eager，否则离屏永不 load → 被 firstContentEdge 跳过');
    expect(lead2Loading, isNot('lazy'), reason: '第二张合并前导插图必须 eager');
    // 不回退 TODO-1074：普通正文大图仍懒加载。
    expect(normalLoading, 'lazy', reason: '普通正文图仍须 lazy（保留 TODO-1074 懒加载优化）');
    // 既有行为：gaiji 内联图 eager（参与文字几何）。
    expect(gaijiLoading, isNot('lazy'), reason: 'gaiji 内联图仍 eager');
  });
}
