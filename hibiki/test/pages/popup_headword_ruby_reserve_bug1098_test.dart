// BUG-1098 — 查词弹窗**词头**的假名（furigana / <rt>）被垂直压扁、裁掉一截。
//
// 两条并列根因，缺一不成立：
//  ① 零垂直预留：popup.css 里词头只有 `.expression rt { font-size: 13px }`，既没有
//     line-height / padding-top 预留，也不走 popup.js 的 postProcessRuby——后者当年
//     只扫 `.glossary-content ruby`，而词头 ruby 是 buildFuriganaEl 造的**裸**
//     <ruby>/<rt>（不带 class）。于是读音直接溢出 header 行盒。
//  ② 溢出不可达：`.expression-scroll { overflow-x: auto }` 让另一轴 computed 成
//     auto，该盒变成滚动容器；而滚动容器的**顶部**溢出永远够不到（scrollTop 不能为
//     负），所以溢出的注音是被永久 CLIP 掉，不是「可以滚过去」。BUG-775 当年写的
//     「保留 overflow-y:auto，注音溢出几像素仍可滚不裁切」这句结论是错的。
//
// 只有部分词被削：buildFuriganaEl 只在**整词一段**时要 .expression-scroll 包装
// （纯汉字词 気配 / 邂逅 / 逢瀬），正是 galgame 高频查的名词；食べる 这类切两段的
// 不套 wrapper，所以不裁。
//
// 修法不引入新机制：词头 ruby 并入 glossary 那套已验证的 per-base 单元
//（BUG-108/363/722/850：.ruby-unit 的 em padding-top 纵向预留 + 绝对定位 rt +
// .ruby-reserve 横向零高孪生），postProcessRuby 一并处理 `.expression ruby`。
// .expression 是 26px，旧的硬编码 13px 恰好等于共享的 0.5em——像素不变，但从此随
// 弹窗 content zoom 等比缩放，而不是让溢出量随 zoom 线性放大。
//
// ruby 几何在无头环境渲染不出来，故守卫的是规则本身的存在与作用域（与既有
// popup_glossary_ruby_lineheight_guard_test.dart 同法，那份只覆盖释义体）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();
  final String js = File('assets/popup/popup.js').readAsStringSync();

  /// 取 `:where(...) <名字> { ... }` 规则体；作用域必须同时含三个面。
  String? sharedRubyRuleBody(String css, String name) {
    final RegExp re = RegExp(
      r':where\(([^)]*)\)\s*' + RegExp.escape(name) + r'\s*\{([^}]*)\}',
    );
    for (final RegExpMatch m in re.allMatches(css)) {
      final String scope = m.group(1)!;
      if (scope.contains('glossary-group') &&
          scope.contains('glossary-content') &&
          scope.contains('.expression')) {
        return m.group(2);
      }
    }
    return null;
  }

  group('词头 furigana 的纵向预留（根因 ①）', () {
    test('.ruby-unit / rt / ruby / .ruby-reserve 的作用域都覆盖 .expression', () {
      for (final String name in const <String>[
        'ruby',
        '.ruby-unit',
        'rt',
        '.ruby-reserve',
      ]) {
        expect(sharedRubyRuleBody(css, name), isNotNull,
            reason: 'popup.css 的 `$name` 规则必须把 .expression 一并纳入作用域，'
                '否则词头 ruby 又回到「零预留」状态（BUG-1098）');
      }
    });

    test('词头继承到的预留是 em padding-top（zoom 免疫），不是行盒 leading', () {
      final String body = sharedRubyRuleBody(css, '.ruby-unit')!;
      expect(RegExp(r'padding-top\s*:\s*[\d.]+em').hasMatch(body), isTrue,
          reason: '预留必须内生于单元且以 em 表达，才能随 popupContentZoom 等比缩放');
      expect(RegExp(r'line-height\s*:\s*1\b').hasMatch(body), isTrue,
          reason: 'line-height:1 保证纵向空间只来自 em padding-top');
    });

    test('rt 绝对定位在预留里（top:0），字号是 em 不是硬编码 px', () {
      final String body = sharedRubyRuleBody(css, 'rt')!;
      expect(RegExp(r'position\s*:\s*absolute').hasMatch(body), isTrue);
      expect(RegExp(r'top\s*:\s*0\b').hasMatch(body), isTrue);
      expect(RegExp(r'font-size\s*:\s*[\d.]+em').hasMatch(body), isTrue);
    });

    test('.expression rt 不得再声明 px 字号（会盖掉零特异性的共享规则）', () {
      // `.expression rt` 特异性 (0,1,1) 高于 `:where(...) rt` 的 (0,0,1)，
      // 任何在这里写死的 px 字号都会重新把注音钉成绝对像素、脱离 zoom 链。
      final RegExpMatch? m =
          RegExp(r'(?<!\S)\.expression\s+rt\s*\{([^}]*)\}').firstMatch(css);
      expect(m, isNotNull, reason: '词头 rt 仍需要一条规则承载 user-select:none');
      final String body = m!.group(1)!;
      expect(RegExp(r'font-size\s*:\s*\d').hasMatch(body), isFalse,
          reason: '词头 rt 的字号必须来自共享的 `font-size: 0.5em`（BUG-1098）');
      expect(body.contains('-webkit-user-select: none'), isTrue,
          reason: '词头是点击目标（onLinkClick），其读音不得被拖选');
    });
  });

  group('postProcessRuby 也处理词头（根因 ① 的 JS 半边）', () {
    test('选择器包含 .expression ruby', () {
      expect(
        js.contains(
            "querySelectorAll('.glossary-content ruby, .expression ruby')"),
        isTrue,
        reason: '词头 ruby 是裸 <ruby>/<rt>，不进 postProcessRuby 就拿不到 .ruby-unit '
            '预留（BUG-1098）',
      );
    });

    test('对已包好的 base 幂等（renderPopup 会对首词条走两遍）', () {
      // renderPopup 先 postProcessRuby(firstEntry)，随后又 postProcessRuby(container)，
      // 而 container 含 firstEntry。没有这道门就会把 .ruby-unit 再包一层 .ruby-unit，
      // 叠出第二份 padding-top。
      final int at = js.indexOf('function postProcessRuby(');
      expect(at, greaterThan(0));
      final int end = js.indexOf('\nfunction ', at + 1);
      final String body = js.substring(at, end);
      expect(body.contains("classList.contains('ruby-unit')"), isTrue,
          reason: 'postProcessRuby 必须跳过已经包好的 base，保证幂等');
    });
  });

  group('三镜像 + 生成物同步（红线：popup.css/js 一改必须三处齐）', () {
    const List<String> mirrors = <String>[
      'assets/browser_extension/vendor',
      '../tools/browser-extension/vendor',
    ];

    test('两份扩展 vendor 的 popup.css / popup.js 与 app 侧字节一致', () {
      for (final String dir in mirrors) {
        expect(File('$dir/popup.css').readAsBytesSync(),
            File('assets/popup/popup.css').readAsBytesSync(),
            reason: '$dir/popup.css 未同步');
        expect(File('$dir/popup.js').readAsBytesSync(),
            File('assets/popup/popup.js').readAsBytesSync(),
            reason: '$dir/popup.js 未同步');
      }
    });

    test('两份 content.css 已重新生成，带上 .expression 作用域', () {
      // 既有的 parity 守卫只收集以 `.` 开头的选择器，`:where(...)` 规则漏在外面，
      // 所以这里显式核对生成物真的跟着 popup.css 走了一遍生成器。
      for (final String dir in mirrors) {
        final String content = File('$dir/content.css').readAsStringSync();
        for (final String name in const <String>[
          'ruby',
          '.ruby-unit',
          'rt',
          '.ruby-reserve',
        ]) {
          expect(sharedRubyRuleBody(content, name), isNotNull,
              reason: '$dir/content.css 缺 `$name` 的 .expression 作用域 — '
                  '改完 popup.css 必须重跑 '
                  'tools/browser-extension/scripts/generate-content-css.mjs');
        }
      }
    });
  });
}
