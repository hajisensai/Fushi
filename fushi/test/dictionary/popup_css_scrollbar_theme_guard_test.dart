// TODO-789 → 2026-08-23 Niratan 对齐改版 static guard：查词弹窗滚动条为
// 「静止隐形、悬停/滚动浮现」的 overlay 胶囊滚动条（对齐 Niratan popup.css），
// 不再是常驻的 --text-color 实心细滚动条。
//
// 钉住的不变式：
// 1. 静止态 thumb 透明（::-webkit-scrollbar-thumb 基础规则 background-color:
//    transparent + 999px 胶囊 + 2px content-box 内缩）；
// 2. 悬停 / .popup-scroll-active（popup.js 滚动监听打的类，覆盖触屏无 hover）
//    时 thumb 才取 --popup-scrollbar-thumb 显形；
// 3. **不得**重新引入标准 scrollbar-color / 根级 scrollbar-width: thin ——
//    Chromium 121+ 一旦标准滚动条属性生效会整族禁用 ::-webkit-scrollbar
//    伪元素（BUG-753 记录的引擎行为），悬停显隐立即失效退化回常驻滚动条；
//    （.expression-scroll 的 scrollbar-width: none 是 BUG-753 的既有修复，保留）
// 4. 两个主题块定义 --popup-scrollbar-thumb 变量；
// 5. color-scheme 仍按主题钉住（WebView2 Fluent overlay 滚动条只认 UA
//    color-scheme 的兜底路径）。
// 6. popup.js 带 popup-scroll-active 滚动监听（900ms 衰减）。
//
// Layer rationale: 滚动条外观是静态资产里的纯 CSS，文件文本扫描是能落地的
// 最强守卫层。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('popup.css overlay scrollbar (Niratan 对齐 2026-08-23)', () {
    late final String css;
    late final String js;

    setUpAll(() {
      final File file = File('assets/popup/popup.css');
      expect(file.existsSync(), isTrue,
          reason: 'popup.css not found at ${file.absolute.path}');
      css = file.readAsStringSync();
      final File jsFile = File('assets/popup/popup.js');
      expect(jsFile.existsSync(), isTrue,
          reason: 'popup.js not found at ${jsFile.absolute.path}');
      js = jsFile.readAsStringSync();
    });

    test('rest-state thumb is transparent pill', () {
      final int idx = css.indexOf('::-webkit-scrollbar-thumb {');
      expect(idx, greaterThanOrEqualTo(0),
          reason: 'base scrollbar thumb rule must exist');
      final String block = css.substring(idx, css.indexOf('}', idx));
      expect(block, contains('background-color: transparent;'),
          reason: '静止态 thumb 必须透明（静止隐形是本设计的核心）');
      expect(block, contains('border-radius: 999px;'),
          reason: '胶囊形 thumb（Niratan 同参）');
      expect(block, contains('background-clip: content-box;'),
          reason: '2px 透明 border + content-box 内缩形成悬浮胶囊');
    });

    test('thumb reveals on hover and on popup-scroll-active', () {
      expect(css, contains('*:hover::-webkit-scrollbar-thumb'),
          reason: '桌面鼠标悬停显形（通用形，任一滚动容器自身悬停即显形）');
      expect(css, contains('*.popup-scroll-active::-webkit-scrollbar-thumb'),
          reason: '滚动进行中显形（触屏/键盘滚动无 hover，靠 popup.js 打类）');
      final int idx = css.indexOf('*:hover::-webkit-scrollbar-thumb');
      final String block = css.substring(idx, css.indexOf('}', idx));
      expect(block, contains('var(--popup-scrollbar-thumb'),
          reason: '显形色走主题变量，非字面量');
    });

    test('standard scrollbar props must NOT come back (Chromium 121+ 全族禁用)',
        () {
      // 声明级匹配（行首缩进 + 属性名 + 冒号），注释里提到属性名不算。
      expect(RegExp(r'^\s*scrollbar-color\s*:', multiLine: true).hasMatch(css),
          isFalse,
          reason: '标准 scrollbar-color 声明一出现，Chromium 121+ 即禁用全部 '
              '::-webkit-scrollbar 伪元素，悬停显隐失效（BUG-753 行为）');
      final Iterable<RegExpMatch> widthDecls =
          RegExp(r'^\s*scrollbar-width\s*:\s*(\S+?)\s*;', multiLine: true)
              .allMatches(css);
      for (final RegExpMatch m in widthDecls) {
        expect(m.group(1), 'none',
            reason: 'scrollbar-width 只允许 none（.expression-scroll 的 '
                'BUG-753 修复）；thin/auto 会让 Chromium 121+ 禁用 '
                '::-webkit-scrollbar 全族');
      }
    });

    test('theme blocks define the thumb variable', () {
      for (final String theme in <String>['light', 'dark']) {
        final int idx = css.indexOf('html[data-theme="$theme"] {');
        expect(idx, greaterThanOrEqualTo(0),
            reason: '$theme theme block must exist');
        final String block = css.substring(idx, css.indexOf('}', idx));
        expect(block, contains('--popup-scrollbar-thumb:'),
            reason: '$theme 主题必须定义滚动条胶囊色变量');
      }
    });

    test('light theme block pins color-scheme: light', () {
      final int lightIdx = css.indexOf('html[data-theme="light"] {');
      expect(lightIdx, greaterThanOrEqualTo(0),
          reason: 'light theme block must exist');
      final int lightBlockEnd = css.indexOf('}', lightIdx);
      final String lightBlock = css.substring(lightIdx, lightBlockEnd);
      expect(lightBlock, contains('color-scheme: light;'),
          reason:
              'WebView2 Fluent overlay scrollbar only follows color-scheme');
    });

    test('dark theme block pins color-scheme: dark', () {
      final int darkIdx = css.indexOf('html[data-theme="dark"] {');
      expect(darkIdx, greaterThanOrEqualTo(0),
          reason: 'dark theme block must exist');
      final int darkBlockEnd = css.indexOf('}', darkIdx);
      final String darkBlock = css.substring(darkIdx, darkBlockEnd);
      expect(darkBlock, contains('color-scheme: dark;'),
          reason:
              'WebView2 Fluent overlay scrollbar only follows color-scheme');
    });

    test('popup.js carries the popup-scroll-active toggler', () {
      expect(js, contains("'popup-scroll-active'"),
          reason: 'popup.js 必须有滚动监听给根节点打 .popup-scroll-active');
      expect(js, contains('900'),
          reason: '900ms 无滚动后衰减（Niratan 同参）');
    });
  });
}
