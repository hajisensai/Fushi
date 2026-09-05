import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

import '../helpers/source_guard.dart';

/// BUG-2151：英语卡的音标黑框（Lapis `#pitch-tags`）超高、左边一大块空白、两条音标
/// 之间没有分隔符。
///
/// 根因是**同一个仓库两端的标记契约对不上**：
///  * 消费端 `LapisNoteType.css` 只对 `#pitch-tags ul` 做 list 归一
///    （`list-style/display/margin/padding` 清零 + `・` 分隔符）；
///  * 产出端 `popup.js` 的两个制卡 builder 却写 `<ol>`。
///
/// 日语卡看不出来，是因为 Lapis 自己的 `handlePitches` 在字段里解析得出数字/假名声调
/// 时会**整个重建** `#pitch-tags`（它建的是 `<ul>`）。英语 IPA 既没有数字也没有假名，
/// `handlePitches` 提前 return，框里留的就是制卡侧原样写进去的 `<ol>` —— 于是吃满浏览器
/// 默认的 `padding-inline-start: 40px` + `margin-block: 1em`，且 `ul` 专属的
/// `::after { content: "・" }` 一条都没命中。
///
/// 因此本守卫锁两头，任一端漂回去都红：
///  1. 制卡侧产出 `<ul>`；
///  2. Lapis CSS 的归一规则同时覆盖 `ul` 和 `ol`（存量卡片字段里存的是 `<ol>`，
///     用户 Anki 里那批卡改不了，只能靠 CSS 认下来）。
///
/// popup.js 三镜像的字节一致由 browser_extension_popup_parity_guard_test 锁定，
/// 本文件只扫 app 侧真身。flutter test cwd 是 hibiki 包根。
void main() {
  group('制卡侧 pitch 字段用 <ul>（BUG-2151）', () {
    final String src = File('assets/popup/popup.js').readAsStringSync();

    /// 取顶层函数体：`function <name>(` 到下一个列首 `}`。用 [maskJsComments] 而不是
    /// [maskComments]——后者不认模板串/正则，扫 JS 会把内容吃错。
    String functionBody(String name) {
      final int start = src.indexOf('function $name(');
      expect(start, greaterThanOrEqualTo(0),
          reason: 'popup.js 缺少 function $name');
      final int end = src.indexOf('\n}', start);
      expect(end, greaterThan(start), reason: '$name 函数体未闭合？');
      return maskJsComments(src.substring(start, end + 2));
    }

    for (final String name in <String>[
      'constructPitchPositionHtml',
      'constructPhoneticTranscriptionsHtml',
    ]) {
      test('$name 产出 <ul> 而不是 <ol>', () {
        final String body = functionBody(name);
        expect(
          body,
          contains(r'`<ul>${items}</ul>`'),
          reason: '$name 的列表标记必须是 ul —— Lapis #pitch-tags 的样式归一只认那条 '
              'ul/ol 规则，写别的标签就等于让黑框吃浏览器默认列表样式',
        );
        expect(
          body,
          isNot(contains('<ol>')),
          reason: '$name 又写回 <ol> 了（BUG-2151 的原始形态）',
        );
      });
    }
  });

  group('Lapis CSS 归一 #pitch-tags 下的 ul 与 ol（BUG-2151）', () {
    /// 把 CSS 切成 `(选择器, 声明块)` 对。够用：Lapis CSS 里 `#pitch-tags` 相关规则
    /// 都是平铺的，没有嵌套 at-rule 包着它们。
    List<List<String>> rules(String css) {
      final List<List<String>> out = <List<String>>[];
      int cursor = 0;
      while (true) {
        final int open = css.indexOf('{', cursor);
        if (open < 0) {
          break;
        }
        final int close = css.indexOf('}', open);
        if (close < 0) {
          break;
        }
        out.add(<String>[
          css.substring(cursor, open).trim(),
          css.substring(open + 1, close),
        ]);
        cursor = close + 1;
      }
      return out;
    }

    final List<List<String>> parsed = rules(maskCssComments(LapisNoteType.css));

    test('list 归一规则（list-style: none）同时点名 #pitch-tags 的 ul 和 ol', () {
      final Iterable<String> selectors = parsed
          .where((List<String> r) => r[1].contains('list-style: none'))
          .map((List<String> r) => r[0]);
      expect(selectors, isNotEmpty,
          reason: '#pitch-tags 的 list 归一规则整条没了 —— 黑框会吃回浏览器默认列表样式');
      final String joined = selectors.join('\n');
      expect(joined, contains('#pitch-tags ul'));
      expect(
        joined,
        contains('#pitch-tags ol'),
        reason: 'BUG-2151 之前制卡侧写的是 <ol>，那批卡已经在用户 Anki 里、改不了；'
            'CSS 漏掉 ol 就等于放着它们继续错版',
      );
    });

    test('「・」分隔符规则同时点名 #pitch-tags 的 ul 和 ol', () {
      final Iterable<String> selectors = parsed
          .where((List<String> r) => r[1].contains('content: "・"'))
          .map((List<String> r) => r[0]);
      expect(selectors, isNotEmpty, reason: 'pitch 条目之间的「・」分隔符规则整条没了');
      final String joined = selectors.join('\n');
      expect(joined, contains('#pitch-tags ul > li:not(:last-child)::after'));
      expect(
        joined,
        contains('#pitch-tags ol > li:not(:last-child)::after'),
        reason: '存量 <ol> 卡片的多条音标之间会连成一片，读起来像坏了',
      );
    });
  });
}
