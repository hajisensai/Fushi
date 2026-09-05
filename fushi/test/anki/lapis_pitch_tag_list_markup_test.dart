import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

import '../helpers/source_guard.dart';

/// 用户报的同一张英语卡上，音标标签框（Lapis `#pitch-tags`）的两个缺陷。
///
/// **BUG-2151**：黑框超高、左边一大块空白、两条音标之间没有分隔符。根因是同一个仓库
/// 两端的列表标记契约对不上——消费端 `LapisNoteType.css` 只对 `#pitch-tags ul` 做 list
/// 归一，产出端 `popup.js` 的两个制卡 builder 却写 `<ol>`。
///
/// 日语卡看不出来，是因为 Lapis 自己的 `handlePitches` 在字段里能解析出数字/假名声调时
/// 会**整个重建** `#pitch-tags`（它建的是 `<ul>`）。英语 IPA 既没有数字也没有假名，
/// `handlePitches` 提前 return，框里留的就是制卡侧原样写进去的 `<ol>` —— 于是吃满浏览器
/// 默认的 `padding-inline-start: 40px` + `margin-block: 1em`，且 `ul` 专属的
/// `::after { content: "・" }` 一条都没命中。
///
/// **BUG-2155**：换成维基音标词典（一个词给十几条音标）后整个卡头被撑爆，窄卡上把封面
/// 顶出视口。三条独立的成因，缺一条都还会犯：
///  1. `.tags` 的 `max-width: 60dvw` 是**视口**相对的上限，塞进 `max-width: 820px` 的
///     卡头里毫无意义；
///  2. `.tags` 的 `white-space: nowrap` 是给单个短标签设计的；
///  3. `.dh-vocab` 是 flex item，`min-width` 默认 `auto`（不小于内容最小尺寸），
///     标签框一宽就把 `.dh-image` 压成 0。
///
/// 换行点必须来自 flex item 边界而不是空白：制卡侧产出的 `<li>…</li><li>…</li>`
/// 之间**一个空白都没有**，行内流因此没有任何换行机会。
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

    test('制卡侧复用展示侧的 pitch 归一化（BUG-2152 跨词典那一路）', () {
      final String body = functionBody('buildMinePayload');
      expect(
        body,
        contains('mergeIdenticalPitchGroups(pitches || [])'),
        reason: '制卡侧又直接吃原始 pitches 了 —— 两本词典给出同一份发音时，'
            '弹窗里合成一行、卡片上却会重复两遍',
      );
      expect(body, contains('constructPitchPositionHtml(normalizedPitches)'));
      expect(
        body,
        contains('constructPhoneticTranscriptionsHtml(normalizedPitches)'),
      );
    });
  });

  group('Lapis CSS：#pitch-tags 的列表与尺寸契约', () {
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

    String declsOf(bool Function(List<String>) where, String what) {
      final Iterable<String> hits =
          parsed.where(where).map((List<String> r) => r[1]);
      expect(hits, isNotEmpty, reason: '$what 规则整条没了');
      return hits.join('\n');
    }

    test('list 归一规则（list-style: none）同时点名 #pitch-tags 的 ul 和 ol（BUG-2151）', () {
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

    test('「・」分隔符规则同时点名 #pitch-tags 的 ul 和 ol（BUG-2151）', () {
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

    test('#pitch-tags 的列表是 wrap 的 flex 容器（BUG-2155）', () {
      final String decls = declsOf(
        (List<String> r) =>
            r[0].contains('#pitch-tags ul') &&
            r[1].contains('list-style: none'),
        '#pitch-tags 的列表',
      );
      expect(decls, contains('display: inline-flex'),
          reason: '退回 display:inline 就没有换行机会了：制卡侧产出的 li 之间没有空白');
      expect(decls, contains('flex-wrap: wrap'));

      final String liDecls = declsOf(
        (List<String> r) => r[0].trim() == '#pitch-tags li',
        '#pitch-tags li',
      );
      expect(liDecls, contains('white-space: nowrap'),
          reason: '一条音标是一个整体，断成 `[/fɜː` + `st/]` 比不换行更糟');
    });

    test('#pitch-tags 的宽度上限相对容器，不是相对视口（BUG-2155）', () {
      final String decls = declsOf(
        (List<String> r) => r[0].trim() == '#pitch-tags',
        '#pitch-tags 自身',
      );
      expect(decls, contains('max-width: 100%'),
          reason: '不覆盖 .tags 的 max-width:60dvw 的话，宽屏上这个框比整个卡头还宽，'
              '窄卡上会把 .def-header 顶出视口、封面被推到看不见');
      expect(decls, contains('white-space: normal'),
          reason: '.tags 的 nowrap 是给单个短标签设计的，音标词典一个词能给十几条');
    });

    test('.dh-vocab 有 min-width: 0，不会饿死封面图那一列（BUG-2155）', () {
      final String decls = declsOf(
        (List<String> r) => r[0].trim() == '.dh-vocab',
        '.dh-vocab',
      );
      expect(decls, contains('min-width: 0'),
          reason: 'flex item 的 min-width 默认 auto = 不小于内容最小尺寸；'
              '标签框一宽，.dh-image 就被压成 0');
    });
  });
}
