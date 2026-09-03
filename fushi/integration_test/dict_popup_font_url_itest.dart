import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_webview_media.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// BUG-1868 端到端验证：查词弹窗的导入字体改走 URL 之后，**在真 WebView2 里真的能
/// 加载**。
///
/// 为什么必须端到端验：这条改动把字体从「一定能显示的 `data:` 内联」换成了「依赖
/// 宿主资源拦截器的 URL」。失败方向不是变慢，而是**字体静默不生效**——比原来的慢
/// 更糟。而失败与否取决于一串只有真浏览器才能回答的问题：
///   ① `https://fushi.local/...` 会不会真的进 `shouldInterceptRequest`（而不是被
///      当成外网请求走 DNS）；
///   ② 插件把 `WebResourceResponse.headers` 传给 WebView2 之后，浏览器认不认；
///   ③ 弹窗文档是 `initialData` 的 **opaque origin**，与 `fushi.local` 跨源，而字体
///      是**强制 CORS 模式**的子资源——没有 `Access-Control-Allow-Origin` 就会被静默
///      拒绝。
/// 单测和静态分析一个都答不了，代码级证据（fork 里确有 AppendHeader）也只覆盖 ②。
///
/// 本测试**不启动 app**（不碰生产数据库），只挂一个 InAppWebView，用与生产同一个
/// `dictionaryFontWebResourceResponse` 供字节，素材是仓库自带的真 ttf。
///
/// 两个用例是一对，第二个是**负向对照**：去掉 ACAO 之后必须失败。没有它，第一个
/// 用例可能只是「在某个不检查 CORS 的实现上恒真」，那就成了自我欺骗的绿。
///
/// 跑法（仓库 fushi/ 下，离屏、不抢焦点、隔离 WebView2 profile）：
///   .\tool\run_windows_itest.ps1 integration_test\dict_popup_font_url_itest.dart
String _jsString(String value) => jsonEncode(value);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory fontDir;
  late File fontFile;

  setUp(() async {
    // 素材用仓库自带的真 ttf：必须是浏览器**真能解析**的字体，否则
    // document.fonts.check 即便 CORS 通过也会是 false，测不出所以然。
    final ByteData bytes =
        await rootBundle.load('assets/fonts/MaterialSymbolsRounded.ttf');
    fontDir = await Directory.systemTemp.createTemp('fushi_font_url_itest');
    // 用 p.join 而不是手拼 '/'：systemTemp 在 Windows 给的是反斜杠路径，手拼会造出
    // 混合分隔符（`...\temp\xxx/ItestFont.ttf`），而白名单两侧都按 p.canonicalize
    // 比对——第一次跑这个测试就是栽在这里，请求被白名单挡下，压根没走到 CORS。
    fontFile = File(p.join(fontDir.path, 'ItestFont.ttf'));
    await fontFile.writeAsBytes(bytes.buffer.asUint8List());
  });

  tearDown(() async {
    if (fontDir.existsSync()) {
      await fontDir.delete(recursive: true);
    }
  });

  /// 挂一个 WebView，文档用 initialData（与生产的 Windows 弹窗一样是 opaque
  /// origin），页面里声明一个引用 [kDictionaryFontUrlPrefix] 的 @font-face，
  /// 然后真去 load 它。返回 `document.fonts.check` 的结果。
  Future<({String probe, List<String> intercepted, bool served})>
      loadFontThroughInterceptor(
    WidgetTester tester, {
    required bool sendCorsHeader,
  }) async {
    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();
    final String fontUrl = dictionaryFontUrl(fontFile.path);
    final List<String> intercepted = <String>[];
    bool served = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InAppWebView(
            initialData: InAppWebViewInitialData(
              data: '<!DOCTYPE html><html><head><meta charset="utf-8">'
                  '<style>'
                  '@font-face { font-family: "ItestFont"; '
                  'src: url("$fontUrl") format("truetype"); }'
                  '</style></head>'
                  '<body><span id="probe" '
                  'style="font-family:\'ItestFont\'">e</span></body></html>',
            ),
            initialSettings: InAppWebViewSettings(
              useShouldInterceptRequest: true,
              resourceCustomSchemes: dictionaryMediaCustomSchemes,
            ),
            shouldInterceptRequest: (controller, request) async {
              intercepted.add(request.url.toString());
              final WebResourceResponse? real =
                  await dictionaryFontWebResourceResponse(
                request.url,
                allowedRoots: <String>[fontDir.path],
                // 白名单必须与拦截器内部同一套归一化（p.canonicalize），
                // 否则分隔符/大小写差异会让合法字体被自己的白名单挡下。
                whitelistedPaths: <String>{p.canonicalize(fontFile.path)},
              );
              if (real == null) return null;
              served = real.statusCode == 200;
              if (sendCorsHeader) return real;
              // 负向对照：同样的字节、同样的 200，唯独抽掉 CORS 头。
              return WebResourceResponse(
                contentType: real.contentType,
                statusCode: real.statusCode,
                reasonPhrase: real.reasonPhrase,
                data: real.data,
              );
            },
            onLoadStop: (controller, url) {
              if (!ready.isCompleted) ready.complete(controller);
            },
          ),
        ),
      ),
    );

    // WebView2 冷启动 + 导航；给足时间，别用固定 sleep 赌。
    final InAppWebViewController controller = await ready.future.timeout(
      const Duration(seconds: 60),
    );
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // evaluateJavascript **不会 await Promise**：直接 return 一个 async IIFE
    // 只会拿到序列化后的 Promise（表现为 `{}`）。这个坑让本测试头两轮跑出的
    // 「失败」全是假的——探针压根没取到值，与 CORS / 拦截器无关。
    // 所以改成两步：先把结果写进 window.__fushiFontProbe，再轮询读那个同步值。
    await controller.evaluateJavascript(
      source: '''
        window.__fushiFontProbe = 'pending';
        (async () => {
          var out = [];
          try {
            var r = await fetch(${_jsString(fontUrl)});
            out.push('fetch:' + r.status);
            var b = await r.arrayBuffer();
            out.push('bytes:' + b.byteLength);
          } catch (e) {
            out.push('fetch-threw:' + e);
          }
          try {
            await document.fonts.load('16px "ItestFont"');
            out.push('load:ok');
          } catch (e) {
            out.push('load-threw:' + e);
          }
          out.push('check:' + document.fonts.check('16px "ItestFont"'));
          out.push('status:' + document.fonts.status);
          var faces = [];
          document.fonts.forEach(function(f) {
            faces.push(f.family + '=' + f.status);
          });
          out.push('faces:' + faces.join(','));
          window.__fushiFontProbe = out.join(' | ');
        })();
      ''',
    );

    String probe = 'pending';
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final Object? v = await controller.evaluateJavascript(
        source: 'window.__fushiFontProbe',
      );
      probe = '$v';
      if (probe != 'pending' && probe.isNotEmpty) break;
    }

    return (
      probe: probe,
      intercepted: intercepted,
      served: served,
    );
  }

  testWidgets(
    'BUG-1868: 跨源 + ACAO 时，经拦截器的 URL 字体真的加载成功',
    (WidgetTester tester) async {
      final r = await loadFontThroughInterceptor(tester, sendCorsHeader: true);
      // ignore: avoid_print
      print('[BUG-1868][cors] probe=${r.probe}');
      // ignore: avoid_print
      print('[BUG-1868][cors] served=${r.served} '
          'intercepted=${r.intercepted}');
      expect(
        r.probe,
        contains('check:true'),
        reason: '字体没能经 https://fushi.local/dictfonts/ 加载。这条路一旦不通，'
            '用户的词典字体会静默失效——比原来的慢更糟，不得合入。'
            '探针：${r.probe}；拦截到的请求：${r.intercepted}',
      );
    },
  );

  testWidgets(
    'BUG-1868 负向对照：抽掉 ACAO 后必须失败（证明上面那条不是恒真）',
    (WidgetTester tester) async {
      final r = await loadFontThroughInterceptor(tester, sendCorsHeader: false);
      // ignore: avoid_print
      print('[BUG-1868][nocors] probe=${r.probe}');
      expect(
        r.probe,
        isNot(contains('check:true')),
        reason: '没有 Access-Control-Allow-Origin 也能加载，说明这个环境根本没在'
            '检查 CORS——那么正向用例的绿就不能证明生产环境也会通过，本测试失去意义。'
            '探针：${r.probe}',
      );
    },
  );
}
