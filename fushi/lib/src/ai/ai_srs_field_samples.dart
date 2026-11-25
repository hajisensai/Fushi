/// 卡片字段 AI 的**样例提示词库**：「新建变体 › 从样例开始」里列出的现成提示词。
///
/// 边界：
/// - 样例本身不进变体下拉、不落盘、没有覆盖 / 版本机制；选一个 = 照它新建一个普通的用户变体
///   （`AiSrsFieldActions.addVariant`，属于样例的任务），之后与手写的变体完全一样。
/// - [AiSrsFieldSample.id] **冻结**（界面 key 与测试按它认）；名字走 i18n（[AiSrsFieldSample.name]），
///   模板是发给模型的英文提示词，写在代码里。
/// - 模板里的字段名按 Fushi 卡片的默认字段写（`{{Term}}`、`{{Sentence}}`……）；用在别的笔记类型上
///   时编辑页会把认不出的占位符标出来。
/// - 功能黑名单：样例一律不生成读音 / 振假名 / 音调（测试守着）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart'
    show kAiSrsFieldGuidance;
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';

/// 一条样例。
class AiSrsFieldSample {
  const AiSrsFieldSample({
    required this.id,
    required this.task,
    required this.template,
    required this.mode,
    this.guidance = kAiSrsFieldGuidance,
  });

  /// 冻结的 id，形如 `sample.translate.literal`。
  final String id;

  /// 选它新建的变体属于哪个任务。
  final AiSrsFieldTask task;
  final String template;
  final AiSrsFieldResponseMode mode;

  /// AI 说明；默认用内置的那份。
  final String guidance;

  /// 新建变体时照抄的三部分。
  AiSrsFieldActionPrompt get prompt => AiSrsFieldActionPrompt(
    template: template,
    guidance: guidance,
    mode: mode,
  );

  /// 显示名（当前界面语言），也是新建变体的默认名。
  String get name => switch (id) {
    'sample.translate.literal' => t.srs_field_ai_sample_translate_literal,
    'sample.translate.natural' => t.srs_field_ai_sample_translate_natural,
    'sample.define.sense' => t.srs_field_ai_sample_define_sense,
    'sample.define.monolingual' => t.srs_field_ai_sample_define_monolingual,
    'sample.rewrite.trim_entry' => t.srs_field_ai_sample_rewrite_trim_entry,
    'sample.custom.example_sentence' =>
      t.srs_field_ai_sample_custom_example_sentence,
    'sample.custom.recall_hint' => t.srs_field_ai_sample_custom_recall_hint,
    'sample.custom.memory_hook' => t.srs_field_ai_sample_custom_memory_hook,
    'sample.custom.grammar_note' => t.srs_field_ai_sample_custom_grammar_note,
    _ => id,
  };

  /// 模板的第一行（样例清单的副标题）。
  String get firstLine => template.trim().split('\n').first.trim();

  @override
  String toString() => 'AiSrsFieldSample($id)';
}

/// 全部样例（按 [AiSrsFieldTask] 的顺序分组）。
const List<AiSrsFieldSample> kAiSrsFieldSamples = <AiSrsFieldSample>[
  AiSrsFieldSample(
    id: 'sample.define.sense',
    task: AiSrsFieldTask.define,
    mode: AiSrsFieldResponseMode.plain,
    template: '''
In one short line in {{output_language}}, give only the meaning of {{Term}} as used in:
{{Sentence}}

Use this dictionary entry if it covers that sense:
{{MainDefinition}}''',
  ),
  AiSrsFieldSample(
    id: 'sample.define.monolingual',
    task: AiSrsFieldTask.define,
    mode: AiSrsFieldResponseMode.plain,
    template: '''
Define {{Term}} in the language of this sentence (not in {{output_language}}), using easy words a learner already knows. One or two lines. Use only senses found here:
{{Glossary}}

Sentence: {{Sentence}}''',
  ),
  AiSrsFieldSample(
    id: 'sample.translate.literal',
    task: AiSrsFieldTask.translate,
    mode: AiSrsFieldResponseMode.structured,
    template: '''
Give a close, literal translation of this sentence into {{output_language}}, for a learner who wants to see its structure:
{{Sentence}}

- Follow the original order and grammar as far as {{output_language}} allows.
- Put words you had to add in [square brackets].
- Bold the words that translate the <b> part.
- "explanation": one sentence on anything that doesn't map one-to-one.''',
  ),
  AiSrsFieldSample(
    id: 'sample.translate.natural',
    task: AiSrsFieldTask.translate,
    mode: AiSrsFieldResponseMode.plain,
    template: '''
Translate this into natural {{output_language}}, the way a native speaker would say it in the same situation. Keep the tone. Bold the words that carry the meaning of the <b> part.

{{Sentence}}''',
  ),
  AiSrsFieldSample(
    id: 'sample.rewrite.trim_entry',
    task: AiSrsFieldTask.rewrite,
    mode: AiSrsFieldResponseMode.plain,
    template: '''
Shorten this dictionary entry for a flashcard. Don't translate it.
{{target_content}}

- Keep at most 3 senses, numbered; the one used in "{{Sentence}}" first, in <b>…</b>.
- Drop examples, cross-references and dictionary labels.''',
  ),
  AiSrsFieldSample(
    id: 'sample.custom.example_sentence',
    task: AiSrsFieldTask.custom,
    mode: AiSrsFieldResponseMode.structured,
    template: '''
Write one new example sentence using {{Term}} in the same sense as in:
{{Sentence}}

- Same language and politeness level as the original, natural, under 20 words.
- Don't reuse the original sentence.
- Wrap the form of {{Term}} you used in <b>…</b>.
- "explanation": its translation into {{output_language}}.''',
  ),
  AiSrsFieldSample(
    id: 'sample.custom.recall_hint',
    task: AiSrsFieldTask.custom,
    mode: AiSrsFieldResponseMode.plain,
    template: '''
Write a hint for this card that helps recall {{Term}} without containing it or its reading. At most 12 words, in {{output_language}}.

Meaning: {{MainDefinition}}
Sentence: {{Sentence}}''',
  ),
  AiSrsFieldSample(
    id: 'sample.custom.memory_hook',
    task: AiSrsFieldTask.custom,
    mode: AiSrsFieldResponseMode.plain,
    template: '''
Write a short, concrete memory hook in {{output_language}} for {{Term}} meaning:
{{MainDefinition}}

One or two sentences. Don't invent etymology; only use kanji component meanings you are sure of.''',
  ),
  AiSrsFieldSample(
    id: 'sample.custom.grammar_note',
    task: AiSrsFieldTask.custom,
    mode: AiSrsFieldResponseMode.plain,
    template: '''
Explain the grammar of this sentence for a learner, in {{output_language}}:
{{Sentence}}

- Up to 3 points as <ul><li>…</li></ul>, each naming a grammar point or particle and what it does here.
- Skip the obvious. Don't translate the whole sentence.''',
  ),
];

/// [task] 的样例（保持库里的顺序）。
List<AiSrsFieldSample> aiSrsFieldSamplesFor(AiSrsFieldTask task) =>
    <AiSrsFieldSample>[
      for (final AiSrsFieldSample s in kAiSrsFieldSamples)
        if (s.task == task) s,
    ];
