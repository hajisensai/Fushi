import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

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

    test('复杂释义示例覆盖结构语义，不把规则绑定到具体词典名称', () {
      final String html = buildLapisStylePreviewHtml(
        css: LapisNoteType.template.css,
        selectedField: LapisVisualField.dictionaryEntry,
        showBack: true,
        darkMode: false,
      );

      expect(html, contains('data-dictionary='));
      expect(html, contains('data-details='));
      expect(html, contains('data-sc-content="example-sentence"'));
      expect(html, contains('class="dict-group__tag-list"'));
      expect(
        lapisVisualSelector(LapisVisualField.dictionaryEntry),
        isNot(contains('明鏡')),
      );
      expect(
        lapisVisualSelector(LapisVisualField.dictionaryEntry),
        isNot(contains('JMdict')),
      );
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
