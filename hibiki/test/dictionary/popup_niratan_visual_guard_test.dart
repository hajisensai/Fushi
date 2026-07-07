// TODO-1325 phase1 静态守卫：借鉴同源 Niratan 的三项视觉升级中的弹窗侧两项——
//   #1 音高来源彩色药丸（popup.css）
//   #4 顶部动作按钮改内联 Material Symbols SVG 图标（popup.js + popup.css + popup.html）
// 弹窗跑在 WebView 里没有 headless 渲染，故用源码文本扫描锁住这些约束，防回退。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 抽取第一个 `<selector> { ... }` 规则块的内容（单层花括号，popup 这些规则无嵌套）。
String _ruleBody(String css, String selector) {
  final int start = css.indexOf('$selector {');
  expect(start, greaterThanOrEqualTo(0), reason: 'rule "$selector" not found');
  final int open = css.indexOf('{', start);
  final int close = css.indexOf('}', open);
  expect(close, greaterThan(open), reason: 'rule "$selector" not closed');
  return css.substring(open + 1, close);
}

void main() {
  // flutter test 的 cwd 是 hibiki 包根。
  late final String css;
  late final String js;
  late final String html;

  setUpAll(() {
    css = File('assets/popup/popup.css').readAsStringSync();
    js = File('assets/popup/popup.js').readAsStringSync();
    html = File('assets/popup/popup.html').readAsStringSync();
  });

  group('#1 音高来源彩色药丸', () {
    test('.pitch-dict-label 不再 display:none，而是可见的填充药丸', () {
      final String body = _ruleBody(css, '.pitch-dict-label');
      // 关键：出处必须可见（回归就是有人把它改回 display:none）。
      expect(body.contains('display: none'), isFalse,
          reason: '.pitch-dict-label 必须可见，让用户看到音高出处词典名');
      expect(body, contains('display: inline-block'),
          reason: '药丸走 inline-block 行内展示');
      // 填充 + 圆角 = 药丸观感。
      expect(body, contains('background-color'), reason: '药丸要有填充背景色');
      expect(RegExp(r'border-radius:\s*999px').hasMatch(body), isTrue,
          reason: '满圆 pill 圆角');
    });

    test('药丸配色接 MD3 --md-* 变量（不写死 Niratan 的 #94a6eb）', () {
      final String body = _ruleBody(css, '.pitch-dict-label');
      expect(body, contains('var(--md-primary'),
          reason: '填充色接注入的 --md-primary 动态取色');
      expect(body, contains('var(--md-on-primary'),
          reason: '文字色接配对的 --md-on-primary，浅色白字 / 深色深字，两主题对比达标');
      expect(body.contains('#94a6eb'), isFalse,
          reason: '禁止照抄 Niratan 的硬编码颜色');
    });

    test('Dart 侧两个注入点都注入了 --md-on-primary（药丸文字色的真值来源）', () {
      for (final String path in <String>[
        'lib/src/pages/implementations/popup_settings_injection.dart',
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(src, contains("'--md-on-primary'"),
            reason: '$path 应注入 --md-on-primary');
        expect(src, contains('scheme.onPrimary'),
            reason: '$path 的 on-primary 取自 ColorScheme.onPrimary');
      }
    });
  });

  group('#4 动作按钮内联 SVG 图标', () {
    test('popup.js 定义了 Material Symbols 图标路径与 setButtonIcon 助手', () {
      expect(js, contains('const ICON_PATHS'), reason: '内联 SVG 图标路径表');
      expect(js, contains('function iconSvg('), reason: 'iconSvg 生成 <svg> 标记');
      expect(js, contains('function setButtonIcon('),
          reason: 'setButtonIcon 记 data-icon 并换 innerHTML');
      // 图标必须是矢量 SVG（fill:currentColor 随主题），不是 macOS-only 的 mask 分支。
      expect(js, contains('<svg'), reason: '用内联 SVG 矢量图标');
      expect(js, contains('fill="currentColor"'),
          reason: 'SVG 用 currentColor 跟随按钮颜色/主题（而非 SF-symbol 的 -webkit-mask macOS-only 分支）');
    });

    test('五类动作按钮全部挂 inline-action-button 共享基类（不只换一半）', () {
      // audio / favorite / mine 三顶部按钮 + Hibiki 独有的 clear-draft / 句子上下文步进器。
      for (final String cls in <String>[
        'inline-action-button audio-button',
        'inline-action-button favorite-button',
        'inline-action-button mine-button',
        'inline-action-button clear-draft-button',
        'inline-action-button context-stepper-btn',
      ]) {
        expect(js, contains(cls), reason: '按钮 "$cls" 必须挂共享基类');
      }
    });

    test('按钮状态切换走图标名而非文字字形（audio/favorite/mine 三态齐全）', () {
      // 不再是文字字形；用具名图标切换。
      for (final String icon in <String>[
        "setButtonIcon(button, 'audio')",
        "setButtonIcon(button, nowFav ? 'favorited' : 'favorite')",
        "setButtonIcon(mineButton, isMined ? (latest ? 'restore' : 'check') : 'add')",
      ]) {
        expect(js, contains(icon), reason: '状态切换应设图标 "$icon"');
      }
      // 旧文字字形的按钮内容赋值不应残留。
      expect(js.contains("textContent: '♪'"), isFalse);
      expect(js.contains("textContent: '☆'"), isFalse);
      expect(js.contains('mineButton.textContent = '), isFalse);
    });

    test('.inline-action-button 有 hover / active / disabled 三态与 SVG 尺寸规则', () {
      expect(css, contains('.inline-action-button {'), reason: '共享基类规则');
      expect(css, contains('.inline-action-button:hover'), reason: 'hover 态');
      expect(css, contains('.inline-action-button:active'), reason: 'active 态');
      expect(css, contains('.inline-action-button:disabled'),
          reason: 'disabled 态');
      // SVG 随按钮 font-size 自适应。
      final String svgBody = _ruleBody(css, '.inline-action-button > svg');
      expect(svgBody, contains('width: 1em'));
      expect(svgBody, contains('height: 1em'));
    });

    test('标签说明遮罩的关闭按钮也换成内联 SVG（关闭图标一并统一）', () {
      expect(html, contains('class="overlay-close"'), reason: 'overlay-close 结构保留');
      expect(RegExp(r'overlay-close"[^>]*>\s*<svg').hasMatch(html), isTrue,
          reason: 'overlay-close 用内联 SVG 而非 × 文字字形');
    });
  });

  group('未破坏 Hibiki 既有弹窗资产（回归护栏）', () {
    test('header-buttons 仍是单一来源的响应式 clamp gap（TODO-846 不回退）', () {
      final String body = _ruleBody(css, '.header-buttons');
      expect(RegExp(r'gap\s*:\s*clamp\(').hasMatch(body), isTrue,
          reason: '顶部按钮间距仍走 .header-buttons 的 clamp gap');
    });

    test('.mine-button / .sentence-context-picker 仍不自带 margin-left', () {
      expect(RegExp(r'\.mine-button\s*\{[^}]*margin-left').hasMatch(css), isFalse,
          reason: '.mine-button 不得自带 margin-left（间距走 gap）');
      expect(
          RegExp(r'\.sentence-context-picker\s*\{[^}]*margin-left').hasMatch(css),
          isFalse,
          reason: '.sentence-context-picker 不得自带 margin-left');
    });

    test('音高发音区仍 user-select:none（TODO-1305 不回退）', () {
      final String body = _ruleBody(css, '.pitch-group');
      expect(body, contains('user-select: none;'));
      expect(body, contains('-webkit-user-select: none;'));
    });

    test('卡片圆角仍走 --hibiki-radius-card token（未被本次改动破坏）', () {
      expect(css, contains('var(--hibiki-radius-card'),
          reason: '弹窗卡片表面仍引用注入的圆角 token');
    });
  });
}
