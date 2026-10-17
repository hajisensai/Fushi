// Anki 模式模板渲染对拍：用例移植自 ankitects/anki rslib
// `template.rs` / `template_filters.rs` / `cloze.rs` / `text.rs` 的单测。
// 与 rslib 有意不同的地方（type: 输出空串、hint 的 id 哈希、partial 渲染）在
// 用例旁注明。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

/// rslib 测试里的 `strip_html`。
String strip(String html) => ankiStripHtml(html);

String reveal(String text, int ord, bool question) =>
    ankiRevealClozeText(text, ord, question: question);

void main() {
  group('template.rs', () {
    test('field_empty', () {
      expect(ankiFieldIsEmpty(''), isTrue);
      expect(ankiFieldIsEmpty(' '), isTrue);
      expect(ankiFieldIsEmpty('x'), isFalse);
      expect(ankiFieldIsEmpty('<BR>'), isTrue);
      expect(ankiFieldIsEmpty('<div />'), isTrue);
      expect(ankiFieldIsEmpty(' <div> <br> </div>\n'), isTrue);
      expect(ankiFieldIsEmpty(' <div>x</div>\n'), isFalse);
    });

    String side(String tpl, Map<String, String> fields, {int ord = 0}) =>
        renderAnkiCardSide(template: tpl, fields: fields, cardOrd: ord);

    test('parsing：注释内不展开、空白、残余 }}', () {
      final Map<String, String> f = <String, String>{
        'bar': 'B',
        'baz': 'Z',
        'abc': 'A',
        'tag': 'T',
      };
      expect(side('foo {{bar}} {{#baz}} quux {{/baz}}', f), 'foo B  quux ');
      expect(
        side(
          'foo <!--{{bar }} --> {{#baz}} --> <!-- <!-- {{#def}} --> '
          'ģ-->і<!-- 2 --><!----> <!-- quux {{/baz}} <!-- {{nc:abc}}',
          f,
        ),
        'foo <!--{{bar }} -->  --> <!-- <!-- {{#def}} --> '
        'ģ-->і<!-- 2 --><!----> <!-- quux  <!-- A',
      );
      expect(side('{{^baz}}{{/baz}}', f), '');
      expect(side('{{ tag }}', f), 'T');
      expect(side('text }} more', f), 'text }} more');
    });

    test('parsing：段不配对报错，注释里的段不算', () {
      final Map<String, String> f = <String, String>{
        'mis': 'x',
        'matched': 'y',
        'foo': 'z',
      };
      for (final String bad in <String>[
        '{{#mis}}{{/matched}}',
        '{{/matched}}',
        '{{#mis}}',
        '{{#mis}}<!--{{/matched}}-->',
      ]) {
        expect(
          () => side(bad, f),
          throwsA(isA<AnkiTemplateError>()),
          reason: bad,
        );
      }
      expect(side('<!--{{#mis}}{{/matched}}-->', f), isNotEmpty);
      expect(side('<!--{{foo}}', f), '<!--z');
      expect(side('{{foo}}-->', f), 'z-->');
    });

    test('parsing：过滤器写法往返（字段改写不动原文）', () {
      for (final String orig in <String>[
        'foo {{one:two}} {{one:two:three}} {{^baz}} {{/baz}} {{foo:}}',
        'foo {{one:two}} <!--<!--abc {{^def}}-->--> {{one:two:three}} '
            '{{^baz}} <!-- {{/baz}} 🙂 --> {{/baz}} {{foo:}}',
      ]) {
        expect(templateNamesToIds(orig, const <String, String>{}), orig);
        expect(templateIdsToNames(orig, const <String, String>{}), orig);
      }
    });

    test('nonempty（renders_with_fields）', () {
      // nonempty = {1, 3}
      final Map<String, String> fields = <String, String>{
        '1': 'x',
        '2': '',
        '3': 'x',
        '4': '',
      };
      bool empty(String tpl) => isAnkiCardEmpty(
        questionTemplate: tpl,
        noteFields: fields,
        cardOrd: 0,
        isCloze: false,
      );
      expect(empty('{{2}}{{1}}'), isFalse);
      expect(empty('{{2}}'), isTrue);
      expect(empty('{{2}}{{4}}'), isTrue);
      expect(empty('{{#3}}{{^2}}{{1}}{{/2}}{{/3}}'), isFalse);
      expect(empty('{{^1}}{{3}}{{/1}}'), isTrue);
    });

    test('alt_syntax', () {
      final Map<String, String> f = <String, String>{'Front': 'f', 'Back': 'b'};
      expect(
        side('\n{{=<% %>=}}\n<%Front%>\n<% #Back %>\n<%/Back%>', f),
        '\nf\n\n',
      );
      expect(
        side('\n{{=<% %>=}}\n{{#foo}}\n<%Front%>\n{{/foo}}\n', f),
        '\n{{#foo}}\nf\n{{/foo}}\n',
      );
    });

    group('render_single', () {
      final Map<String, String> map = <String, String>{
        'F': 'f',
        'B': 'b',
        'E': ' ',
        'c1': '1',
      };
      String r(String tpl) => side(tpl, map, ord: 1);

      test('替换 / 空段 / 嵌套 / 注释 / 卡片条件', () {
        expect(r('{{B}}A{{F}}'), 'bAf');
        expect(r('{{#E}}A{{/E}}'), '');
        expect(
          () => r('{{#E}}}{{^M}}A{{/M}}{{/E}}}'),
          throwsA(isA<AnkiTemplateError>()),
          reason: '不存在的字段做条件——即使外层段为假也要报错',
        );
        expect(r('{{^E}}1{{#F}}2{{#B}}{{F}}{{/B}}{{/F}}{{/E}}'), '12f');
        expect(
          r(
            '{{^E}}1<!--{{#F}}2{{#B}}{{F}}{{/B}}{{/F}}-->ģ'
            '<!-- this is a comment -->{{/E}}і',
          ),
          '1<!--{{#F}}2{{#B}}{{F}}{{/B}}{{/F}}-->ģ'
          '<!-- this is a comment -->і',
        );
        expect(r('{{^c2}}1{{#c1}}2{{/c1}}{{/c2}}'), '12');
      });

      test('过滤器：未知过滤器透传（非 partial 模式）', () {
        // rslib partial 模式会把未知过滤器留给 Python；非 partial 直接忽略。
        expect(r('{{one:two:B}}'), 'b');
        expect(r('{{one::text:B}}'), 'b');
        expect(r('{{text:B}}'), 'b');
        // 空字段名 + 过滤器：非 partial 模式什么都不输出。
        expect(r('{{filter:}}'), '');
      });

      test('未知字段报错', () {
        expect(() => r('{{X}}'), throwsA(isA<AnkiTemplateError>()));
        expect(
          () => r('{{foo:text:X}}'),
          throwsA(
            isA<AnkiTemplateError>().having(
              (AnkiTemplateError e) => e.message,
              'message',
              contains('{{foo:text:X}}'),
            ),
          ),
        );
      });
    });

    test('render_card：空正面 / FrontSide', () {
      AnkiRenderedCard card(String q, [String a = '']) => renderAnkiCard(
        questionTemplate: q,
        answerTemplate: a,
        noteFields: const <String, String>{'E': '', 'N': 'N'},
        cardOrd: 1,
        isCloze: false,
      );
      final AnkiRenderedCard blank = card('test{{E}}');
      expect(blank.isEmpty, isTrue);
      expect(blank.question, 'test');
      // 正面的 {{FrontSide}} 渲染成空。
      final AnkiRenderedCard ok = card(
        '{{FrontSide}}{{N}}',
        '{{FrontSide}}<hr>',
      );
      expect(ok.isEmpty, isFalse);
      expect(ok.question, 'N');
      expect(ok.answer, 'N<hr>');
    });
  });

  group('template_filters.rs', () {
    test('furigana', () {
      const String text = 'test first[second] third[fourth]';
      expect(ankiKanaFilter(text), 'testsecondfourth');
      expect(ankiKanjiFilter(text), 'testfirstthird');
      expect(
        ankiFuriganaFilter('first[second]'),
        '<ruby><rb>first</rb><rt>second</rt></ruby>',
      );
      // 日文实例 + 声音标记不被当成注音。
      expect(
        ankiFuriganaFilter('私[わたし]は 毎朝[まいあさ]'),
        '<ruby><rb>私</rb><rt>わたし</rt></ruby>は'
        '<ruby><rb>毎朝</rb><rt>まいあさ</rt></ruby>',
      );
      expect(ankiKanaFilter('x[sound:a.mp3]'), 'x[sound:a.mp3]');
      expect(ankiKanaFilter('漢字[かんじ]&nbsp;です'), 'かんじ です');
    });

    test('hint（结构同 rslib，id 用 sha256 而非 blake3）', () {
      final String out = ankiHintFilter('foo', 'field');
      final RegExp shape = RegExp(r'''^
<a class=hint href="#"
onclick="this.style.display='none';
document.getElementById\('hint([0-9a-f]{16})'\).style.display='block';
return false;" draggable=false>
field</a>
<div id="hint\1" class=hint style="display: none">foo</div>
$''');
      expect(shape.hasMatch(out), isTrue, reason: out);
      expect(ankiHintFilter('  ', 'field'), '  ');
    });

    test('type: 暂不支持，输出空串（rslib 输出 [[type:…]]）', () {
      final Map<String, String> f = <String, String>{'Text': 'x'};
      for (final String tpl in <String>[
        '{{type:Text}}',
        '{{type:cloze:Text}}',
        '{{type:nc:ci:Text}}',
        '{{type-nc:Text}}',
      ]) {
        expect(
          renderAnkiCardSide(template: tpl, fields: f, cardOrd: 0),
          '',
          reason: tpl,
        );
      }
    });

    test('cloze', () {
      const String text = '{{c1::one}} {{c2::two::hint}}';
      expect(strip(ankiClozeFilter(text, 0, question: true)), '[...] two');
      expect(
        ankiClozeFilter(text, 0, question: true),
        '<span class="cloze" data-cloze="one" data-ordinal="1">[...]</span> '
        '<span class="cloze-inactive" data-ordinal="2">two</span>',
      );
      expect(strip(ankiClozeFilter(text, 1, question: true)), 'one [hint]');
      expect(strip(ankiClozeFilter(text, 1, question: false)), 'one two');
      // 序号不存在 → 空串（cloze overlapper 等插件依赖此行为）。
      expect(ankiClozeFilter(text, 2, question: true), '');
    });

    test('tts', () {
      expect(
        ankiTtsFilter('en_US voices=Bob,Jane', 'foo'),
        '[anki:tts lang=en_US voices=Bob,Jane]foo[/anki:tts]',
      );
      expect(
        renderAnkiCardSide(
          template: '{{tts ja_JP:Front}}',
          fields: const <String, String>{'Front': '食べる'},
          cardOrd: 0,
        ),
        '[anki:tts lang=ja_JP]食べる[/anki:tts]',
      );
    });
  });

  group('cloze.rs', () {
    test('cloze numbers', () {
      expect(clozeOrdinalsIn('test'), <int>{});
      expect(clozeOrdinalsIn('{{c2::te}}{{c1::s}}t{{'), <int>{1, 2});
      expect(clozeOrdinalsIn('{{c0::te}}s{{c2::t}}s'), <int>{2});
    });

    test('cloze_only', () {
      expect(ankiRevealClozeTextOnly('foo', 1, question: true), '');
      expect(
        ankiRevealClozeTextOnly('foo {{c1::bar}}', 1, question: true),
        '...',
      );
      expect(
        ankiRevealClozeTextOnly('foo {{c1::bar::baz}}', 1, question: true),
        'baz',
      );
      expect(
        ankiRevealClozeTextOnly('foo {{c1::bar}}', 1, question: false),
        'bar',
      );
      expect(
        ankiRevealClozeTextOnly('foo {{c1::bar}}', 2, question: false),
        '',
      );
      expect(
        ankiRevealClozeTextOnly('{{c1::foo}} {{c1::bar}}', 1, question: false),
        'foo, bar',
      );
    });

    test('nested_cloze_plain_text', () {
      expect(
        strip(reveal('foo {{c1::bar {{c2::baz}}}}', 1, true)),
        'foo [...]',
      );
      expect(
        strip(reveal('foo {{c1::bar {{c2::baz}}}}', 1, false)),
        'foo bar baz',
      );
      const String t = 'foo {{c1::bar {{c2::baz}}::qux}}';
      expect(strip(reveal(t, 2, true)), 'foo bar [...]');
      expect(strip(reveal(t, 2, false)), 'foo bar baz');
      expect(strip(reveal(t, 1, true)), 'foo [qux]');
      expect(strip(reveal(t, 1, false)), 'foo bar baz');
    });

    test('nested_cloze_html', () {
      expect(clozeOrdinalsIn('{{c2::te{{c1::s}}}}t{{'), <int>{1, 2});
      // htmlescape::encode_attribute('bar <span class="cloze-inactive" data-ordinal="2">baz</span>')
      const String encodedInner =
          'bar&#x20;&lt;span&#x20;class&#x3D;&quot;'
          'cloze&#x2D;inactive&quot;&#x20;data&#x2D;ordinal&#x3D;&quot;2&quot;'
          '&gt;baz&lt;&#x2F;span&gt;';
      expect(
        reveal('foo {{c1::bar {{c2::baz}}}}', 1, true),
        'foo <span class="cloze" data-cloze="$encodedInner" '
        'data-ordinal="1">[...]</span>',
      );
      expect(
        reveal('foo {{c1::bar {{c2::baz}}}}', 1, false),
        'foo <span class="cloze" data-ordinal="1">bar '
        '<span class="cloze-inactive" data-ordinal="2">baz</span></span>',
      );
      const String t = 'foo {{c1::bar {{c2::baz}}::qux}}';
      expect(
        reveal(t, 2, true),
        'foo <span class="cloze-inactive" data-ordinal="1">bar '
        '<span class="cloze" data-cloze="baz" data-ordinal="2">[...]</span></span>',
      );
      expect(
        reveal(t, 2, false),
        'foo <span class="cloze-inactive" data-ordinal="1">bar '
        '<span class="cloze" data-ordinal="2">baz</span></span>',
      );
      expect(
        reveal(t, 1, true),
        'foo <span class="cloze" data-cloze="$encodedInner" '
        'data-ordinal="1">[qux]</span>',
      );
      expect(
        reveal(t, 1, false),
        'foo <span class="cloze" data-ordinal="1">bar '
        '<span class="cloze-inactive" data-ordinal="2">baz</span></span>',
      );
    });

    test('mathjax_html：表达式内去标签保留实体', () {
      expect(
        ankiClozeFilter(r'{{c1::\(<foo>&lt;&gt;</foo>\)}}', 0, question: false),
        r'<span class="cloze" data-ordinal="1">\(&lt;&gt;\)</span>',
      );
    });

    test('MathJax 内的花括号不提前关闭 cloze', () {
      const String a = r'{{c1:: \( \frac{1}{\sqrt{\pi}} \) }}';
      expect(strip(reveal(a, 1, true)), '[...]');
      expect(strip(reveal(a, 1, false)), r' \( \frac{1}{\sqrt{\pi}} \) ');
      const String b = r'{{c1:: \[ \frac{1}{\sqrt{\pi}} \] }}';
      expect(strip(reveal(b, 1, true)), '[...]');
      expect(strip(reveal(b, 1, false)), r' \[ \frac{1}{\sqrt{\pi}} \] ');
      const String c = r'{{c1:: \(\pi\) and \(\sqrt{2}\) }}';
      expect(strip(reveal(c, 1, true)), '[...]');
      expect(strip(reveal(c, 1, false)), r' \(\pi\) and \(\sqrt{2}\) ');
    });

    test('未闭合 / 错配的 MathJax 定界符按普通文本', () {
      for (final (String text, String answer) in <(String, String)>[
        (r'{{c1::foo \( bar}} baz', r'foo \( bar baz'),
        (r'{{c1::foo \[ bar}} baz', r'foo \[ bar baz'),
      ]) {
        expect(strip(reveal(text, 1, true)), '[...] baz');
        expect(strip(reveal(text, 1, false)), answer);
        expect(clozeOrdinalsIn(text), <int>{1});
      }
      expect(strip(reveal(r'{{c1::\( a \]}} b', 1, false)), r'\( a \] b');
    });

    test('MathJax 内嵌套 cloze', () {
      const String t = r'{{c1::\( a {{c2::b}} \frac{1}{\sqrt{2}} \)}} c';
      expect(strip(reveal(t, 1, true)), '[...] c');
      expect(strip(reveal(t, 1, false)), r'\( a b \frac{1}{\sqrt{2}} \) c');
      expect(strip(reveal(t, 2, false)), r'\( a b \frac{1}{\sqrt{2}} \) c');
      expect(clozeOrdinalsIn(t), <int>{1, 2});

      const String u = r'\(x = {{c1::a}} + {{c2::\frac{1}{2} }}\)';
      expect(strip(reveal(u, 1, false)), r'\(x = a + \frac{1}{2} \)');
      expect(strip(reveal(u, 2, false)), r'\(x = a + \frac{1}{2} \)');

      expect(strip(reveal(r'\(a {{c1::b\) c}} d', 1, false)), r'\(a b\) c d');
      expect(
        strip(reveal(r'\(\sqrt{\pi}}\) {{c1::a}}', 1, false)),
        r'\(\sqrt{\pi}}\) a',
      );
    });

    test('non_latin', () {
      expect(clozeOrdinalsIn('öaöaöööaö'), isEmpty);
    });

    test('multi_card', () {
      expect(clozeOrdinalsIn('{{c1,2,3::multi}}'), <int>{1, 2, 3});
      const String t =
          '{{c1,2::shared}} word and {{c1::first}} vs {{c2::second}}';
      expect(strip(reveal(t, 1, true)), '[...] word and [...] vs second');
      expect(strip(reveal(t, 2, true)), '[...] word and first vs [...]');
      expect(strip(reveal(t, 1, false)), 'shared word and first vs second');
      expect(strip(reveal(t, 2, false)), 'shared word and first vs second');
      expect(clozeOrdinalsIn(t), <int>{1, 2});
      for (final int ord in <int>[1, 2, 3]) {
        expect(
          reveal('{{c1,2,3::multi}}', ord, true),
          contains('data-ordinal="1,2,3"'),
        );
      }
      const String h = '{{c1,2::answer::hint}}';
      expect(strip(reveal(h, 1, true)), '[hint]');
      expect(strip(reveal(h, 2, true)), '[hint]');
      expect(strip(reveal(h, 1, false)), 'answer');
      expect(strip(reveal(h, 2, false)), 'answer');
      expect(clozeOrdinalsIn('{{c1,1,2::test}}'), <int>{1, 2});
      expect(clozeOrdinalsIn('{{c0,1,2::test}}'), <int>{1, 2});
      expect(clozeOrdinalsIn('{{c1,,3::test}}'), <int>{1, 3});
      const String o = '{{c1,2::shared}} and {{c1::first}} vs {{c2::second}}';
      expect(ankiRevealClozeTextOnly(o, 1, question: true), '..., ...');
      expect(ankiRevealClozeTextOnly(o, 2, question: true), '..., ...');
      expect(ankiRevealClozeTextOnly(o, 1, question: false), 'shared, first');
      expect(ankiRevealClozeTextOnly(o, 2, question: false), 'shared, second');
    });

    test('multi_card_nested / 同序号父子嵌套', () {
      const String t = '{{c1,2::outer {{c3::inner}}}}';
      expect(strip(reveal(t, 1, true)), '[...]');
      expect(strip(reveal(t, 2, true)), '[...]');
      expect(strip(reveal(t, 3, true)), 'outer [...]');
      expect(clozeOrdinalsIn(t), <int>{1, 2, 3});
      const String s = '{{c1::outer {{c1::inner}}}}';
      expect(strip(reveal(s, 1, true)), '[...]');
      expect(clozeOrdinalsIn(s), <int>{1});
    });

    test('畸形 / 超深嵌套不崩', () {
      final String deep = '${'{{c1::' * 30}x${'}}' * 30}';
      expect(() => reveal(deep, 1, true), returnsNormally);
      expect(() => reveal('{{c1::a {{c2::b}}', 1, false), returnsNormally);
      expect(() => reveal('}}}} {{c::x}} {{c1:x}}', 1, false), returnsNormally);
    });
  });

  group('text.rs strip_html', () {
    test('标签 / script 整段', () {
      expect(strip('test'), 'test');
      expect(strip('t<b>e</b>st'), 'test');
      expect(strip('so<SCRIPT>t<b>e</b>st</script>me'), 'some');
      expect(strip('a&nbsp;b &amp; &#x41;&#66;'), 'a b & AB');
    });
  });

  group('整卡渲染：特殊字段与 cloze 笔记', () {
    const AnkiCardSpecialFields specials = AnkiCardSpecialFields(
      tags: <String>['n5', 'verb::ichidan'],
      deckName: '日本語::語彙',
      noteTypeName: 'Basic',
      cardName: 'Recognition',
      cardFlag: 3,
      cardId: '1700000000000',
    );

    test('Tags / Type / Deck / Subdeck / Card / CardFlag / CardID', () {
      final AnkiRenderedCard card = renderAnkiCard(
        questionTemplate:
            '{{Front}}|{{Tags}}|{{Type}}|{{Deck}}|{{Subdeck}}|{{Card}}|'
            '{{CardFlag}}|{{CardID}}',
        answerTemplate: '{{FrontSide}}<hr id=answer>{{Back}}',
        noteFields: const <String, String>{'Front': '食べる', 'Back': 'eat'},
        cardOrd: 0,
        isCloze: false,
        specials: specials,
      );
      expect(
        card.question,
        '食べる|n5 verb::ichidan|Basic|日本語::語彙|語彙|Recognition|flag3|'
        '1700000000000',
      );
      expect(card.answer, '${card.question}<hr id=answer>eat');
    });

    test('正面只引用特殊字段也不算空（Deck 恒非空）', () {
      expect(
        isAnkiCardEmpty(
          questionTemplate: '{{Deck}}',
          noteFields: const <String, String>{'Front': ''},
          cardOrd: 0,
          isCloze: false,
        ),
        isFalse,
      );
    });

    test('cloze 笔记：正反面与空卡', () {
      const Map<String, String> note = <String, String>{
        'Text': '{{c1::東京}}は{{c2::日本::国}}の首都',
        'Extra': '',
      };
      AnkiRenderedCard card(int ord) => renderAnkiCard(
        questionTemplate: '{{cloze:Text}}',
        answerTemplate: '{{cloze:Text}}<br>{{Extra}}',
        noteFields: note,
        cardOrd: ord,
        isCloze: true,
      );
      expect(strip(card(0).question), '[...]は日本の首都');
      expect(strip(card(0).answer), '東京は日本の首都');
      expect(strip(card(1).question), '東京は[国]の首都');
      expect(card(2).isEmpty, isTrue);
      expect(
        isAnkiCardEmpty(
          questionTemplate: '{{cloze:Text}}',
          noteFields: note,
          cardOrd: 1,
          isCloze: true,
        ),
        isFalse,
      );
      expect(
        isAnkiCardEmpty(
          questionTemplate: '{{cloze:Text}}',
          noteFields: note,
          cardOrd: 4,
          isCloze: true,
        ),
        isTrue,
      );
    });
  });

  group('字段引用 名字 ↔ fld:<id>', () {
    const Map<String, String> nameToId = <String, String>{
      'Front': 'f1',
      'Back': 'b2',
      'Reading': 'r3',
    };
    final Map<String, String> idToName = <String, String>{
      for (final MapEntry<String, String> e in nameToId.entries) e.value: e.key,
    };

    test('替换 / 过滤器 / 段标记 / 特殊字段 / 注释', () {
      const String tpl =
          '{{Front}} {{furigana:kana:Reading}} {{#Back}}x{{/Back}} '
          '{{^ Front }}y{{/ Front }} {{FrontSide}} {{Tags}} {{#c1}}{{/c1}} '
          '<!-- {{Front}} --> {{Unknown}} {{{Back}}}';
      final String ids = templateNamesToIds(tpl, nameToId);
      expect(
        ids,
        '{{fld:f1}} {{furigana:kana:fld:r3}} {{#fld:b2}}x{{/fld:b2}} '
        '{{^ fld:f1 }}y{{/ fld:f1 }} {{FrontSide}} {{Tags}} {{#c1}}{{/c1}} '
        '<!-- {{Front}} --> {{Unknown}} {{{fld:b2}}}',
      );
      expect(templateIdsToNames(ids, idToName), tpl);
    });

    test('id 渲染：先转回名字再渲染', () {
      final String ids = templateNamesToIds('{{text:Front}}', nameToId);
      expect(
        renderAnkiCardSide(
          template: templateIdsToNames(ids, idToName),
          fields: const <String, String>{'Front': '<b>x</b>'},
          cardOrd: 0,
        ),
        'x',
      );
    });

    test('未知 id 原样保留；旧语法前缀保留', () {
      expect(templateIdsToNames('{{fld:zz}}', idToName), '{{fld:zz}}');
      const String alt = '{{=<% %>=}}<%Front%>{{Front}}';
      final String ids = templateNamesToIds(alt, nameToId);
      expect(ids, '{{=<% %>=}}<%fld:f1%>{{Front}}');
      expect(templateIdsToNames(ids, idToName), alt);
    });
  });

  test('lang 容器', () {
    expect(
      wrapAnkiCardHtmlWithLang('<b>x</b>', 'ja'),
      '<div lang="ja"><b>x</b></div>',
    );
    expect(wrapAnkiCardHtmlWithLang('x', null), 'x');
    expect(wrapAnkiCardHtmlWithLang('x', '  '), 'x');
    expect(
      wrapAnkiCardHtmlWithLang('x', 'zh"><script>'),
      isNot(contains('<script>')),
    );
  });
}
