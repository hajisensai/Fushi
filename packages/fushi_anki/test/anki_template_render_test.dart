// 预览渲染器（mustache 子集）的守卫。
//
// 它只服务编辑器预览：拿**用户自己的模板**渲染示例数据，这样预览的结构天然与
// 真卡一致，不再有「手写 mock 与真实模板漂开」那一整类问题。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

void main() {
  group('renderAnkiTemplate', () {
    test('变量替换；未知字段渲染成空（与 Anki 一致）', () {
      expect(
        renderAnkiTemplate('<b>{{A}}</b>{{B}}', <String, String>{'A': '甲'}),
        '<b>甲</b>',
      );
    });

    test('非空段与空段', () {
      const String tpl = '{{#P}}[有:{{P}}]{{/P}}{{^P}}[无]{{/P}}';
      expect(renderAnkiTemplate(tpl, <String, String>{'P': 'x'}), '[有:x]');
      expect(renderAnkiTemplate(tpl, <String, String>{'P': ''}), '[无]');
      expect(renderAnkiTemplate(tpl, <String, String>{}), '[无]');
      // 只有空白也算空——Anki 的判据同样是「去空白后为空」。
      expect(renderAnkiTemplate(tpl, <String, String>{'P': '   '}), '[无]');
    });

    test('段可以嵌套，内层不输出时外层文本照旧', () {
      const String tpl = '{{#A}}A{{#B}}B{{/B}}A2{{/A}}';
      expect(
        renderAnkiTemplate(tpl, <String, String>{'A': '1', 'B': ''}),
        'AA2',
      );
      expect(
        renderAnkiTemplate(tpl, <String, String>{'A': '1', 'B': '1'}),
        'ABA2',
      );
      expect(renderAnkiTemplate(tpl, <String, String>{'B': '1'}), '');
    });

    test('过滤器前缀取最后一段字段名', () {
      expect(
        renderAnkiTemplate(
          '{{furigana:Sentence}}|{{kana:kanji:Expression}}',
          <String, String>{'Sentence': 'S', 'Expression': 'E'},
        ),
        'S|E',
      );
    });

    test('FrontSide 不展开（背面预览不嵌正面）', () {
      expect(
        renderAnkiTemplate('x{{FrontSide}}y', <String, String>{}),
        'xy',
      );
    });

    test('标签不配对不抛错，尽量把卡画出来', () {
      // 预览的职责是把他的卡画出来，不是校验模板。
      expect(
        renderAnkiTemplate('{{#A}}未闭合', <String, String>{'A': '1'}),
        '未闭合',
      );
      expect(
        () => renderAnkiTemplate('{{/A}}多余闭合', <String, String>{}),
        returnsNormally,
      );
    });

    test('引用字段清单剔除控制符与 FrontSide', () {
      final Set<String> names = ankiTemplateReferencedFields(
        '{{#Picture}}{{furigana:Sentence}}{{/Picture}}{{FrontSide}}{{^X}}{{/X}}',
      );
      expect(names, containsAll(<String>['Picture', 'Sentence', 'X']));
      expect(names, isNot(contains('FrontSide')));
      expect(names.any((String n) => n.startsWith('#')), isFalse);
      expect(names.any((String n) => n.startsWith('/')), isFalse);
    });
  });

  group('用真实 Lapis 模板渲染预览', () {
    test('背面渲染出真卡的关键结构，且不残留 mustache', () {
      final String html = renderLapisPreviewSide(
        template: LapisNoteType.back,
      );
      for (final String anchor in <String>[
        'class="def-header"',
        'class="vocab"',
        'class="pitch"',
        'class="sentence"',
        'class="main-def"',
        'id="glossaries"',
      ]) {
        expect(html, contains(anchor), reason: '预览缺少真卡结构 $anchor');
      }
      expect(html, contains('食べる'));
      // 渲染完不该还剩模板语法。
      expect(html, isNot(contains('{{')));
      expect(html, isNot(contains('}}')));
    });

    test('正面渲染同样不残留 mustache', () {
      final String html = renderLapisPreviewSide(
        template: LapisNoteType.front,
      );
      expect(html, isNot(contains('{{')));
      expect(html, contains('食べる'));
    });

    test('用户自己的模板照他的结构渲染，不套用内置那份', () {
      const String userBack = '<div id="lapis"><main>'
          '<div class="mine">{{Expression}} / {{Sentence}}</div>'
          '</main></div>';
      final String html = renderLapisPreviewSide(template: userBack);
      expect(html, contains('class="mine"'));
      expect(html, contains('食べる / 私は毎朝パンを食べる。'));
      expect(html, isNot(contains('def-header')));
    });

    test('自定义区域插进渲染结果并保留可点选锚点', () {
      final String html = renderLapisPreviewSide(
        template: LapisNoteType.back,
        blocks: const <LapisCustomBlock>[
          LapisCustomBlock(
            id: 'b1',
            anchor: LapisBlockAnchor.bottom,
            fields: <String>['Frequency'],
          ),
        ],
      );
      expect(html, contains('data-hibiki-block="b1"'));
      // 区域里的字段同样被渲染成示例值，而不是留着 handlebar。
      expect(html, contains('1320'));
      expect(html, isNot(contains('{{Frequency}}')));
    });

    test('模板引用的冷门字段回落成字段名，位置仍然可见', () {
      const String tpl = '<div>{{SomeUnknownField}}</div>';
      expect(
        renderLapisPreviewSide(template: tpl),
        contains('SomeUnknownField'),
      );
    });
  });

  group('点选标记脚本', () {
    test('每个可视字段的 selector 都进了脚本，且来自真相源', () {
      final String script = buildLapisPreviewTargetScript();
      for (final LapisVisualField field in LapisVisualField.values) {
        expect(script, contains('"${field.wireName}"'));
        // selector 逐字面量对齐 lapisVisualSelector——预览可点选的东西与样式
        // 实际作用的东西按定义一致，不可能再漂。
        expect(
          script,
          contains(jsonEscaped(lapisVisualSelector(field))),
          reason: '${field.wireName} 的 selector 与真相源不一致',
        );
      }
      expect(script, contains('querySelectorAll'));
      // 重打前先清空，否则布局变化后残留标记会让不存在的位置继续可点。
      expect(script, contains('removeAttribute'));
      // 自定义区域的目标名与 Dart 侧同一套前缀。
      expect(script, contains("'block-'"));
      expect(lapisPreviewBlockTarget('b1'), 'block-b1');
    });
  });
}

/// selector 里含引号时 jsonEncode 会转义，断言得按同样规则比对。
String jsonEscaped(String value) {
  final String encoded = const JsonEncoder().convert(value);
  return encoded.substring(1, encoded.length - 1);
}
