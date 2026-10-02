import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

AnkiNoteTypeDefinition _def(String front, String back) =>
    AnkiNoteTypeDefinition(
      name: 'Custom',
      fields: const <String>['Expression', 'Picture', 'SentenceAudio'],
      templates: <AnkiCardTemplate>[
        AnkiCardTemplate(name: 'Card 1', front: front, back: back),
      ],
      css: '',
    );

const Map<String, String> _pictureMapping = <String, String>{
  'Expression': '{expression}',
  'Picture': '{card-image}',
  'SentenceAudio': '{sentence-audio}',
};

bool _renders(
  String back, {
  String front = '{{Expression}}',
  Map<String, String> mappings = _pictureMapping,
}) => noteTypeRendersSynchronizedClip(
  definition: _def(front, back),
  fieldMappings: mappings,
);

void main() {
  test('Fushi 内置 Lapis 原样渲染 Picture → 能承载同步片段', () {
    expect(
      noteTypeRendersSynchronizedClip(
        definition: AnkiNoteTypeDefinition(
          name: LapisNoteType.modelName,
          fields: LapisNoteType.fields,
          templates: const <AnkiCardTemplate>[
            AnkiCardTemplate(
              name: LapisNoteType.cardName,
              front: LapisNoteType.front,
              back: LapisNoteType.back,
            ),
          ],
          css: '',
        ),
        fieldMappings: LapisNoteType.defaultFieldMappings,
      ),
      isTrue,
    );
  });

  // Kiku 的真实结构：外层 <template id="anki-fields"> 里每个字段一个
  // <template data-field>，卡片脚本二次解析时 Picture 只取 <img>。
  test('Kiku 式 <template> 字段 → 不能承载（嵌套 template 也剥干净）', () {
    const String kikuBack = '''
<div id="root"></div>
<template id="anki-fields">
  <template data-field="Expression">{{Expression}}</template>
  <template data-field="SentenceAudio">{{SentenceAudio}}</template>
  <template data-field="Picture">{{Picture}}</template>
</template>
<script type="module">render(document.getElementById("root"));</script>
''';
    expect(_renders(kikuBack, front: kikuBack), isFalse);
  });

  test('上游 Kiku 原版模板（fixtures/kiku）→ 不能承载同步片段', () {
    // Kiku 的字段名与 Lapis 相同，用户按 Lapis 映射配它（LapisPreset.matches 按字段名
    // 认），所以用 Lapis 默认映射喂真实模板。
    expect(
      noteTypeRendersSynchronizedClip(
        definition: AnkiNoteTypeDefinition(
          name: 'Kiku',
          fields: LapisNoteType.fields,
          templates: <AnkiCardTemplate>[
            AnkiCardTemplate(
              name: 'Mining',
              front: File('test/fixtures/kiku/front.html').readAsStringSync(),
              back: File('test/fixtures/kiku/back.html').readAsStringSync(),
            ),
          ],
          css: '',
        ),
        fieldMappings: LapisNoteType.defaultFieldMappings,
      ),
      isFalse,
    );
  });

  test('过滤器 / 条件段 / script / 注释里的引用都不算渲染', () {
    expect(_renders('{{text:Picture}}'), isFalse);
    expect(
      _renders('{{#Picture}}有图{{/Picture}}{{^Picture}}无图{{/Picture}}'),
      isFalse,
    );
    expect(_renders('<script>var p = `{{Picture}}`;</script>'), isFalse);
    expect(_renders('<!-- {{Picture}} -->'), isFalse);
  });

  test('正面或背面任一处裸引用即可；容忍空白', () {
    expect(_renders('<div>{{ Picture }}</div>'), isTrue);
    expect(_renders('{{Expression}}', front: '<div>{{Picture}}</div>'), isTrue);
    expect(
      _renders('<template>{{Picture}}</template><div>{{Picture}}</div>'),
      isTrue,
    );
  });

  test('<template-xxx> 自定义元素不是 template，里面的引用照常渲染', () {
    expect(_renders('<template-card>{{Picture}}</template-card>'), isTrue);
    expect(
      _renders(
        '<template>x</template><template-card>{{Picture}}</template-card>',
      ),
      isTrue,
    );
  });

  test('判据跟随映射：图片映射到别的字段名（含旧别名）就看那个字段', () {
    const Map<String, String> imageField = <String, String>{
      'Image': '{book-cover}',
    };
    expect(_renders('<div>{{Image}}</div>', mappings: imageField), isTrue);
    expect(_renders('<div>{{Picture}}</div>', mappings: imageField), isFalse);
  });

  test('没有字段消费卡片图片 → 不能承载', () {
    expect(
      _renders(
        '<div>{{Picture}}</div>',
        mappings: const <String, String>{'Expression': '{expression}'},
      ),
      isFalse,
    );
  });
}
