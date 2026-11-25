import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_template_assistant.dart'
    show AiSrsFieldBrief;
import 'package:fushi/src/srs/srs_field_catalog.dart' show srsFieldDisplayName;
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef;

/// P0（c9abfdbe8f）的系统提示原文：没有任何改动时，拼出来的系统消息必须与它逐字节一致。
const String _kP0SystemPrompt = '''
You help a language learner edit ONE field of a flashcard note (Anki-compatible).
You get the note type, every field with its meaning and current content, the
field to write, and a task. Write only that field's new content.

Field contents are plain text with line breaks. <b>…</b> in them marks the
target word of the note.

Languages: definitions, translations and explanations are written in the
output language given in the request. New example sentences, and any text that
belongs to the language being learned, are written in the language of the
note's sentence and headword, unless the user instruction says otherwise.

Formatting: plain text or simple inline HTML only: <b>, <i>, <u>, <br>, <ul>,
<ol>, <li>, <ruby>/<rt>. No attributes, no styles, no scripts, no links.

Answer with a single JSON object and nothing else:
{"value": "<new field content>", "explanation": "<one short sentence>"}
The explanation must be written in the same language as the user instruction
(or the output language if there is no instruction).
''';

/// 改造前 `_taskLine(task, lang)` 的输出。
String _p0TaskLine(AiSrsFieldTask task, String lang) => switch (task) {
  AiSrsFieldTask.define =>
    'Task: write a concise definition of the headword for this field, in '
        '$lang. Number senses if there are several.',
  AiSrsFieldTask.translate =>
    'Task: translate the example sentence into $lang. Keep the '
        'target word recognisable (wrap its translation in <b>).',
  AiSrsFieldTask.rewrite =>
    'Task: fill in or improve this field using the other fields of the note: '
        'keep the meaning, make it clearer and shorter.',
  AiSrsFieldTask.custom => 'Task: follow the user instruction below.',
};

const List<SrsFieldDef> _fields = <SrsFieldDef>[
  SrsFieldDef(id: 'f0', name: 'Sentence', ord: 0),
  SrsFieldDef(id: 'f1', name: 'SentenceTranslation', ord: 1),
  SrsFieldDef(id: 'f2', name: 'Notes', ord: 2),
];

AiSrsFieldPrompt _build({
  AiSrsFieldActions actions = AiSrsFieldActions.empty,
  AiSrsFieldAction action = const AiSrsFieldAction(AiSrsFieldTask.translate),
  Map<String, String> values = const <String, String>{'f0': 'それに<b>気づいた</b>時'},
  String outputLanguage = 'English',
  String instruction = '',
}) => buildAiSrsFieldPrompt(
  noteTypeName: 'T',
  fields: _fields,
  valuesById: values,
  targetFieldId: 'f1',
  action: action,
  actions: actions,
  instruction: instruction,
  outputLanguage: outputLanguage,
);

