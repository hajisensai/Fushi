// 模板预览的字段占位值：字段名是不可信文本，作为字段内容进卡面 HTML 前必须转义。
// 模板编辑器（没有笔记时的 `(字段名)`）与字段说明页（高亮预览）共用 srsFieldPlaceholderHtml。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_info_page.dart'
    show srsFieldSpotlightValues;
import 'package:fushi/src/pages/implementations/srs/srs_template_editor_page.dart'
    show srsFieldPlaceholderHtml, srsRenderTemplatePreview;
import 'package:fushi_srs/fushi_srs.dart';

const String _evil = '<img src=x onerror="alert(1)">&b';

SrsNoteTypeView _type() => SrsNoteTypeView(
  id: 'nt',
  ankiNum: 1,
  kind: SrsNoteTypeKind.standard,
  name: 'Imported',
  fields: const <SrsFieldDef>[
    SrsFieldDef(id: 'f1', name: _evil, ord: 0),
    SrsFieldDef(id: 'f2', name: 'Back', ord: 1),
  ],
  templates: const <SrsTemplateDef>[],
  css: '',
  termFieldId: null,
  deletedAt: null,
  builtinKey: null,
  edits: SrsEntityEdits(<String, SrsRegister>{}),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('占位值把字段名转义成纯文本', () {
    expect(
      srsFieldPlaceholderHtml(_evil),
      '(&lt;img src=x onerror="alert(1)"&gt;&amp;b)',
    );
    expect(srsFieldPlaceholderHtml('Front'), '(Front)');
  });

  test('模板编辑器预览：没有样例时按占位值渲染，卡面里不出现可执行的标签', () {
    final String html = srsRenderTemplatePreview(
      front: '{{$_evil}}',
      back: '{{FrontSide}}<hr>{{Back}}',
      fieldsByName: <String, String>{
        _evil: srsFieldPlaceholderHtml(_evil),
        'Back': srsFieldPlaceholderHtml('Back'),
      },
      isCloze: false,
      cardOrd: 0,
    ).card!.question;
    expect(html, isNot(contains('<img')));
    expect(html, contains('&lt;img'));
  });

  test('字段说明页高亮预览：别的字段与本字段（无样例、非内置）的占位都转义', () {
    final SrsNoteTypeView type = _type();
    final Map<String, String> asOther = srsFieldSpotlightValues(
      type: type,
      fieldId: 'f2',
      sampleById: const <String, String>{},
    );
    expect(asOther[_evil], isNot(contains('<img')));
    expect(asOther[_evil], contains('&lt;img'));

    final Map<String, String> asSelf = srsFieldSpotlightValues(
      type: type,
      fieldId: 'f1',
      sampleById: const <String, String>{},
    );
    expect(asSelf[_evil], contains('data-fushi-field-spot'));
    expect(asSelf[_evil], isNot(contains('<img')));
    expect(asSelf[_evil], contains('&lt;img'));
  });
}
