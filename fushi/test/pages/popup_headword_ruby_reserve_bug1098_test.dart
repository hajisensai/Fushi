// BUG-1098 — 查词弹窗**词头**的假名（furigana / <rt>）被垂直压扁、裁掉一截。
//
// 两条并列根因，缺一不成立：
//  ① 零垂直预留：popup.css 里词头只有 `.expression rt { font-size: 13px }`，既没有
//     line-height / padding-top 预留，也没有任何别的纵向空间来源。于是读音直接溢出
//     header 行盒。
//  ② 溢出不可达：`.expression-scroll { overflow-x: auto }` 让另一轴 computed 成
//     auto，该盒变成滚动容器；而滚动容器的**顶部**溢出永远够不到（scrollTop 不能为
//     负），所以溢出的注音是被永久 CLIP 掉，不是「可以滚过去」。BUG-775 当年写的
//     「保留 overflow-y:auto，注音溢出几像素仍可滚不裁切」这句结论是错的。
//
// 只有部分词被削：buildFuriganaEl 只在**整词一段**时要 .expression-scroll 包装
// （纯汉字词 気配 / 邂逅 / 逢瀬），正是 galgame 高频查的名词；食べる 这类切两段的
// 不套 wrapper，所以不裁。
//
// BUG-1098 当年的修法是把词头并进 glossary 那套 per-base 单元（.ruby-unit 的 em
// padding-top + 绝对定位注音盒）。预留这半边是对的、必须永远保住；但那套同时带来
// glossary 有意为之的**紧凑基字**，读音比基字宽时向一侧悬出，词头因此看起来「读音
// 偏在词的左边」——BUG-2568 因此把词头换回原生 <ruby>，并把预留直接挂到
// `.expression` 自己身上（同样是 em，同样 zoom 免疫）。
//
// 所以本守卫锁的是 BUG-1098 的**不变量**（词头有 em 纵向预留、注音字号不是硬编码
// px），而不是当年那一种实现；具体「词头必须走原生 ruby」由
// popup_headword_native_ruby_bug2568_test.dart 单独守。
//
// ruby 几何在无头环境渲染不出来，故守卫的是规则本身的存在与作用域（与既有
// popup_glossary_ruby_lineheight_guard_test.dart 同法，那份只覆盖释义体）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String css =
      maskCssComments(File('assets/popup/popup.css').readAsStringSync());

  /// 取顶格写的 `<选择器> { ... }` 规则体。锚到行首是必要的：`.expression` 与
  /// `.expression-scroll .expression` 都以同一串结尾，不锚行首会取错规则。
  String? ruleBody(String source, String selector) => RegExp(
        '(?:^|\n)${RegExp.escape(selector)}\\s*\\{([^}]*)\\}',
      ).firstMatch(source)?.group(1);

  group('词头 furigana 的纵向预留（根因 ①）', () {
    test('.expression 自带 em padding-top 预留带（zoom 免疫）', () {
      final String? body = ruleBody(css, '.expression');
      expect(body, isNotNull, reason: 'popup.css 必须有 `.expression` 规则');
      expect(
        RegExp(r'padding-top\s*:\s*[\d.]+em').hasMatch(body!),
        isTrue,
        reason: '预留必须内生于词头且以 em 表达，才能随 popupContentZoom 等比缩放；'
            '行盒 leading 顶不住——实测 line-height 1.7 / 2.0 下原生 ruby 注音仍向上'
            '溢出 4.0px，而 .expression-scroll 的顶部溢出不可达（BUG-1098 根因 ②）',
      );
    });

    test('预留带容得下注音（带高 >= 注音字号）', () {
      final String band = RegExp(r'padding-top\s*:\s*([\d.]+)em')
          .firstMatch(ruleBody(css, '.expression')!)!
          .group(1)!;
      final String rt = RegExp(r'font-size\s*:\s*([\d.]+)em')
          .firstMatch(ruleBody(css, '.expression ruby > rt')!)!
          .group(1)!;
      expect(
        double.parse(band),
        greaterThanOrEqualTo(double.parse(rt)),
        reason: '放大振假名（BUG-1655 把 0.5em 调到 0.6em）时预留带必须同步抬高，'
            '否则注音重新顶出 .expression-scroll 被裁',
      );
    });

    test('.expression 的注音字号是 em，不是硬编码 px', () {
      // 硬编码 px 会把注音钉成绝对像素、脱离 documentElement.style.zoom 链
      // （popupContentZoom），溢出量随 zoom 线性放大——BUG-1098/363 的老坑。
      final String? body = ruleBody(css, '.expression ruby > rt');
      expect(body, isNotNull,
          reason: '词头需要一条承载注音字号的规则（BUG-2568 后是 `.expression ruby > rt`）');
      expect(RegExp(r'font-size\s*:\s*[\d.]+em').hasMatch(body!), isTrue,
          reason: '词头注音字号必须以 em 表达');
    });

    test('.expression rt 不得声明 px 字号，且保住 user-select:none', () {
      final String? body = ruleBody(css, '.expression rt');
      expect(body, isNotNull, reason: '词头 rt 仍需要一条规则承载 user-select:none');
      expect(RegExp(r'font-size\s*:\s*\d+px').hasMatch(body!), isFalse,
          reason: '词头 rt 的字号必须是 em（BUG-1098）');
      expect(body.contains('-webkit-user-select: none'), isTrue,
          reason: '词头是点击目标（onLinkClick），其读音不得被拖选');
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

    test('两份 content.css 已重新生成，带上词头的预留与原生 ruby 规则', () {
      // 既有的 parity 守卫只收集以 `.` 开头的选择器里的一部分，这里显式核对生成物
      // 真的跟着 popup.css 走了一遍生成器。
      for (final String dir in mirrors) {
        final String content =
            maskCssComments(File('$dir/content.css').readAsStringSync());
        expect(
          RegExp(r'padding-top\s*:\s*[\d.]+em')
              .hasMatch(ruleBody(content, '.expression') ?? ''),
          isTrue,
          reason: '$dir/content.css 缺词头预留 — 改完 popup.css 必须重跑 '
              'tools/browser-extension/scripts/generate-content-css.mjs',
        );
        expect(ruleBody(content, '.expression ruby'), isNotNull,
            reason: '$dir/content.css 缺 `.expression ruby` 的原生 ruby 规则');
      }
    });
  });
}
