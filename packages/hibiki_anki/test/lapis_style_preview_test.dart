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
          html,
          contains('data-hibiki-lapis-field="${field.wireName}"'),
        );
      }
      expect(html, contains("callHandler('selectLapisVisualField', field)"));
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
    });
  });
}
