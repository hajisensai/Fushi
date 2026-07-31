import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

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
            'data-hibiki-lapis-targets="[^"]*'
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
          'data-hibiki-lapis-targets='
          '"primary-definition definition-content"',
        ),
      );
      expect(
        html,
        contains(
          'window.hibikiLapisEditor.selectField("primary-definition")',
        ),
      );
      expect(
        html,
        contains('window.hibikiLapisEditor.showSide("back")'),
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
