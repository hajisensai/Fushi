// BUG-2041：词形变化语法说明只能有**一套**呈现。
//
// 用户原话：「到底用不用点击，点击和不点击的统一改一下吧」。此前同一段
// data-description 披两套皮——click 走 popup.html 的静态 `.overlay` 全屏卡片
// （showDescription / closeOverlay），hover 走 `.grammar-tooltip` 浮层，两套 DOM、
// 两套定位、两套关闭、两套配色字号；`.overlay` 还是顶层节点、不在 .entry 内，点它
// 正文会落到 document dismiss 分支把整个查词窗关掉。
//
// 分工（别把这条守卫当成行为测试）：
//  · 交互语义（hover 预览 / click 钉住 / toggle / 点别处收起 / zoom 折算）由
//    `tools/browser-extension/grammar-tooltip-single-surface.test.js` 真执行 popup.js
//    切片来验——那才是能抓住逻辑退化的层。
//  · 这条守卫只钉「旧那套没有复活、三镜像没漏同步」，是行为测试覆盖不到的结构面。
//
// 注意：popup.js / popup.css 的**注释里**会长期出现 `.overlay`、`showDescription`
// 这些词（讲的正是这段历史），所以判据必须遮掉注释再看，否则这条守卫永远红。
// 遮罩一律走 test/helpers/source_guard.dart 的 maskJsComments / maskCssComments：
// 手写的「找 // 和 /*」会把字符串和正则里的斜杠当成注释起点，一路吃掉真代码——
// 本守卫第一版正是这么把 dismiss 豁免那行吃没了、自己红的（也正是
// test/tools/source_guard_adoption_test.dart 明令禁止手写剥离的原因）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  const List<String> roots = <String>[
    'assets/popup',
    'assets/browser_extension/vendor',
    '../tools/browser-extension/vendor',
  ];

  String read(String root, String name) =>
      File('$root/$name').readAsStringSync();

  group('语法说明只有一套呈现（BUG-2041）', () {
    for (final String root in roots) {
      test('[$root] 旧的 .overlay 全屏卡片没有复活', () {
        final String html = read(root, 'popup.html');
        expect(
          html.contains('class="overlay"'),
          isFalse,
          reason:
              '$root/popup.html 又出现了 `.overlay` 静态节点——'
              '它是顶层元素、不在 .entry 内，点它正文会落到 document dismiss 分支'
              '把整个查词窗关掉，而且和 .grammar-tooltip 是同一段文字的两套皮',
        );
        expect(html.contains('overlay-content'), isFalse);
        expect(html.contains('overlay-title'), isFalse);

        final String js = maskJsComments(read(root, 'popup.js'));
        for (final String dead in <String>[
          'function showDescription',
          'function closeOverlay',
        ]) {
          expect(
            js.contains(dead),
            isFalse,
            reason: '$root/popup.js 又长出了 $dead（第二套呈现）',
          );
        }

        final String css = maskCssComments(read(root, 'popup.css'));
        for (final String dead in <String>[
          '.overlay-title',
          '.overlay-content',
          '.overlay-close',
        ]) {
          expect(
            css.contains(dead),
            isFalse,
            reason: '$root/popup.css 又长出了 $dead 的样式',
          );
        }
      });

      test('[$root] 唯一那套浮层的两态样式齐全', () {
        final String css = read(root, 'popup.css');
        for (final String needed in <String>[
          '.grammar-tooltip {',
          '.grammar-tooltip.is-pinned {',
          '.grammar-tooltip-body {',
          '.grammar-tooltip.is-pinned .grammar-tooltip-title {',
          '.grammar-tooltip.is-pinned .grammar-tooltip-close {',
        ]) {
          expect(
            css.contains(needed),
            isTrue,
            reason:
                '$root/popup.css 缺少浮层规则 `$needed`——'
                '钉住态少了它就退回预览态观感（不可交互 / 没有标题和关闭按钮）',
          );
        }
      });
    }

    test('钉住态在 document dismiss 分支里被豁免（否则点说明就关窗）', () {
      final String js = maskJsComments(read('assets/popup', 'popup.js'));
      expect(
        js.contains(".closest('.grammar-tooltip')"),
        isTrue,
        reason:
            '钉住态是可交互的、且挂在 __fushiOverlayParent() 顶层不在 .entry 内。'
            'popup.js 末尾的 document click dismiss 必须显式豁免它，'
            '否则点说明正文会一路落到 tapOutside 把整个查词窗关掉（旧 .overlay 的老毛病）',
      );
    });

    test('浮层不再依赖 .overlay 承担窄屏，改由 JS 现算 max-width', () {
      final String js = maskJsComments(read('assets/popup', 'popup.js'));
      expect(
        js.contains('style.maxWidth'),
        isTrue,
        reason:
            '原 `.overlay` 存在的唯一理由是「窄屏放不下浮层」。删掉它之后，'
            '窄屏自适应必须由 showGrammarTooltip 按视口现算 max-width 承担，'
            '否则窄屏上浮层会顶出视口',
      );
    });
  });
}
