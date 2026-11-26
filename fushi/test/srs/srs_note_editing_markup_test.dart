// 笔记编辑 / 模板编辑的纯函数：富文本扩展子集（高亮）、结构化字段逐段改文字、可视化块的
// 斜体 / 自定义颜色、字段 AI 回复的本地校验。全部不起 widget。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart';
import 'package:fushi/src/pages/implementations/srs/srs_rich_text_controller.dart';
import 'package:fushi/src/srs/srs_field_markup.dart';
import 'package:fushi/src/srs/srs_html_text_parts.dart';
import 'package:fushi/src/srs/srs_rich_format.dart';
import 'package:fushi/src/srs/srs_visual_template.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

const String _kGlossary =
    '<div style="text-align: left;" class="yomitan-glossary"><ol>'
    '<li data-dictionary="大辞林"><i>(大辞林)</i> '
    '<span class="gloss-sc-span" style="font-weight: bold; color: #c00;">かよう</span>'
    '&amp;続ける</li></ol></div>';

void main() {
  group('富文本扩展子集（高亮）', () {
    test('旧子集的序列化逐字节不变', () {
      for (final String html in <String>[
        '毎日<b>図書館</b>に',
        '<i><span style="color: #e53935;">図書館</span></i>',
        'a<br>b&amp;c',
      ]) {
        final SrsRichDoc old = srsParseRichHtml(html)!;
        final SrsRichFormatDoc now = srsParseRichFormatHtml(html)!;
        expect(now.text, old.text);
        expect(
          srsRichFormatToHtml(now.text, now.formats),
          srsRichToHtml(old.text, old.styles),
          reason: html,
        );
      }
    });

    test('<mark> 与 background-color 认成高亮；color 与背景可同一个 span', () {
      final SrsRichFormatDoc mark = srsParseRichFormatHtml('a<mark>bc</mark>')!;
      expect(mark.formats[0].highlight, isNull);
      expect(mark.formats[1].highlight, kSrsHighlightDefault);
      final SrsRichFormatDoc both = srsParseRichFormatHtml(
        '<span style="color: #ff0000; background-color: #c8e6c9;">x</span>',
      )!;
      expect(both.formats.single.color, 0xFFFF0000);
      expect(both.formats.single.highlight, 0xFFC8E6C9);
      expect(
        srsRichFormatToHtml(both.text, both.formats),
        '<span style="color: #ff0000; background-color: #c8e6c9;">x</span>',
      );
      // 子集之外照旧拒绝（class / 别的声明）。
      expect(srsParseRichFormatHtml('<span class="x">a</span>'), isNull);
      expect(
        srsParseRichFormatHtml('<span style="font-weight: bold;">a</span>'),
        isNull,
      );
      expect(srsParseRichFormatHtml(_kGlossary), isNull);
    });

    test('编辑器类型：高亮例句走所见即所得，词典排版 / 图片仍是结构化', () {
      expect(
        srsFieldKindOf('Sentence', '今日は<mark>晴れ</mark>'),
        SrsFieldKind.structured,
        reason: '旧判据把它当结构化（只能改源码）',
      );
      expect(
        srsEditorFieldKindOf('Sentence', '今日は<mark>晴れ</mark>'),
        SrsFieldKind.rich,
      );
      expect(
        srsEditorFieldKindOf('SentenceFurigana', '毎日[まいにち]<mark>通[かよ]う</mark>'),
        SrsFieldKind.furigana,
      );
      expect(
        srsEditorFieldKindOf('MainDefinition', _kGlossary),
        SrsFieldKind.structured,
      );
      expect(
        srsEditorFieldKindOf('Front', '<mark>a</mark><img src="x.png">'),
        SrsFieldKind.structured,
      );
      expect(srsEditorFieldKindOf('Sentence', 'plain'), SrsFieldKind.rich);
    });

    test('控制器：选区加高亮 / 去高亮，没改过原样返回', () {
      final SrsRichTextController c = SrsRichTextController.tryParse(
        '今日は<mark>晴れ</mark>',
      )!;
      expect(c.html, '今日は<mark>晴れ</mark>', reason: '没改过不经序列化');
      c.selection = const TextSelection(baseOffset: 3, extentOffset: 5);
      expect(c.activeHighlight, kSrsHighlightDefault);
      c.setHighlight(null);
      expect(c.html, '今日は晴れ');
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      c.setHighlight(0xFFBBDEFB);
      c.toggle(SrsRichAttr.bold);
      expect(
        c.html,
        '<b><span style="background-color: #bbdefb;">今日</span></b>は晴れ',
      );
      c.dispose();
    });
  });

  group('结构化字段逐段改文字', () {
    test('拆出可见文字；原样拼回逐字节一致', () {
      final SrsHtmlTextParts parts = srsSplitHtmlText(_kGlossary);
      expect(parts.texts, <String>['(大辞林)', 'かよう', '&続ける']);
      expect(parts.join(parts.texts), _kGlossary);
    });

    test('只改一段：其余标签 / 属性 / 实体原样，新文字转义', () {
      final SrsHtmlTextParts parts = srsSplitHtmlText(_kGlossary);
      final String out = parts.join(<String>['(大辞林)', 'かよう<x>', '&続ける']);
      expect(out, _kGlossary.replaceFirst('かよう</span>', 'かよう&lt;x&gt;</span>'));
      expect(out, contains('&amp;続ける'), reason: '没改的段保留原写法');
    });

    test('style / script 内容、注释、纯空白都不算文字；两侧空白留在骨架', () {
      const String html =
          '<style>.a{color:red}</style>\n  <p>  hi  </p><!-- c --><script>x()</script>';
      final SrsHtmlTextParts parts = srsSplitHtmlText(html);
      expect(parts.texts, <String>['hi']);
      expect(
        parts.join(<String>['yo']),
        '<style>.a{color:red}</style>\n  <p>  yo  </p><!-- c --><script>x()</script>',
      );
    });
  });

  group('可视化块：斜体 / 自定义颜色', () {
    const SrsVisualCompileContext ctx = SrsVisualCompileContext(
      fieldNameById: <String, String>{'f1': 'Expression'},
    );

    test('编译进内联样式；颜色压过强调色、与弱化共存', () {
      const SrsVisualBlock b = SrsVisualBlock(
        id: 'b1',
        kind: SrsVisualBlockKind.field,
        fieldId: 'f1',
        italic: true,
        color: '#e53935',
        tone: SrsVisualTone.accent,
      );
      final String html = srsCompileVisualBody(<SrsVisualBlock>[b], ctx);
      expect(html, contains('font-style:italic'));
      expect(html, contains('color:#e53935'));
      expect(html, isNot(contains('--fushi-srs-accent')));
      final String muted = srsCompileVisualBody(<SrsVisualBlock>[
        b.copyWith(tone: SrsVisualTone.muted),
      ], ctx);
      expect(muted, contains('opacity:0.7'));
      expect(muted, contains('color:#e53935'));
    });

    test('持久化往返；清颜色；不认的颜色丢掉（防 CSS 注入）', () {
      const SrsVisualBlock b = SrsVisualBlock(
        id: 'b1',
        kind: SrsVisualBlockKind.text,
        text: 'x',
        italic: true,
        color: '#123abc',
      );
      final SrsVisualBlock back = SrsVisualBlock.fromJson(b.toJson())!;
      expect(back.italic, isTrue);
      expect(back.color, '#123abc');
      expect(b.copyWith(clearColor: true).color, isNull);
      final SrsVisualBlock? evil = SrsVisualBlock.fromJson(<String, Object?>{
        'id': 'b2',
        'k': 'text',
        't': 'x',
        'col': 'red;background:url(x)',
      });
      expect(evil!.color, isNull);
      expect(srsVisualColorOrNull('#ABC'), '#aabbcc');
    });

    test('AI 布局回复里的 italic / color 经同一校验', () {
      final AiSrsTemplateSuggestion s = parseAiSrsTemplateSuggestion(
        '{"front":[{"kind":"field","field":"f1","italic":true,'
        '"color":"#00ff00"},{"kind":"text","text":"t","color":"expression(1)"}]}',
        fields: const <SrsFieldDef>[
          SrsFieldDef(id: 'f1', name: 'Expression', ord: 0),
        ],
        isCloze: false,
      );
      expect(s.front!.first.italic, isTrue);
      expect(s.front!.first.color, '#00ff00');
      expect(s.front![1].color, isNull);
    });
  });

  group('字段 AI 回复的本地校验', () {
    test('白名单标签去属性；脚本 / 样式整段丢；未知标签只留文字', () {
      expect(
        aiSrsSanitizeFieldHtml(
          '<b onclick="x()">食べる</b><script>alert(1)</script>'
          '<a href="javascript:x">link</a><br/><img src=x onerror=y>'
          '<style>b{}</style><ol class="k"><li>1</li></ol>',
        ),
        '<b>食べる</b>link<br><ol><li>1</li></ol>',
      );
    });

    test('解析 value；空值 / 非 JSON 视为失败', () {
      final AiSrsFieldSuggestion s = parseAiSrsFieldSuggestion(
        '```json\n{"value": "to eat <i>(v)</i>", "explanation": "ok"}\n```',
      );
      expect(s.value, 'to eat <i>(v)</i>');
      expect(s.explanation, 'ok');
      expect(
        () => parseAiSrsFieldSuggestion('{"value": "<b></b>"}'),
        throwsA(isA<AiSrsFieldEmpty>()),
      );
      expect(
        () => parseAiSrsFieldSuggestion('sorry'),
        throwsA(isA<AiSrsFieldEmpty>()),
      );
    });

    test('提示词带目标字段与任务', () {
      final String p = buildAiSrsFieldUserPrompt(
        noteTypeName: 'Lapis',
        fields: const <AiSrsFieldBrief>[
          AiSrsFieldBrief(id: 'a', name: 'Sentence', sample: '毎日通う'),
          AiSrsFieldBrief(id: 'b', name: 'SentenceTranslation'),
        ],
        targetFieldId: 'b',
        task: AiSrsFieldTask.translate,
        instruction: '',
        outputLanguage: 'zh-CN',
      );
      expect(p, contains('Field to write: SentenceTranslation'));
      expect(p, contains('translate the example sentence into zh-CN'));
      expect(p, isNot(contains('User instruction')));
    });

    test('每个任务都带输出语言（改写 / 自定义的任务行本身不写语言）', () {
      for (final AiSrsFieldTask task in AiSrsFieldTask.values) {
        final String p = buildAiSrsFieldUserPrompt(
          noteTypeName: 'Lapis',
          fields: const <AiSrsFieldBrief>[],
          targetFieldId: 'b',
          task: task,
          instruction: 'x',
          outputLanguage: 'en',
        );
        expect(p, contains('Output language: en'), reason: task.name);
      }
    });

    test('系统提示写明加粗 = 目标词、新例句用笔记的语言', () {
      final String flat = kAiSrsFieldSystemPrompt.replaceAll('\n', ' ');
      expect(flat, contains('<b>…</b> in them marks the target word'));
      expect(
        flat,
        contains(
          'New example sentences, and any text that belongs to the language '
          "being learned, are written in the language of the note's sentence",
        ),
      );
    });
  });

  group('交给 AI 的字段内容（BUG：目标词标记丢失、标签处多出空格、振假名混入正文）', () {
    test('保留目标词加粗，去掉其余标签时不补空格', () {
      expect(
        aiSrsFieldSample('それに<b>気づいた</b>時 完全に嫌いになった'),
        'それに<b>気づいた</b>時 完全に嫌いになった',
      );
      expect(
        aiSrsFieldSample(
          '<span class="x">毎日</span><strong style="c">通う</strong>',
        ),
        '毎日<b>通う</b>',
      );
    });

    test('振假名读音整段去掉，挖空记成加粗', () {
      expect(
        aiSrsFieldSample('<ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>を書く'),
        '漢字を書く',
      );
      expect(aiSrsFieldSample('{{c1::うっかり::hint}}かあ'), '<b>うっかり</b>かあ');
    });

    test('换行标签变换行；脚本 / 注释丢掉；实体只解不会伪造标签的那几个', () {
      expect(
        aiSrsFieldSample(
          '一行目<br>二行目<div>三</div><!-- c --><script>x</script>'
          'A&nbsp;&amp;&nbsp;B &lt;b&gt;',
        ),
        '一行目\n二行目三\nA & B &lt;b&gt;',
      );
    });

    test('截断不留半个标签、不留没闭合的加粗', () {
      final String s = aiSrsFieldSample('${'あ' * 8}<b>${'い' * 8}</b>', max: 12);
      expect(s, '${'あ' * 8}<b>い</b>');
      expect(aiSrsFieldSample('${'あ' * 10}<b>い</b>', max: 12), 'あ' * 10);
    });

    test('requestAiSrsField 发出去的就是整理后的内容', () async {
      final _CapturingClient client = _CapturingClient();
      addTearDown(client.close);
      await requestAiSrsField(
        client: client,
        provider: AiProviderConfig(
          id: 'p',
          presetId: kAiCustomPresetId,
          name: 'p',
          baseUrl: Uri.parse('https://example.com/v1'),
          apiKey: 'k',
          model: 'm',
          protocol: AiWireProtocol.openAiCompatible,
        ),
        noteType: _noteType(<String>['Sentence', 'SentenceTranslation']),
        valuesById: const <String, String>{'f0': 'それに<b>気づいた</b>時'},
        targetFieldId: 'f1',
        task: AiSrsFieldTask.translate,
        outputLanguage: 'en',
      );
      final String user = client.sent.last.content;
      expect(user, contains(r'それに<b>気づいた</b>時'));
      expect(user, isNot(contains('それに 気づいた 時')));
    });
  });
}

SrsNoteTypeView _noteType(List<String> fieldNames) => SrsNoteTypeView(
  id: 'nt',
  ankiNum: 1,
  kind: SrsNoteTypeKind.standard,
  name: 'T',
  termFieldId: null,
  deletedAt: null,
  edits: SrsEntityEdits(<String, SrsRegister>{}),
  builtinKey: null,
  fields: <SrsFieldDef>[
    for (int i = 0; i < fieldNames.length; i++)
      SrsFieldDef(id: 'f$i', name: fieldNames[i], ord: i),
  ],
  templates: const <SrsTemplateDef>[],
  css: '',
);

class _CapturingClient extends AiChatClient {
  final List<AiChatMessage> sent = <AiChatMessage>[];

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    sent.addAll(messages);
    return '{"value": "When I <b>noticed</b> that", "explanation": "ok"}';
  }
}
