import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-3224：制卡时 popup.js 把每本词典**整份** styles.css（加作用域前缀）内联进每个
/// 释义字段。牛津这类词典 210 KB 的 CSS 进卡约 247 KB，Lapis 默认又把 `{glossary}` 与
/// `{glossary-first}` 映射到两个字段，整条笔记 700 KB+，AnkiDroid 预览把字段过 Binder
/// 时 `TransactionTooLargeException`，预览打不开。
///
/// 修复：落卡渲染前按本条释义实际内容裁掉命中不到的作用域规则（交互态同样按命中判断）、
/// 没被引用的 @font-face / @keyframes，并去掉注释与空白（anki_glossary_css.dart）。
/// 这里钉两层：① 裁剪语义（只会多留、不会误删）；② 真实落卡路径上一张典型多词典卡的
/// 字段总大小上限、字段内不重复带同一份词典 CSS。
class _RenderPathRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) => throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) =>
      throw UnimplementedError();

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();

  Map<String, String> renderFor({
    required AnkiSettings settings,
    required AnkiMiningPayload payload,
  }) => renderMediaPayload(
    settings: settings,
    payload: payload,
    context: const AnkiMiningContext(sentence: ''),
    coverRef: null,
    sentenceAudioRef: null,
    processedAudio: '',
    dictionaryMediaTags: const <String, String>{},
  ).fields;
}

const String _scope = '.yomitan-glossary [data-dictionary="D"]';

/// popup.js 导出形状的一段释义：[body] 是 `<li data-dictionary>` 里的内容，[css] 进 `<style>`。
String _glossary(String body, String css, {String dict = 'D'}) =>
    '<div style="text-align: left;" class="yomitan-glossary"><ol>'
    '<li data-dictionary="$dict"><i>($dict)</i> <span>$body</span></li>'
    '</ol><style>$css</style></div>';

String _styleOf(String html) => RegExp(
  r'<style>([\s\S]*?)</style>',
).allMatches(html).map((Match m) => m.group(1)!).join('\n');

int _bytes(String s) => utf8.encode(s).length;

