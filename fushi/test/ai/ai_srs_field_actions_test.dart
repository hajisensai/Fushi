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

/// P2 在总体说明末尾加的一段（以笔记的词典字段为准）。
const String _kGrounding = '''
Ground your answer in the note: prefer what its dictionary fields (definition,
glossary) say over your own knowledge, and never invent senses, readings or
facts that the note does not support.''';

/// 当前内置系统提示 = P0 原文在「语言」一段后插入 [_kGrounding]；契约部分逐字节不变。
final String _kDefaultSystemPrompt = _kP0SystemPrompt.replaceFirst(
  'says otherwise.\n\nFormatting',
  'says otherwise.\n\n$_kGrounding\n\nFormatting',
);

/// 内置任务模板代入占位符后的任务行。
String _defaultTaskLine(AiSrsFieldTask task, String lang) =>
    aiSrsFieldResolvePlaceholders(
      aiSrsFieldTaskTemplate(task).text,
      outputLanguage: lang,
      targetField: 'X',
      fieldValuesByName: const <String, String>{},
    );

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
  group('没有改动 = 内置默认', () {
    test('系统消息 = P0 原文 + 「以笔记为准」一段；契约不变', () {
      expect(kAiSrsFieldSystemPrompt, _kDefaultSystemPrompt);
      expect(
        aiSrsFieldSystemMessage(
          AiSrsFieldActions.empty.textOf(kAiSrsFieldSystemTemplateId),
        ),
        _kDefaultSystemPrompt,
      );
      expect(_build().system, _kDefaultSystemPrompt);
      expect(_kDefaultSystemPrompt, contains(_kGrounding));
    });

    test('改过正文的内置模板版本号都加了一（基于旧版改过的用户会看到更新提示）', () {
      int versionOf(String id) => aiSrsFieldTemplateById(id)!.version;
      expect(versionOf(kAiSrsFieldSystemTemplateId), 2);
      expect(versionOf('task.define'), 2);
      expect(versionOf('task.translate'), 2);
      expect(versionOf('task.rewrite'), 2);
      expect(versionOf('task.custom'), 1, reason: '自定义任务正文没变');
      final AiSrsFieldActions basedOnV1 = decodeAiSrsFieldActions(
        '{"overrides": {"task.translate": {"text": "mine", "baseVersion": 1}}}',
      );
      expect(basedOnV1.isOutdated('task.translate'), isTrue);
    });

    test('翻译任务：只译例句、保留语气与残句、句末语气词、中性猜测写进说明、目标词加粗', () {
      final String line = _defaultTaskLine(AiSrsFieldTask.translate, 'English');
      final String flat = line.replaceAll('\n', ' ');
      expect(
        line,
        startsWith("Task: translate the note's example sentence into English."),
      );
      expect(line, isNot(contains('{{')));
      for (final String rule in <String>[
        'Translate only the sentence.',
        'Be faithful first, natural second',
        'Keep fragments, interjections and lines that trail off as they are',
        'Add a missing subject or object only when the sentence needs one.',
        'name the guess in "explanation"',
        'Translate sentence-final particles and drawn-out endings',
        'Wrap the words that translate the target word',
        '"value" holds only the translation',
      ]) {
        expect(flat, contains(rule), reason: rule);
      }
    });

    test('释义任务以词典字段为准、句中义项加粗；改写不许改意思；自定义不变', () {
      final String define = _defaultTaskLine(
        AiSrsFieldTask.define,
        'English',
      ).replaceAll('\n', ' ');
      expect(define, contains('in English.'));
      expect(define, contains('do not invent senses'));
      expect(define, contains("the sense used in the note's sentence first"));
      expect(
        _defaultTaskLine(AiSrsFieldTask.rewrite, 'English'),
        contains('Never change the meaning'),
      );
      expect(
        _defaultTaskLine(AiSrsFieldTask.custom, 'English'),
        'Task: follow the user instruction below.',
      );
    });

    test('两条真实难句：目标词标记原样进用户消息，翻译规则同在一条消息里', () {
      for (final String sentence in <String>[
        'それに<b>気づいた</b>時 完全に嫌いになった',
        '<b>うっかり</b>かあ',
      ]) {
        final AiSrsFieldPrompt p = _build(
          values: <String, String>{'f0': sentence},
        );
        expect(p.user, contains(sentence), reason: sentence);
        expect(p.user, contains('Keep fragments, interjections'));
        expect(p.system, contains('marks the\ntarget word'));
      }
    });

    test('整条用户消息 = 固定骨架 + 内置任务行', () {
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
          taskText: _defaultTaskLine(task, 'English'),
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
      expect(fresh.overrides['task.define']!.baseVersion, 2);
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
        contains(_defaultTaskLine(AiSrsFieldTask.define, 'English')),
      );
      // 已删除的变体 → 任务模板。
      expect(
        _build(
          actions: a.removeVariant(v.id),
          action: AiSrsFieldAction(AiSrsFieldTask.translate, variantId: v.id),
        ).user,
        contains(_defaultTaskLine(AiSrsFieldTask.translate, 'English')),
      );
    });
  });

  test('内置「已保存的提示词」预设按任务筛；用户条目不筛', () {
    final List<AiSavedPrompt> builtins = aiBuiltinPromptsForTest();
    List<String> visible(AiSrsFieldTask task) => <String>[
      for (final AiSavedPrompt p in builtins)
        if (aiSrsFieldBuiltinPresetVisible(p, task)) p.id.split(':').last,
    ];
    expect(visible(AiSrsFieldTask.define), <String>[
      'concise',
      'list',
      'sense',
      'monolingual',
    ]);
    expect(visible(AiSrsFieldTask.translate), <String>['literal', 'nuance']);
    expect(visible(AiSrsFieldTask.rewrite), <String>['concise', 'example']);
    expect(visible(AiSrsFieldTask.custom), <String>['example']);
    const AiSavedPrompt mine = AiSavedPrompt(id: 'p1', name: 'n', text: 't');
    for (final AiSrsFieldTask task in AiSrsFieldTask.values) {
      expect(aiSrsFieldBuiltinPresetVisible(mine, task), isTrue);
    }
  });
}

/// 内置预设的 id（正文走 i18n，这里只关心 id），顺序同 `aiBuiltinPrompts`。
List<AiSavedPrompt> aiBuiltinPromptsForTest() => <AiSavedPrompt>[
  for (final String slug in <String>[
    'concise',
    'example',
    'list',
    'sense',
    'monolingual',
    'literal',
    'nuance',
  ])
    AiSavedPrompt(
      id: '${kAiBuiltinPromptIdPrefix}srs_field:$slug',
      name: slug,
      text: slug,
      sceneWire: 'srs_field',
    ),
];
