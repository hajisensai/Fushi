import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

/// BUG-2607 真 WebKit 证据探针：在真 WKWebView 里（阅读器同款
/// `isTextInteractionEnabled: false`）装入本仓真实生成的阅读器 CSS，对三段正文各注册
/// 一条 `fushi-selection` Custom Highlight，截图采样 Range 矩形内的像素：
///   a. 裸段落 —— 修复后的 iOS CSS（触屏块无 user-select:none）应画出高亮；
///   b. 同一段落手动补 `user-select:none`（= 1279 旧规则）—— WebKit 不画（对照）；
///   c. 有声书 cue span 包裹 —— 应与 a 相同（证明与有声书 DOM 无关）。
/// 采样按 `::highlight(fushi-selection)` 被探针追加规则钉成的纯色 rgb(200,210,170)。
///
/// 跑法（主 checkout runner，iOS 模拟器）：
///   .\tool\run_mac_itest.ps1 integration_test/reader_ios_highlight_user_select_probe_itest.dart -Ios
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('WebKit 只在 user-select 非 none 的文字上绘制 ::highlight', (
    WidgetTester tester,
  ) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    final String readerCss = ReaderContentStyles.css(
      settings: settings,
      contentLanguage: 'ja',
    );
    // ignore: avoid_print
    print(
      '[bug2607] readerCss coarseBlockHasUserSelect='
      '${_coarseBlock(readerCss).contains('user-select')}',
    );

    const String text = '朝の満員電車に乗るようになって二ヵ月が経つけれど';
    final String html =
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<style>$readerCss</style>'
        '<style>'
        'body{font-size:28px;line-height:1.8;padding:24px;margin:0}'
        'p{margin:0 0 12px 0}'
        '::highlight(fushi-selection){background-color:rgb(200,210,170);color:inherit}'
        '</style></head><body>'
        '<p id="a">$text</p>'
        '<p id="b" style="-webkit-user-select:none;user-select:none">$text</p>'
        '<p id="c"><span class="fushi-sentence-audio-cue">$text</span></p>'
        '</body></html>';

    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InAppWebView(
            initialData: InAppWebViewInitialData(data: html),
            initialSettings: InAppWebViewSettings(
              isTextInteractionEnabled: !isIOSPlatform,
            ),
            onLoadStop: (InAppWebViewController controller, WebUri? url) {
              if (!ready.isCompleted) ready.complete(controller);
            },
          ),
        ),
      ),
    );
    final InAppWebViewController controller = await ready.future;
    // iOS 上 onLoadStop 可能先于平台视图拿到尺寸（innerWidth 0 → 布局矩形全错），
    // 等真实视口出现再注册高亮取矩形。
    int viewportWidth = 0;
    for (int i = 0; i < 40 && viewportWidth <= 0; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final dynamic w = await controller.evaluateJavascript(
        source: 'window.innerWidth',
      );
      viewportWidth = (w is num) ? w.toInt() : 0;
    }
    expect(viewportWidth, greaterThan(0), reason: 'WebView 视口一直是 0 宽');

    final dynamic raw = await controller.evaluateJavascript(
      source: '''
(function(){
  var ids = ['a','b','c'];
  var ranges = [];
  var rects = {};
  ids.forEach(function(id){
    var el = document.getElementById(id);
    var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    var n = w.nextNode();
    var r = document.createRange(); r.setStart(n, 2); r.setEnd(n, 9);
    ranges.push(r);
    var b = r.getBoundingClientRect();
    rects[id] = {x:b.x, y:b.y, w:b.width, h:b.height};
  });
  var hl = new Highlight(...ranges); hl.priority = 1;
  CSS.highlights.set('fushi-selection', hl);
  return JSON.stringify({
    supported: !!(window.CSS && CSS.highlights && window.Highlight),
    dpr: window.devicePixelRatio, vw: window.innerWidth, vh: window.innerHeight,
    userSelectA: getComputedStyle(document.getElementById('a')).webkitUserSelect,
    userSelectB: getComputedStyle(document.getElementById('b')).webkitUserSelect,
    rects: rects
  });
})();
''',
    );
    final Map<String, dynamic> info =
        jsonDecode(raw as String) as Map<String, dynamic>;
    // ignore: avoid_print
    print('[bug2607] page $info');
    await tester.pump(const Duration(milliseconds: 500));

    final Uint8List? png = await controller.takeScreenshot();
    expect(png, isNotNull);
    final ui.Image image = await _decode(png!);
    final ByteData? rgba = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(rgba, isNotNull);
    final double scaleX = image.width / (info['vw'] as num);
    final double scaleY = image.height / (info['vh'] as num);
    // ignore: avoid_print
    print(
      '[bug2607] shot ${image.width}x${image.height} scale=$scaleX/$scaleY',
    );

    final Map<String, double> ratio = <String, double>{};
    for (final String id in <String>['a', 'b', 'c']) {
      final Map<String, dynamic> r =
          (info['rects'] as Map<String, dynamic>)[id] as Map<String, dynamic>;
      final int x0 = ((r['x'] as num) * scaleX).round() + 2;
      final int x1 = (((r['x'] as num) + (r['w'] as num)) * scaleX).round() - 2;
      final int y0 = ((r['y'] as num) * scaleY).round() + 4;
      final int y1 = (((r['y'] as num) + (r['h'] as num)) * scaleY).round() - 4;
      int hit = 0;
      int total = 0;
      for (int y = y0; y < y1; y += 2) {
        for (int x = x0; x < x1; x += 2) {
          final int k = (y * image.width + x) * 4;
          final int red = rgba!.getUint8(k);
          final int green = rgba.getUint8(k + 1);
          final int blue = rgba.getUint8(k + 2);
          total++;
          if ((red - 200).abs() < 12 &&
              (green - 210).abs() < 12 &&
              (blue - 170).abs() < 12) {
            hit++;
          }
        }
      }
      ratio[id] = total == 0 ? 0 : hit / total;
    }
    // ignore: avoid_print
    print('[bug2607] RESULT highlightPixelRatio=$ratio');

    expect(info['supported'], isTrue, reason: 'CSS Custom Highlight 不可用');
    expect(
      ratio['a'],
      greaterThan(0.2),
      reason: '修复后的 iOS 阅读器 CSS 下裸段落必须画出 ::highlight',
    );
    expect(
      ratio['c'],
      greaterThan(0.2),
      reason: '有声书 cue span 内的文字同样必须画出 ::highlight',
    );
    expect(
      ratio['b'],
      lessThan(0.02),
      reason: '对照：user-select:none 的文字 WebKit 不画 ::highlight（根因）',
    );
  });
}

String _coarseBlock(String css) {
  final int start = css.indexOf('@media (pointer: coarse)');
  if (start < 0) return '';
  final int end = css.indexOf('\n}\n', start);
  return end < 0 ? css.substring(start) : css.substring(start, end + 3);
}

Future<ui.Image> _decode(Uint8List bytes) {
  final Completer<ui.Image> c = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, c.complete);
  return c.future;
}