void main() {
  group('slimAnkiGlossaryHtml 裁剪语义', () {
    test('没有 <style> 的 HTML 原样返回同一实例', () {
      const String html = '<div class="yomitan-glossary"><ol></ol></div>';
      expect(slimAnkiGlossaryHtml(html), same(html));
      expect(slimAnkiGlossaryHtml(''), '');
    });

    test('命中本条内容的作用域规则保留，命中不到的去掉', () {
      final String out = slimAnkiGlossaryHtml(
        _glossary(
          '<span data-sc-class="used">x</span>',
          '$_scope [data-sc-class="used"] { color: red; }\n'
              '$_scope [data-sc-class="unused"] { color: blue; }\n'
              '$_scope .absent, $_scope span { font-weight: bold; }',
        ),
      );
      final String css = _styleOf(out);
      expect(css, contains('[data-sc-class="used"]{color: red;}'));
      expect(css, isNot(contains('unused')));
      // 选择器列表里任意一个命中就整条保留（原样，不拆列表）。
      expect(css, contains('$_scope .absent,$_scope span{font-weight: bold;}'));
    });

    test('非作用域规则一律保留（可能命中卡片模板里的元素）', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<b>x</b>',
            '.card { color: red; } body .nothing { x: y; }',
          ),
        ),
      );
      expect(css, contains('.card{color: red;}'));
      expect(css, contains('body .nothing{x: y;}'));
    });

    test('伪元素 / 结构伪类 / :not() 去掉后判断，只会多留', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<ul><li>a</li><li>b</li></ul>',
            '$_scope li::before { content: "• "; }\n'
                '$_scope li:not(:first-child) { margin: 0; }\n'
                '$_scope ul > :nth-child(2) { color: red; }\n'
                '$_scope table:first-child { color: blue; }',
          ),
        ),
      );
      expect(css, contains('li::before{content: "• ";}'));
      expect(css, contains('li:not(:first-child){margin: 0;}'));
      expect(css, contains('ul > :nth-child(2){color: red;}'));
      expect(css, isNot(contains('table')));
    });

    // Anki 桌面有鼠标 hover，Android WebView 点按也触发 :hover（「点一下显示」的提示靠它）：
    // 交互态与其它伪类同样放宽后按命中判断，命中本条元素的保留，命中不到的才去掉。
    test('交互态规则按命中判断：本条有的元素保留，没有的去掉', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<span class="icon">x<span class="tip">t</span></span>',
            '$_scope .icon { background: url(data:image/png;base64,AAAA); }\n'
                '$_scope .icon:hover { background: url(data:image/png;base64,BBBB); }\n'
                '$_scope .icon:active, $_scope .icon:focus-visible { outline: 0; }\n'
                '$_scope .icon:hover .tip { display: inline; }\n'
                '$_scope .absent:hover { background: url(data:image/png;base64,CCCC); }\n'
                '$_scope .icon:not(:hover) { opacity: 1; }',
          ),
        ),
      );
      expect(css, contains('AAAA'));
      expect(css, contains('BBBB'));
      expect(css, contains('outline'));
      expect(css, contains('.icon:hover .tip{display: inline;}'));
      expect(css, isNot(contains('CCCC')));
      expect(css, contains('.icon:not(:hover){opacity: 1;}'));
    });

    // 导出时 <details> 关着（没有 open 属性），卡片上点开才有：带 [open] 条件的规则
    // 要像交互态伪类一样放宽后判断，否则展开后的内容在卡上没有样式。
    test('BUG-3265 交互态属性 [open] 放宽后判断：关着导出的 details 展开样式保留', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<details><summary>例</summary><div class="x">body</div></details>',
            '$_scope details[open] .x { color: red; }\n'
                '$_scope details[open] > summary { font-weight: bold; }\n'
                '$_scope [open] { margin: 1px; }\n'
                '$_scope details[OPEN="" i] .x { padding: 2px; }\n'
                '$_scope details[open] .absent { color: blue; }\n'
                '$_scope [data-sc-class="unused"] { color: green; }',
          ),
        ),
      );
      expect(css, contains('details[open] .x{color: red;}'));
      expect(css, contains('details[open] > summary{font-weight: bold;}'));
      expect(css, contains('[open]{margin: 1px;}'));
      expect(css, contains('padding: 2px'));
      // 放宽只去掉交互态条件，结构照常判断：本条没有的元素照样裁。
      expect(css, isNot(contains('.absent')));
      // 其它属性条件不放宽。
      expect(css, isNot(contains('unused')));
    });

    test('@media 等条件组递归裁剪，裁空整组去掉', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<i class="a">x</i>',
            '@media (max-width: 600px) { $_scope .a { color: red; } $_scope .b { color: blue; } }\n'
                '@supports (display: grid) { $_scope .gone { display: grid; } }',
          ),
        ),
      );
      expect(
        css,
        contains('@media (max-width: 600px){$_scope .a{color: red;}}'),
      );
      expect(css, isNot(contains('.b{')));
      expect(css, isNot(contains('@supports')));
    });

    test('@font-face / @keyframes 只在留下的规则引用时保留', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<span class="ph">x</span>',
            '@font-face { font-family: "UsedFont"; src: url(data:font/woff2;base64,UUUU); }\n'
                '@font-face { font-family: DeadFont; src: url(data:font/woff2;base64,DDDD); }\n'
                '@keyframes spin { to { transform: rotate(1turn); } }\n'
                '@keyframes fade { to { opacity: 0; } }\n'
                '$_scope .ph { font-family: "UsedFont", serif; animation: spin 1s; }\n'
                '$_scope .gone { font-family: DeadFont; animation: fade 1s; }',
          ),
        ),
      );
      expect(css, contains('UUUU'));
      expect(css, isNot(contains('DDDD')));
      expect(css, contains('@keyframes spin'));
      expect(css, isNot(contains('@keyframes fade')));
    });

    test('@font-face 被释义正文的内联样式 / <font face> 引用时保留', () {
      // MDX 词典的 HTML 释义常直接写内联 font-family（音标字体）而不经 styles.css 规则。
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<span style="font-family: \'Phonetic\'">x</span><font face="Kana">y</font>',
            '@font-face { font-family: "Phonetic"; src: url(data:font/woff2;base64,PPPP); }\n'
                '@font-face { font-family: Kana; src: url(data:font/woff2;base64,KKKK); }\n'
                '@font-face { font-family: Dead; src: url(data:font/woff2;base64,DDDD); }',
          ),
        ),
      );
      expect(css, contains('PPPP'));
      expect(css, contains('KKKK'));
      expect(css, isNot(contains('DDDD')));
    });

    test('去注释、压空白，但字符串内容逐字保留', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<span class="q">x</span>',
            '/* license header\n   many lines */\n'
                '$_scope   .q   {\n  content:  "a  /* not a comment */  b" ;\n  color : red ;\n}\n',
          ),
        ),
      );
      expect(css, isNot(contains('license')));
      expect(css, contains('content: "a  /* not a comment */  b";'));
      expect(css, isNot(contains('\n')));
    });

    test('popup.js 格式化在未加引号的 data URI 里插进的空格被收回', () {
      // popup.js 把 `;` 统一改成 `; `，`url(data:image/png;base64,…)` 变成
      // `url(data:image/png; base64,…)`——未加引号的 url 里有空白即非法声明，图标不显示。
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary(
            '<span class="k">x</span>',
            '$_scope .k { background-image: url(data:image/png; base64,QUJD); }',
          ),
        ),
      );
      expect(css, contains('url(data:image/png;base64,QUJD)'));
    });

    test('不认识的选择器语法按命中处理，整条保留', () {
      final String css = _styleOf(
        slimAnkiGlossaryHtml(
          _glossary('<b>x</b>', '$_scope [data-x="1" i] { color: red; }\n'),
        ),
      );
      expect(css, contains('[data-x="1" i]{color: red;}'));
    });

    test('同一段 HTML 里裁完相同的 <style> 只留一份；裁空的 <style> 整个去掉', () {
      const String rule = '.yomitan-glossary .x { color: red; }';
      final String html =
          '<div class="yomitan-glossary"><span class="x">a</span>'
          '<style>$rule</style><style>/* c */ $rule</style>'
          '<style>.yomitan-glossary .none { color: blue; }</style></div>';
      final String out = slimAnkiGlossaryHtml(html);
      expect('<style>'.allMatches(out), hasLength(1));
      expect(out, contains('<style>.yomitan-glossary .x{color: red;}</style>'));
    });
  });

  group('真实落卡路径：典型多词典卡体积（renderMediaPayload）', () {
    // 三本 styles.css 很大的词典：每本 ~100 KB，绝大部分是本条用不到的规则，
    // 每条都背着 data URI（牛津的形态），外加 hover 态、注释和一份没用到的内嵌字体。
    String bigDictCss(String dict) {
      final String scope = '.yomitan-glossary [data-dictionary="$dict"]';
      final String dataUri = 'data:image/svg+xml;base64,${'PHN2Zz4' * 60}';
      final StringBuffer b = StringBuffer()
        ..writeln('/* $dict stylesheet, exported from the original app */')
        ..writeln(
          '@font-face { font-family: "${dict}Glyphs"; '
          'src: url(data:font/woff2;base64,${'AAAA' * 2000}); }',
        );
      for (int i = 0; i < 220; i++) {
        b
          ..writeln('/* component $i */')
          ..writeln(
            '$scope [data-sc-content="part-$i"] {\n'
            '    background-image: url($dataUri);\n'
            '    margin: 0 0.25em;\n}',
          )
          ..writeln(
            '$scope [data-sc-content="part-$i"]:hover { '
            'background-image: url($dataUri); }',
          );
      }
      b.writeln(
        '$scope .glyph { font-family: "${dict}Glyphs"; }',
      ); // 本条没有 .glyph
      return b.toString();
    }

    String body(String dict) =>
        '<div><span data-sc-content="part-1">$dict 1</span>'
        '<span data-sc-content="part-2">$dict 2</span>'
        '<ol><li>sense a</li><li>sense b</li></ol></div>';

    String singleFor(String dict) =>
        '<div style="text-align: left;" class="yomitan-glossary"><ol>'
        '<li data-dictionary="$dict"><i>($dict)</i> <span>${body(dict)}</span></li>'
        '</ol><style>${bigDictCss(dict)}</style></div>';

    const List<String> dicts = <String>[
      'OALDPE En-Cn 精装版 V2025.02.14',
      '明鏡国語辞典 第三版',
      'Jitendex.org [2026-03-05]',
    ];
    final Map<String, String> singles = <String, String>{
      for (final String d in dicts) d: singleFor(d),
    };
    final String glossary =
        '<div style="text-align: left;" class="yomitan-glossary"><ol>'
        '${dicts.map((String d) => '<li data-dictionary="$d"><i>($d)</i> <span>${body(d)}</span></li>').join()}'
        '</ol>${dicts.map((String d) => '<style>${bigDictCss(d)}</style>').join()}</div>';
    final AnkiMiningPayload payload = AnkiMiningPayload(
      expression: '走る',
      reading: 'はしる',
      glossary: glossary,
      glossaryFirst: singles[dicts.first]!,
      singleGlossaries: singles,
    );
    // Lapis 出厂把 MainDefinition 映射到 {glossary-first}、Glossary 映射到 {glossary}。
    const Map<String, String> mappings = <String, String>{
      'Expression': '{expression}',
      'MainDefinition': '{glossary-first}',
      'Glossary': '{glossary}',
      'Extra': '{glossary-first-2}',
    };
    final _RenderPathRepo repo = _RenderPathRepo();

    test('字段总大小有上限（改前约 1 MB，挂在 AnkiDroid 预览的 Binder 上）', () {
      final int before = <String>[
        glossary,
        singles[dicts.first]!,
        singles[dicts[0]]! + singles[dicts[1]]!,
      ].fold(0, (int a, String s) => a + _bytes(s));
      expect(before, greaterThan(900 * 1024), reason: '夹具要真的大');

      final Map<String, String> fields = repo.renderFor(
        settings: AnkiSettings(fieldMappings: mappings),
        payload: payload,
      );
      final int total = fields.values.fold(
        0,
        (int a, String s) => a + _bytes(s),
      );
      expect(total, lessThan(16 * 1024), reason: 'fields: ${fields.keys}');
      // 本条用到的规则和它们的 data URI 都还在。
      for (final String d in dicts) {
        expect(
          fields['Glossary'],
          contains('[data-dictionary="$d"] [data-sc-content="part-1"]'),
        );
        expect(
          fields['Glossary'],
          contains('[data-dictionary="$d"] [data-sc-content="part-2"]'),
        );
      }
      expect(fields['Glossary'], contains('data:image/svg+xml;base64,'));
      // 本条用不到的：其余组件、hover 态、没被引用的字体、注释。
      expect(fields['Glossary'], isNot(contains('part-3"')));
      // hover 态只留本条元素的（part-1 / part-2），其余组件的不带。
      expect(fields['Glossary'], contains('[data-sc-content="part-1"]:hover'));
      expect(fields['Glossary'], isNot(contains('part-5"]:hover')));
      expect(fields['Glossary'], isNot(contains('@font-face')));
      expect(fields['Glossary'], isNot(contains('/*')));
    });

    test('每个字段里同一本词典的 CSS 只出现一次，正文不受影响', () {
      final Map<String, String> fields = repo.renderFor(
        settings: AnkiSettings(fieldMappings: mappings),
        payload: payload,
      );
      for (final MapEntry<String, String> e in fields.entries) {
        final List<String> blocks = RegExp(
          r'<style>([\s\S]*?)</style>',
        ).allMatches(e.value).map((Match m) => m.group(1)!).toList();
        expect(blocks.toSet(), hasLength(blocks.length), reason: e.key);
        for (final String d in dicts) {
          // 只数基础规则（`…"part-1"]{`）；同一元素的 hover 态是另一条规则。
          final int rules = '[data-dictionary="$d"] [data-sc-content="part-1"]{'
              .allMatches(e.value)
              .length;
          expect(rules, lessThanOrEqualTo(1), reason: '${e.key} / $d');
        }
      }
      // 释义正文逐字保留：去掉 <style> 后与原文一致。
      String stripStyles(String s) =>
          s.replaceAll(RegExp(r'<style>[\s\S]*?</style>'), '');
      expect(stripStyles(fields['Glossary']!), stripStyles(glossary));
      expect(
        stripStyles(fields['MainDefinition']!),
        stripStyles(singles[dicts.first]!),
      );
    });
  });
}