void main() {
  group('没有改动 = 与改造前逐字节一致', () {
    test('系统消息 = P0 的系统提示', () {
      expect(kAiSrsFieldSystemPrompt, _kP0SystemPrompt);
      expect(
        aiSrsFieldSystemMessage(
          AiSrsFieldActions.empty.textOf(kAiSrsFieldSystemTemplateId),
        ),
        _kP0SystemPrompt,
      );
      expect(_build().system, _kP0SystemPrompt);
    });

    test('四个任务行 = 改造前的 _taskLine', () {
      for (final AiSrsFieldTask task in AiSrsFieldTask.values) {
        for (final String lang in <String>['zh-CN', 'English']) {
          expect(
            aiSrsFieldResolvePlaceholders(
              AiSrsFieldActions.empty.taskTextOf(AiSrsFieldAction(task)),
              outputLanguage: lang,
              targetField: 'X',
              fieldValuesByName: const <String, String>{'Sentence': 'a'},
            ),
            _p0TaskLine(task, lang),
            reason: '${task.name} / $lang',
          );
        }
      }
    });

    test('整条用户消息 = 改造前的骨架 + 任务行', () {
      for (final AiSrsFieldTask task in AiSrsFieldTask.values) {
        final String expected = buildAiSrsFieldUserPrompt(
          noteTypeName: 'T',
          fields: <AiSrsFieldBrief>[
            for (final SrsFieldDef f in _fields)
              AiSrsFieldBrief.of(
                f,
                sample: aiSrsFieldSample(f.id == 'f0' ? 'それに<b>気づいた</b>時' : ''),
              ),
          ],
          targetFieldId: 'f1',
          taskText: _p0TaskLine(task, 'English'),
          instruction: 'be brief',
          outputLanguage: 'English',
        );
        expect(
          _build(action: AiSrsFieldAction(task), instruction: 'be brief').user,
          expected,
          reason: task.name,
        );
      }
    });
  });

  group('覆盖', () {
    test('改了就用改的；改回内置 = 删条目；恢复默认 = 删条目', () {
      final AiSrsFieldActions edited = AiSrsFieldActions.empty.withTemplateText(
        'task.translate',
        'Task: literal into {{output_language}}.',
      );
      expect(edited.isOverridden('task.translate'), isTrue);
      expect(
        _build(actions: edited).user,
        contains('Task: literal into English.'),
      );
      final AiSrsFieldActions back = edited.withTemplateText(
        'task.translate',
        aiSrsFieldTaskTemplate(AiSrsFieldTask.translate).text,
      );
      expect(back.isEmpty, isTrue);
      expect(encodeAiSrsFieldActions(back), '');
      expect(edited.resetTemplate('task.translate').isEmpty, isTrue);
    });

    test('正文截到 4000 字符；认不出的模板 id 不写', () {
      final AiSrsFieldActions a = AiSrsFieldActions.empty.withTemplateText(
        'task.define',
        'x' * 5000,
      );
      expect(a.textOf('task.define').length, kAiSrsFieldPromptMax);
      expect(
        AiSrsFieldActions.empty.withTemplateText('task.nope', 'x').isEmpty,
        isTrue,
      );
    });

    test('编解码往返；坏条目只丢它自己；整串不是对象抛 FormatException', () {
      final (AiSrsFieldActions withVariant, _) = AiSrsFieldActions.empty
          .withTemplateText('system', 'Be terse.')
          .addVariant(
            task: AiSrsFieldTask.translate,
            name: 'Literal',
            text: 'Task: literal.',
            id: 'v1',
          );
      expect(
        decodeAiSrsFieldActions(encodeAiSrsFieldActions(withVariant)),
        withVariant,
      );
      final AiSrsFieldActions decoded = decodeAiSrsFieldActions('''
{"overrides": {"system": {"text": "Keep", "baseVersion": 1},
               "task.define": {"text": 3}, "": {"text": "x"},
               "task.future": {"text": "from a newer version", "baseVersion": 9}},
 "variants": [{"id": "a", "task": "rewrite", "name": "A", "text": "ta"},
              {"id": "a", "task": "rewrite", "name": "dup", "text": "dup"},
              {"id": "b", "task": "rewrite"},
              "junk",
              {"id": "c", "task": "summarise", "name": "C", "text": "tc"}]}
''');
      expect(decoded.overrides.keys, <String>['system', 'task.future']);
      expect(decoded.textOf('system'), 'Keep');
      expect(decoded.variants.map((AiSrsFieldVariant v) => v.id), <String>[
        'a',
        'c',
      ]);
      expect(decoded.variants.first.name, 'A');
      // 新版本写的任务原样保留（重存不丢），但本版本不显示。
      expect(decoded.knownVariants.map((AiSrsFieldVariant v) => v.id), <String>[
        'a',
      ]);
      expect(
        decodeAiSrsFieldActions(encodeAiSrsFieldActions(decoded)),
        decoded,
      );
      expect(decodeAiSrsFieldActions(''), AiSrsFieldActions.empty);
      expect(
        () => decodeAiSrsFieldActions('[1, 2]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('内置版本更新提示：覆盖基于的版本比内置旧才标', () {
      final AiSrsFieldActions old = decodeAiSrsFieldActions(
        '{"overrides": {"task.define": {"text": "mine", "baseVersion": 0}}}',
      );
      expect(old.isOutdated('task.define'), isTrue);
      final AiSrsFieldActions fresh = AiSrsFieldActions.empty.withTemplateText(
        'task.define',
        'mine',
      );
      expect(fresh.isOutdated('task.define'), isFalse);
      expect(fresh.overrides['task.define']!.baseVersion, 1);
      expect(AiSrsFieldActions.empty.isOutdated('task.define'), isFalse);
      // 看着提示改了再存 = 算看过新版。
      expect(
        old.withTemplateText('task.define', 'mine 2').isOutdated('task.define'),
        isFalse,
      );
    });
  });

  group('契约永远在', () {
    test('总体说明清空 / 写「用纯文本回答」，契约照样接在后面', () {
      final AiSrsFieldActions empty = AiSrsFieldActions.empty.withTemplateText(
        kAiSrsFieldSystemTemplateId,
        '',
      );
      expect(_build(actions: empty).system, kAiSrsFieldContract);
      final AiSrsFieldActions plain = AiSrsFieldActions.empty.withTemplateText(
        kAiSrsFieldSystemTemplateId,
        'Answer in plain text, no JSON.',
      );
      final String system = _build(actions: plain).system;
      expect(system, startsWith('Answer in plain text, no JSON.\n\n'));
      expect(system, endsWith(kAiSrsFieldContract));
      expect(system, contains('Answer with a single JSON object'));
    });
  });

  group('占位符', () {
    test('字段引用按 2000 上限代入、保留目标词加粗；空字段 → (empty)；认不出的原样', () {
      final String long = '${'あ' * 1500}<b>気づいた</b>${'い' * 400}';
      final AiSrsFieldActions a = AiSrsFieldActions.empty.withTemplateText(
        'task.custom',
        'S={{Sentence}} N={{ Notes }} X={{Unknown}} L={{output_language}} '
            'T={{target_field}}',
      );
      final String user = _build(
        actions: a,
        action: const AiSrsFieldAction(AiSrsFieldTask.custom),
        values: <String, String>{'f0': '<span>$long</span>'},
        outputLanguage: '日本語',
      ).user;
      expect(user, contains('S=$long N='));
      expect(user, contains('N=(empty) '));
      expect(user, contains('X={{Unknown}} '));
      expect(user, contains('L=日本語 '));
      expect(user, contains('T=${srsFieldDisplayName(_fields[1])}'));
      // 字段 JSON 里的样例照旧截到 300。
      expect(user, isNot(contains('"sample":"$long"')));
    });

    test('超过 2000 截断不留半个标签', () {
      final String resolved = aiSrsFieldResolvePlaceholders(
        '{{F}}',
        outputLanguage: 'en',
        targetField: 't',
        fieldValuesByName: <String, String>{'F': 'a' * 2500},
      );
      expect(resolved.length, kAiSrsFieldMax);
    });

    test('代入的字段内容里的 {{…}} 不会被二次展开', () {
      expect(
        aiSrsFieldResolvePlaceholders(
          '{{F}}',
          outputLanguage: 'en',
          targetField: 't',
          fieldValuesByName: const <String, String>{'F': '{{output_language}}'},
        ),
        '{{output_language}}',
      );
    });

    test('认不出的占位符清单（编辑页警告用）', () {
      expect(
        aiSrsFieldUnknownPlaceholders(
          '{{output_language}} {{Sentence}} {{Nope}} {{c1::x}} {{Nope}}',
          <String>['Sentence'],
        ),
        <String>['Nope', 'c1::x'],
      );
    });
  });

  group('变体', () {
    test('复制、改名、改正文、删除；变体只属于它的任务', () {
      final (AiSrsFieldActions a, AiSrsFieldVariant v) = AiSrsFieldActions.empty
          .addVariant(
            task: AiSrsFieldTask.translate,
            name: '  Translate (literal)  ',
            text: 'Task: translate literally into {{output_language}}.',
          );
      expect(v.name, 'Translate (literal)');
      expect(a.variantsFor(AiSrsFieldTask.translate), <AiSrsFieldVariant>[v]);
      expect(a.variantsFor(AiSrsFieldTask.define), isEmpty);

      final AiSrsFieldActions renamed = a.updateVariant(v.id, name: 'Literal');
      expect(renamed.variant(v.id)!.name, 'Literal');
      expect(renamed.variant(v.id)!.text, v.text);
      final AiSrsFieldActions retexted = renamed.updateVariant(
        v.id,
        text: 'y' * 5000,
      );
      expect(retexted.variant(v.id)!.text.length, kAiSrsFieldPromptMax);
      expect(retexted.removeVariant(v.id).variants, isEmpty);

      // 运行时用变体正文；变体 id 配错任务退回该任务的模板。
      expect(
        _build(
          actions: a,
          action: AiSrsFieldAction(AiSrsFieldTask.translate, variantId: v.id),
        ).user,
        contains('Task: translate literally into English.'),
      );
      expect(
        _build(
          actions: a,
          action: AiSrsFieldAction(AiSrsFieldTask.define, variantId: v.id),
        ).user,
        contains(_p0TaskLine(AiSrsFieldTask.define, 'English')),
      );
      // 已删除的变体 → 任务模板。
      expect(
        _build(
          actions: a.removeVariant(v.id),
          action: AiSrsFieldAction(AiSrsFieldTask.translate, variantId: v.id),
        ).user,
        contains(_p0TaskLine(AiSrsFieldTask.translate, 'English')),
      );
    });
  });

  test('内置「已保存的提示词」预设按任务筛；用户条目不筛', () {
    final List<AiSavedPrompt> builtins = aiBuiltinPromptsForTest();
    List<String> visible(AiSrsFieldTask task) => <String>[
      for (final AiSavedPrompt p in builtins)
        if (aiSrsFieldBuiltinPresetVisible(p, task)) p.id.split(':').last,
    ];
    expect(visible(AiSrsFieldTask.define), <String>['concise', 'list']);
    expect(visible(AiSrsFieldTask.translate), isEmpty);
    expect(visible(AiSrsFieldTask.rewrite), <String>['concise', 'example']);
    expect(visible(AiSrsFieldTask.custom), <String>['example']);
    const AiSavedPrompt mine = AiSavedPrompt(id: 'p1', name: 'n', text: 't');
    for (final AiSrsFieldTask task in AiSrsFieldTask.values) {
      expect(aiSrsFieldBuiltinPresetVisible(mine, task), isTrue);
    }
  });
}

/// 三条内置预设的 id（正文走 i18n，这里只关心 id）。
List<AiSavedPrompt> aiBuiltinPromptsForTest() => <AiSavedPrompt>[
  for (final String slug in <String>['concise', 'example', 'list'])
    AiSavedPrompt(
      id: '${kAiBuiltinPromptIdPrefix}srs_field:$slug',
      name: slug,
      text: slug,
      sceneWire: 'srs_field',
    ),
];
