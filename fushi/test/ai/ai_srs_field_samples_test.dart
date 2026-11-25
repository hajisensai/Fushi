import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';
import 'package:fushi/src/ai/ai_srs_field_samples.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_prompt_editor_page.dart'
    show srsFieldAiSamplePreview;
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardNoteType;

/// 样例提示词库：id 冻结且唯一、占位符都认得（保留名或 Fushi 卡片默认字段）、回复格式与
/// 「explanation」一致、功能黑名单（不生成读音 / 振假名 / 音调）。
void main() {
  final RegExp placeholder = RegExp(r'\{\{\s*([^{}]*?)\s*\}\}');

  test('id 唯一、形如 sample.<任务>.<名字> 且任务段与所属任务一致；每个任务至少一条', () {
    final Set<String> ids = <String>{};
    for (final AiSrsFieldSample s in kAiSrsFieldSamples) {
      expect(ids.add(s.id), isTrue, reason: 'duplicate ${s.id}');
      expect(
        s.id,
        matches(
          RegExp(r'^sample\.(define|translate|rewrite|custom)\.[a-z_]+$'),
        ),
      );
      expect(s.id.split('.')[1], aiSrsFieldTaskWire(s.task), reason: s.id);
      expect(s.name.trim(), isNotEmpty, reason: s.id);
      expect(s.name, isNot(s.id), reason: '${s.id} 没有 i18n 名字');
      expect(s.firstLine, isNotEmpty, reason: s.id);
      expect(s.guidance, kAiSrsFieldGuidance, reason: s.id);
      expect(s.template.length, lessThan(kAiSrsFieldPromptMax));
    }
    for (final AiSrsFieldTask task in AiSrsFieldTask.values) {
      expect(aiSrsFieldSamplesFor(task), isNotEmpty, reason: task.name);
    }
    expect(ids, <String>{
      'sample.define.sense',
      'sample.define.monolingual',
      'sample.translate.literal',
      'sample.translate.natural',
      'sample.rewrite.trim_entry',
      'sample.custom.example_sentence',
      'sample.custom.recall_hint',
      'sample.custom.memory_hook',
      'sample.custom.grammar_note',
    });
  });

  test('占位符都是保留名或 Fushi 卡片的默认字段；在示例笔记上没有认不出 / 残留的', () {
    final Set<String> known = <String>{
      ...kAiSrsFieldReservedPlaceholders,
      ...FushiCardNoteType.fields,
    };
    for (final AiSrsFieldSample s in kAiSrsFieldSamples) {
      for (final RegExpMatch m in placeholder.allMatches(s.template)) {
        expect(known, contains(m.group(1)), reason: '${s.id}: ${m.group(0)}');
      }
      final AiSrsFieldRequest r = buildAiSrsFieldRequest(
        note: srsFieldAiSamplePreview(
          task: s.task,
          outputLanguage: 'English',
        ).note,
        prompt: s.prompt,
        instruction: '',
      );
      expect(r.unknownPlaceholders, isEmpty, reason: s.id);
      expect(r.prompt.user, isNot(contains('{{')), reason: s.id);
      expect(r.overLimit, isFalse, reason: s.id);
    }
  });

  test('回复格式：要 "explanation" 的样例才是结构化，纯文本样例不提 explanation', () {
    for (final AiSrsFieldSample s in kAiSrsFieldSamples) {
      expect(
        s.template.contains('"explanation"'),
        s.mode == AiSrsFieldResponseMode.structured,
        reason: s.id,
      );
    }
    final Map<String, AiSrsFieldResponseMode> modes =
        <String, AiSrsFieldResponseMode>{
          for (final AiSrsFieldSample s in kAiSrsFieldSamples) s.id: s.mode,
        };
    expect(
      modes['sample.translate.literal'],
      AiSrsFieldResponseMode.structured,
    );
    expect(
      modes['sample.custom.example_sentence'],
      AiSrsFieldResponseMode.structured,
    );
    expect(
      modes.values.where((AiSrsFieldResponseMode m) {
        return m == AiSrsFieldResponseMode.structured;
      }),
      hasLength(2),
    );
  });

  test('功能黑名单：没有样例生成读音 / 振假名 / 音调', () {
    for (final AiSrsFieldSample s in kAiSrsFieldSamples) {
      final String lower = s.template.toLowerCase();
      for (final String banned in <String>[
        'furigana',
        'pitch',
        'accent',
        'kana',
        'romaji',
        'romanization',
        '<ruby',
        '<rt',
        'pronunciation',
      ]) {
        expect(lower, isNot(contains(banned)), reason: '${s.id}: $banned');
      }
      // 唯一提到 reading 的地方是「不许写出读音」的提示。
      expect(
        lower.replaceAll('without containing it or its reading', ''),
        isNot(contains('reading')),
        reason: s.id,
      );
    }
  });
}
