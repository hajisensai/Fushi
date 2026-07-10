// spec 2026-07-10 — 剪贴板面板（host 面板模式 + 半透明变量 + 句子条可点）的
// 源码接线守卫。行为级断言在 node harness（global_lookup_host_test.mjs P1-P3）；
// 这里锁跨文件契约：变量名 / payload 键 / CSS 默认值——任何一端单方面改名都会
// 让面板静默失效，故三端（Dart render / host JS / popup.css）互相钉死。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String hostJs =
      File('assets/popup/global_lookup_host.js').readAsStringSync();
  final String popupJs = File('assets/popup/popup.js').readAsStringSync();
  final String popupCss = File('assets/popup/popup.css').readAsStringSync();
  final String renderDart =
      File('lib/src/lookup/global_lookup_render.dart').readAsStringSync();
  final String injectionDart =
      File('lib/src/pages/implementations/popup_settings_injection.dart')
          .readAsStringSync();

  group('host 面板模式（layoutMode 契约）', () {
    test('render 侧仅 panel 模式携带 layoutMode 键（cascade 载荷字节不变）', () {
      expect(renderDart.contains("if (layoutMode == 'panel')"), isTrue);
      expect(renderDart.contains("payloadObj['layoutMode'] = 'panel'"), isTrue);
    });

    test('host 读 payload.layoutMode 且面板短路 measureAndReport', () {
      expect(hostJs.contains('payload.layoutMode'), isTrue);
      expect(hostJs.contains("layoutMode === 'panel'"), isTrue);
      expect(hostJs.contains('ensurePanelBar'), isTrue);
    });

    test('面板点空白不关（onHostPointerDown 面板早退）', () {
      final int fn = hostJs.indexOf('function onHostPointerDown');
      expect(fn, isNonNegative);
      final String body =
          hostJs.substring(fn, hostJs.indexOf('function handleGlobalClick'));
      expect(body.contains("layoutMode === 'panel'"), isTrue,
          reason: '常驻语义：面板内点空白永不 dismissRootWithSlide');
    });
  });

  group('半透明卡背景（--hibiki-card-bg-* 三端契约）', () {
    test('注入端产出 rgb 三元组变量', () {
      expect(injectionDart.contains('--hibiki-card-bg-rgb'), isTrue);
      expect(injectionDart.contains('_cssRgbTriplet'), isTrue);
    });

    test('render 端恒注入 alpha 变量（1.0 也写——防调回 100% 后旧值残留）', () {
      expect(renderDart.contains('--hibiki-card-bg-alpha'), isTrue);
      expect(renderDart.contains('cardBgAlpha.toStringAsFixed(2)'), isTrue);
      expect(renderDart.contains('cardBgAlpha < 1.0'), isFalse,
          reason: '条件注入会让常驻面板从 0.85 调回 1.0 后停在半透明（审查 #4）');
    });

    test('popup.css 卡背景消费两变量且默认 alpha=1（零回归）', () {
      expect(popupCss.contains('var(--hibiki-card-bg-rgb'), isTrue);
      expect(popupCss.contains('var(--hibiki-card-bg-alpha, 1)'), isTrue);
    });
  });

  group('句子横幅逐字可点', () {
    test('popup.js 逐字 span + 后缀 onLinkClick', () {
      final int fn =
          popupJs.indexOf('function buildGlobalLookupSentenceBanner');
      expect(fn, isNonNegative);
      final String body = popupJs.substring(
          fn, popupJs.indexOf('function prependSentenceBanner'));
      expect(body.contains('global-lookup-sentence-char'), isTrue);
      expect(body.contains('chars.slice(i).join('), isTrue,
          reason: '点字=该字到句尾后缀查词（同 in-app 剪贴板面板语义）');
      expect(body.contains('callHandler(') && body.contains("'onLinkClick'"),
          isTrue,
          reason: '复用现有 onLinkClick 桥（host 重锚定 + 嵌套子卡）');
    });

    test('popup.css 有逐字 hover 样式', () {
      expect(popupCss.contains('.global-lookup-sentence-char'), isTrue);
    });
  });
}
