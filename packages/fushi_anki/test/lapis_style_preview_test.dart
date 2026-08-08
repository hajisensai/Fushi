import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 只取预览的 DOM 部分（`<body>` 到内联 `<script>` 之前）。整份 html 里还塞着
/// vendored Lapis CSS 与桥接脚本，直接对整份断言会被 CSS 里的 `dict-group` /
/// `data-details` 规则污染成假绿。
String _previewMarkup(String html) {
  final int start = html.indexOf('<body');
  final int end = html.indexOf('<script>', start);
  expect(start, greaterThanOrEqualTo(0));
  expect(end, greaterThan(start));
  return html.substring(start, end);
}

void main() {
  group('buildLapisStylePreviewHtml', () {
    test('正反面预览暴露全部可选字段并接通点击回传', () {
      final String html = buildLapisStylePreviewHtml(
        css: LapisNoteType.template.css,
        selectedField: LapisVisualField.primaryDefinition,
        showBack: true,
        darkMode: false,
      );

      for (final LapisVisualField field in LapisVisualField.values) {
        expect(
          RegExp(
            'data-fushi-lapis-targets="[^"]*'
            '${RegExp.escape(field.wireName)}[^"]*"',
          ).hasMatch(html),
          isTrue,
          reason: '预览缺少 ${field.wireName} 的可点击目标',
        );
      }
      expect(html, contains("callHandler('selectLapisVisualField', field)"));
      expect(html, contains('candidates.indexOf'));
      expect(html, contains('selectedIndex + 1'));
      expect(
        html,
        contains(
          'data-fushi-lapis-targets='
          '"primary-definition definition-content"',
        ),
      );
      expect(
        html,
        contains(
          'window.fushiLapisEditor.selectField("primary-definition")',
        ),
      );
      expect(
        html,
        contains('window.fushiLapisEditor.showSide("back")'),
      );
      expect(html, contains('<body class="card card1">'));
    });

    test('释义示例复刻 popup.js 的真实产物结构，不再是自造 mock', () {
      final String html = buildLapisStylePreviewHtml(
        css: LapisNoteType.template.css,
        selectedField: LapisVisualField.dictionaryEntry,
        showBack: true,
        darkMode: false,
      );

      // 只看 DOM 部分：注入的 vendored Lapis CSS 自带 dict-group / data-details
      // 规则（服务 JPMN 导入卡），拿整份 html 断言等于没断言。
      final String markup = _previewMarkup(html);

      // popup.js constructGlossaryHtml 恒产出
      // `div.yomitan-glossary > ol > li[data-dictionary] > (i + span)`。
      // 预览若偏离这个形状，用户在编辑器里看到的效果就与真卡不一致。
      expect(markup, contains('<div class="yomitan-glossary"'));
      expect(markup, contains('<ol>'));
      expect(markup, contains('<li data-dictionary='));
      // 这些是 vendored Lapis 为 JPMN 导入卡准备的锚点 / 旧 mock 的自造类名，
      // Hibiki 自产卡从不产出；预览里出现它们就会重新养出假 selector。
      expect(markup, isNot(contains('data-details=')));
      expect(markup, isNot(contains('dict-group')));
      expect(markup, isNot(contains('data-sc-content="example"')));
      expect(markup, contains('data-sc-content="example-sentence"'));
      for (final LapisVisualField field in LapisVisualField.values) {
        expect(
          lapisVisualSelector(field),
          isNot(contains('明鏡')),
          reason: '${field.wireName} 的 selector 绑死了具体词典名',
        );
        expect(
          lapisVisualSelector(field),
          isNot(contains('JMdict')),
          reason: '${field.wireName} 的 selector 绑死了具体词典名',
        );
      }
    });

    test('预览携带每个可视字段 selector 所依赖的真实锚点', () {
      final String markup = _previewMarkup(
        buildLapisStylePreviewHtml(
          css: LapisNoteType.template.css,
          selectedField: LapisVisualField.expression,
          showBack: true,
          darkMode: false,
        ),
      );
      // 字段 → 该字段 selector 在真卡上依赖、预览里必须同样存在的 HTML 片段。
      // 缺一条就说明预览与 selector 已经漂开（= 预览有效果、真机没反应）。
      const Map<LapisVisualField, List<String>> anchors =
          <LapisVisualField, List<String>>{
        LapisVisualField.expression: <String>[
          'class="front-vocab"',
          'class="vocab"',
        ],
        LapisVisualField.reading: <String>['class="pitch"'],
        LapisVisualField.sentence: <String>['id="hint"', 'class="sentence"'],
        LapisVisualField.definitionInfo: <String>['class="def-info"'],
        LapisVisualField.definitionBox: <String>['class="main-def"'],
        LapisVisualField.definitionContent: <String>['class="definition"'],
        LapisVisualField.selectedDefinition: <String>['id="selection"'],
        LapisVisualField.primaryDefinition: <String>['id="primary"'],
        LapisVisualField.glossaries: <String>['id="glossaries"'],
        LapisVisualField.dictionaryEntry: <String>['<li data-dictionary='],
        LapisVisualField.dictionaryName: <String>['<i data-hibiki-lapis-'],
        LapisVisualField.definitionExample: <String>[
          'data-sc-content="example-sentence"',
        ],
      };
      expect(anchors.keys.toSet(), LapisVisualField.values.toSet());
      for (final MapEntry<LapisVisualField, List<String>> entry
          in anchors.entries) {
        for (final String anchor in entry.value) {
          expect(
            markup,
            contains(anchor),
            reason: '预览缺少 ${entry.key.wireName} 依赖的锚点 $anchor',
          );
        }
      }
    });

    test('预览携带布局切换需要的备用位置元素', () {
      final String markup = _previewMarkup(
        buildLapisStylePreviewHtml(
          css: LapisNoteType.template.css,
          selectedField: LapisVisualField.sentence,
          showBack: true,
          darkMode: false,
        ),
      );
      // vendored Lapis 的位置切换全靠「两处 DOM + 显隐互换」：例句有
      // .sentence/.sentence-alt，图片有 .image/.image-alt，音频有
      // .audio-buttons/.audio-buttons-alt。备用那半边缺一个，改到对应位置时
      // 预览就是一片空白 —— 用户会以为设置坏了。
      for (final String anchor in <String>[
        'class="sentence"',
        'class="sentence-alt"',
        'class="image"',
        'class="image-alt"',
        'class="audio-buttons"',
        'class="audio-buttons-alt"',
      ]) {
        expect(markup, contains(anchor), reason: '预览缺少 $anchor');
      }
      // 例句挪到备用位置后仍要能被选中改样式。
      expect(
        markup,
        contains('class="sentence-alt" data-fushi-lapis-targets="sentence"'),
      );
    });

    test('预览按真卡同一套判据把布局变量翻成 data 属性', () {
      final String html = buildLapisStylePreviewHtml(
        css: LapisNoteType.template.css,
        selectedField: LapisVisualField.expression,
        showBack: true,
        darkMode: false,
      );
      // 注入 CSS 后必须重跑一次，否则改了位置预览纹丝不动。
      expect(html, contains('window.fushiLapisEditor.applyLayout();'));
      expect(html, contains("setAttribute('data-' + opt.slice(2), value)"));

      // 预览读的变量必须是真卡 userSettings() 也读的那些；漂开就等于预览
      // 和真卡两套布局语义。
      final RegExp option = RegExp(r"'(--[a-z-]+)'");
      final Iterable<String> options =
          option.allMatches(html).map((RegExpMatch m) => m.group(1)!).toSet();
      expect(options, contains('--sentence-position'));
      expect(options, contains('--main-picture-position'));
      expect(options, contains('--audio-buttons'));
      for (final String name in options) {
        expect(
          LapisNoteType.back,
          contains('"$name"'),
          reason: '$name 不在真卡 userSettings() 的读取清单里',
        );
      }
    });

    test('刷新脚本按同一顺序重放布局', () {
      final String script = buildLapisStylePreviewRefreshScript(
        css: '.x { color: red; }',
        selectedField: LapisVisualField.sentence,
        showBack: false,
      );
      // 编辑器每次改动只走这段脚本，不重载页面。漏掉 applyLayout，改区块位置
      // 就要重新打开编辑器才看得到效果；顺序反了则读到旧 CSS 的变量。
      final int css = script.indexOf("getElementById('lapis-style')");
      final int layout = script.indexOf('applyLayout()');
      final int side = script.indexOf('showSide(');
      final int select = script.indexOf('selectField(');
      expect(css, greaterThanOrEqualTo(0));
      expect(layout, greaterThan(css));
      expect(side, greaterThan(layout));
      expect(select, greaterThan(side));
      expect(script, contains('"front"'));
      expect(script, contains('"sentence"'));
    });

    test('刷新脚本也走 JSON 转义，CSS 不能逃逸成脚本', () {
      final String script = buildLapisStylePreviewRefreshScript(
        css: '</style><script>window.bad = true;</script>',
        selectedField: LapisVisualField.expression,
        showBack: true,
      );
      expect(script, isNot(contains('<script>window.bad')));
      expect(script, contains(r'\u003Cscript>window.bad'));
    });

    test('CSS 通过 textContent 注入，style/script 结束标签不能逃逸', () {
      const String hostile =
          'body { color: red; }</style><script>window.bad = true;</script>';
      final String html = buildLapisStylePreviewHtml(
        css: hostile,
        selectedField: LapisVisualField.expression,
        showBack: false,
        darkMode: true,
      );

      expect(html, isNot(contains(hostile)));
      expect(html, contains(r'\u003C/style>'));
      expect(html, contains(r'\u003Cscript>window.bad = true;'));
      expect(html, contains('<html class="nightMode">'));
      expect(html, contains('<body class="card card1 nightMode">'));
    });
  });
}
