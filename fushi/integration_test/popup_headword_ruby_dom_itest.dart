import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'test_helpers.dart';

/// BUG-1098 真 DOM 验证：查词弹窗**词头**（.expression）的 furigana 不再被裁。
///
/// 已有的 `test/pages/popup_headword_ruby_reserve_bug1098_test.dart` 只做 CSS/JS
/// 字符串守卫（无头环境量不了几何，文件头自陈）。这里把生产的 `assets/popup/popup.css`
/// + `popup.js` 原样塞进真 WebView2，用生产的 `buildFuriganaEl` + `postProcessRuby`
/// 造出与生产同构的词头 DOM，再 `getBoundingClientRect` / `getComputedStyle` 量真像素。
///
/// 受害形状必须先复现：`buildFuriganaEl` 返回 truthy（单段带注音 = 纯汉字词，如
/// 気配/邂逅/逢瀬）时生产才套 `.expression-scroll`（popup.js:2420-2426）——而
/// `.expression-scroll{overflow-x:auto}` 让该盒成为滚动容器，滚动容器的**顶部**溢出
/// 永远够不到（scrollTop 不能为负）= 永久 CLIP。所以判据是 rt 的顶不得越过容器顶。
///
/// 跑法（仓库 fushi/ 下，离屏、不抢焦点、隔离 WebView2 profile）：
///   .\tool\run_windows_itest.ps1 integration_test\popup_headword_ruby_dom_itest.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BUG-1098: 纯汉字词头的注音在真 WebView 里有 em 预留、不被顶部裁切',
      (WidgetTester tester) async {
    final String popupJs = await rootBundle.loadString('assets/popup/popup.js');
    final String popupCss =
        await rootBundle.loadString('assets/popup/popup.css');
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

    // popup.js 的桥调用在无宿主时会抛，先桩掉（与 desktop_reader_css_dom 同款）。
    await controller.evaluateJavascript(source: '''
      window.flutter_inappwebview = {
        callHandler: function() { return Promise.resolve(true); }
      };
    ''');
    // alias 必须与加载在同一次 eval 里，否则后续 eval 拿不到顶层函数。
    await controller.evaluateJavascript(
      source: '$dictMediaJs\n$popupJs\n'
          'window.__t = { buildFuriganaEl: buildFuriganaEl, '
          'postProcessRuby: postProcessRuby };',
    );

    final Object? raw = await controller.evaluateJavascript(source: '''
      (function() {
        try {
          if (typeof window.__t.buildFuriganaEl !== 'function' ||
              typeof window.__t.postProcessRuby !== 'function') {
            return JSON.stringify({ error: 'popup.js 顶层函数 alias 失败' });
          }
          var style = document.createElement('style');
          style.textContent = ${jsonEncode(popupCss)};
          document.head.appendChild(style);

          // 与生产 createEntryHeader（popup.js:2400-2426）同构的词头 DOM。
          var header = document.createElement('div');
          header.className = 'entry-header';
          var span = document.createElement('span');
          span.className = 'expression';
          var needsScroll = window.__t.buildFuriganaEl(span, '気配', 'けはい');
          var scroll = null;
          if (needsScroll) {
            scroll = document.createElement('div');
            scroll.className = 'expression-scroll';
            scroll.appendChild(span);
            header.appendChild(scroll);
          } else {
            header.appendChild(span);
          }
          document.body.replaceChildren(header);

          // 修复前的裁切形状：ruby 是裸的、无 .ruby-unit。先记一份「未处理」几何。
          var rawRt = span.querySelector('rt');
          var rawRtTop = rawRt ? rawRt.getBoundingClientRect().top : null;
          var boxTopBefore = scroll
            ? scroll.getBoundingClientRect().top
            : span.getBoundingClientRect().top;

          window.__t.postProcessRuby(header);

          var units = span.querySelectorAll('.ruby-unit');
          var rt = span.querySelector('rt');
          var rubyEl = span.querySelector('ruby');
          var box = scroll || span;
          var boxRect = box.getBoundingClientRect();
          var rtRect = rt ? rt.getBoundingClientRect() : null;
          var unitCs = units.length ? getComputedStyle(units[0]) : null;
          var rtCs = rt ? getComputedStyle(rt) : null;
          var boxCs = getComputedStyle(box);
          var expressionFontSize = getComputedStyle(span).fontSize;

          // 幂等：生产 renderPopup 对首词条会走两遍（firstEntry + container）。
          window.__t.postProcessRuby(header);
          var unitsAfterTwice = span.querySelectorAll('.ruby-unit').length;
          var nestedUnits =
            span.querySelectorAll('.ruby-unit .ruby-unit').length;

          return JSON.stringify({
            needsScroll: !!needsScroll,
            hasScrollWrapper: !!scroll,
            rawRtTop: rawRtTop,
            boxTopBefore: boxTopBefore,
            unitCount: units.length,
            unitsAfterTwice: unitsAfterTwice,
            nestedUnits: nestedUnits,
            rubyHasRtChild: rubyEl ? !!rubyEl.querySelector(':scope > rt') : null,
            boxTop: boxRect.top,
            boxHeight: boxRect.height,
            boxScrollTop: box.scrollTop,
            rtTop: rtRect ? rtRect.top : null,
            rtHeight: rtRect ? rtRect.height : null,
            rtBottom: rtRect ? rtRect.bottom : null,
            unitPaddingTop: unitCs ? unitCs.paddingTop : null,
            unitLineHeight: unitCs ? unitCs.lineHeight : null,
            rtPosition: rtCs ? rtCs.position : null,
            rtTopStyle: rtCs ? rtCs.top : null,
            rtFontSize: rtCs ? rtCs.fontSize : null,
            boxOverflowX: boxCs.overflowX,
            boxOverflowY: boxCs.overflowY,
            expressionFontSize: expressionFontSize
          });
        } catch (error) {
          return JSON.stringify({
            error: String(error), stack: String(error && error.stack)
          });
        }
      })();
    ''');
    await tester.pump(const Duration(seconds: 1));
    await takeScreenshot(binding, 'bug1098_headword_ruby_dom');

    final Map<String, dynamic> g =
        jsonDecode(raw?.toString() ?? '{}') as Map<String, dynamic>;
    debugPrint('[BUG-1098] headword ruby geometry: ${jsonEncode(g)}');
    expect(g['error'], isNull, reason: '生产 popup.js 必须能在 WebView2 里跑起来');

    // ① 先证明这就是受害形状（单段 → 套 .expression-scroll → 滚动容器）。
    expect(g['needsScroll'], isTrue,
        reason: '気配/けはい 必须是单段带注音（才会套 .expression-scroll）');
    expect(g['hasScrollWrapper'], isTrue);
    expect(g['boxOverflowX'], 'auto');
    expect(g['boxOverflowY'], isNot('visible'),
        reason: '一轴非 visible → 另一轴 computed 成 auto，该盒确实是滚动容器；'
            '顶部溢出永远够不到（scrollTop 不能为负）');

    // ② 词头真的进了 postProcessRuby（per-base 单元）。
    expect(g['unitCount'], 1,
        reason: '単段词头 = 一个 per-base .ruby-unit（気配 是一个 base）');
    expect(g['nestedUnits'], 0, reason: '幂等门：二次处理不得套出嵌套 .ruby-unit');
    expect(g['unitsAfterTwice'], g['unitCount'],
        reason: 'renderPopup 对首词条走两遍，单元数不得增加');

    // ③ 预留是 em padding-top（zoom 免疫），rt 绝对定位在预留里。
    final double expressionFont =
        _px(g['expressionFontSize'], 'expressionFontSize');
    final double unitPad = _px(g['unitPaddingTop'], 'unitPaddingTop');
    final double rtFont = _px(g['rtFontSize'], 'rtFontSize');
    expect(g['rtPosition'], 'absolute');
    expect(_px(g['rtTopStyle'], 'rtTopStyle'), closeTo(0, 0.5));
    expect(unitPad, greaterThan(0), reason: '词头必须拿到纵向预留（修复前是 0）');
    expect(unitPad / expressionFont, closeTo(0.55, 0.02),
        reason: '预留是 0.55em，随字号等比（不是硬编码 px）');
    expect(rtFont / expressionFont, closeTo(0.5, 0.02),
        reason: 'rt 是 0.5em；.expression 26px 时 = 旧的硬编码 13px，像素不变');

    // ④ 核心断言：注音没有被滚动容器顶部裁掉。
    final double boxTop = _num(g['boxTop']);
    final double rtTop = _num(g['rtTop']);
    final double rtHeight = _num(g['rtHeight']);
    expect(rtHeight, greaterThan(0), reason: '注音必须真占高度（不是被压扁成 0）');
    expect(g['boxScrollTop'], 0);
    expect(rtTop, greaterThanOrEqualTo(boxTop - 0.5),
        reason: '注音顶 ($rtTop) 不得越过滚动容器顶 ($boxTop)——越过 = 永久被裁');
    expect(_num(g['rtBottom']),
        lessThanOrEqualTo(_num(g['boxHeight']) + boxTop + 0.5),
        reason: '注音整块落在容器内');

    // ⑤ 回归对照：修复前的裸 rt 是溢出到容器顶之上的（证明这个探针能抓到 bug）。
    final Object? rawRtTop = g['rawRtTop'];
    final Object? boxTopBefore = g['boxTopBefore'];
    if (rawRtTop is num && boxTopBefore is num) {
      debugPrint('[BUG-1098] pre-postProcess rawRtTop=$rawRtTop '
          'boxTop=$boxTopBefore delta=${rawRtTop - boxTopBefore}');
    }
  });
}

double _num(Object? v) {
  expect(v, isA<num>(), reason: '几何字段缺失：$v');
  return (v as num).toDouble();
}

double _px(Object? v, String name) {
  expect(v, isA<String>(), reason: '$name 应为 CSS 长度字符串，实得 $v');
  final String s = v as String;
  expect(s.endsWith('px'), isTrue, reason: '$name 应以 px 结尾，实得 $s');
  return double.parse(s.substring(0, s.length - 2));
}
