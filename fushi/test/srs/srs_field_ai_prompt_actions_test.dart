import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';
import 'package:fushi/src/ai/ai_srs_field_samples.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_prompt_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_formatted_text.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef;
import 'package:material_ui/material_ui.dart';

/// 内存实现：字段 AI 动作改动 + 已保存的提示词。
class _Store implements AiSrsFieldActionStore, AiSavedPromptStore {
  _Store([this._actions = AiSrsFieldActions.empty]);

  AiSrsFieldActions _actions;

  @override
  AiSrsFieldActions get aiFieldActions => _actions;

  @override
  Future<void> setAiFieldActions(AiSrsFieldActions actions) async {
    // 与偏好仓库同一条编解码路径（默认值不落盘、截断、容错）。
    _actions = decodeAiSrsFieldActions(encodeAiSrsFieldActions(actions));
  }

  @override
  List<AiSavedPrompt> get aiSavedPrompts => const <AiSavedPrompt>[];

  @override
  Future<void> setAiSavedPrompts(Iterable<AiSavedPrompt> prompts) async {}
}

/// 截住发出去的消息（与 `srs_note_editing_markup_test.dart` 同一写法），回复可设。
class _CapturingClient extends AiChatClient {
  final List<List<AiChatMessage>> sent = <List<AiChatMessage>>[];
  String reply = '{"value": "I go.", "explanation": "direct"}';

  /// 非空 = 下一次请求抛它（网络 / 提供商失败），抛完清空。
  AiChatFailure? failNext;

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    sent.add(List<AiChatMessage>.of(messages));
    final AiChatFailure? fail = failNext;
    failNext = null;
    if (fail != null) throw fail;
    return reply;
  }
}

final AiProviderConfig _provider = AiProviderConfig(
  id: 'p',
  presetId: kAiCustomPresetId,
  name: 'p',
  baseUrl: Uri.parse('https://example.com/v1'),
  apiKey: 'k',
  model: 'm',
  protocol: AiWireProtocol.openAiCompatible,
);

const List<SrsFieldDef> _fields = <SrsFieldDef>[
  SrsFieldDef(id: 'f0', name: 'Sentence', ord: 0),
  SrsFieldDef(id: 'f1', name: 'SentenceTranslation', ord: 1),
];

AiSrsFieldNoteContext _note([
  Map<String, String> values = const <String, String>{'f0': '毎日<b>通う</b>'},
]) => AiSrsFieldNoteContext(
  noteTypeName: 'T',
  fields: _fields,
  valuesById: values,
  targetFieldId: 'f1',
  outputLanguage: 'English',
);

Finder _key(String key) => find.byKey(ValueKey<String>(key));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

String _selectable(WidgetTester tester, String key) =>
    tester.widget<SelectableText>(_key(key)).data!;

/// 带格式预览（Text.rich）的纯文字。
String _richText(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).textSpan!.toPlainText();

/// [root] 里所有带文字的 TextSpan（深度优先）。
List<TextSpan> _textSpans(InlineSpan root) {
  final List<TextSpan> out = <TextSpan>[];
  root.visitChildren((InlineSpan s) {
    if (s is TextSpan && (s.text ?? '').isNotEmpty) out.add(s);
    return true;
  });
  return out;
}

class _Harness {
  final _CapturingClient client = _CapturingClient();
  String? result;
  bool closed = false;
}

Future<_Harness> _pump(
  WidgetTester tester,
  _Store store, {
  String fieldName = 'SentenceTranslation',
  Map<String, String> values = const <String, String>{'f0': '毎日<b>通う</b>'},
  Size size = const Size(900, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Harness h = _Harness();
  addTearDown(h.client.close);
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey<String>('open'),
                  onPressed: () async {
                    h.result = await showSrsFieldAiSheet(
                      context,
                      fieldLabel: 'Sentence translation',
                      fieldName: fieldName,
                      current: 'old',
                      note: () => _note(values),
                      promptStore: store,
                      actionStore: store,
                      editPrompt:
                          (BuildContext context, AiSrsFieldAction action) =>
                              openSrsFieldAiPromptEditor(
                                context,
                                store: store,
                                target: SrsFieldAiPromptRef.forAction(action),
                                preview: SrsFieldAiPromptPreview(
                                  note: _note(values),
                                  task: action.task,
                                ),
                              ),
                      // 与生产同一个发送函数：消息原样交给客户端。
                      send: (AiSrsFieldPrompt prompt) => sendAiSrsFieldPrompt(
                        client: h.client,
                        provider: _provider,
                        prompt: prompt,
                      ),
                    );
                    h.closed = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(_key('open'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> _leaveEditor(WidgetTester tester) async {
  await Navigator.of(
    tester.element(_key('srs-field-ai-prompt-editor')),
  ).maybePop();
  await tester.pumpAndSettle();
}

AiSrsFieldActionPrompt _builtin(AiSrsFieldTask task) =>
    aiSrsFieldTaskTemplate(task).prompt;

void main() {
  testWidgets('预览 == 请求：编辑页预览的两条消息与抽屉生成时发出的逐字相同', (WidgetTester tester) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');
    expect(_key('srs-field-ai-prompt-editor'), findsOneWidget);
    // 翻译模板用到 {{instruction}}：编辑页有「预览用的要求」。
    await tester.enterText(
      _key('srs-field-ai-prompt-preview-instruction'),
      'keep it casual',
    );
    await tester.pumpAndSettle();
    final String user = _selectable(tester, 'srs-field-ai-prompt-preview-user');
    final String guidance = _selectable(
      tester,
      'srs-field-ai-prompt-preview-guidance',
    );
    final String rules = _selectable(
      tester,
      'srs-field-ai-prompt-preview-rules',
    );
    expect(user, contains('keep it casual'));
    expect(user, contains('"content":"毎日<b>通う</b>"'));
    await _leaveEditor(tester);

    await tester.enterText(_key('srs-field-ai-instruction'), 'keep it casual');
    await tester.pumpAndSettle();
    await _tap(tester, 'srs-field-ai-run');
    final List<AiChatMessage> sent = h.client.sent.single;
    expect(sent.map((AiChatMessage m) => m.role), <String>['system', 'user']);
    expect(sent[0].content, '$guidance\n\n$rules');
    expect(sent[1].content, user);

    // 什么都还没写：要点替换。
    expect(h.closed, isFalse);
    await _tap(tester, 'srs-field-ai-replace');
    expect(h.result, 'I go.');
  });

  testWidgets('编辑提示词：插入占位符（可搜索、补空格）→ 预览现拼 → 保存后生成用改过的', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');
    expect(
      find.text(_builtin(AiSrsFieldTask.translate).template),
      findsOneWidget,
      reason: '打开的是当前任务（翻译）的模板',
    );

    await tester.enterText(
      _key('srs-field-ai-prompt-text'),
      'Translate {{Sentence}} into',
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'srs-field-ai-prompt-insert');
    expect(_key('srs-field-ai-placeholder-sheet'), findsOneWidget);
    // 当前笔记的字段在清单里；搜索筛掉不相干的。
    expect(_key('srs-field-ai-placeholder-field-Sentence'), findsOneWidget);
    await tester.enterText(_key('srs-field-ai-placeholder-search'), 'output');
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-placeholder-note'), findsNothing);
    await _tap(tester, 'srs-field-ai-placeholder-output_language');
    expect(_key('srs-field-ai-placeholder-sheet'), findsNothing);
    final TextEditingController text = tester
        .widget<FushiTextField>(_key('srs-field-ai-prompt-text'))
        .controller!;
    expect(text.text, 'Translate {{Sentence}} into {{output_language}}');
    expect(
      _selectable(tester, 'srs-field-ai-prompt-preview-user'),
      'Translate 毎日<b>通う</b> into English',
      reason: '用户消息就是模板本身，什么都没追加',
    );
    // 模板里没有 {{instruction}}：没有「预览用的要求」。
    expect(_key('srs-field-ai-prompt-preview-instruction'), findsNothing);
    await _tap(tester, 'srs-field-ai-prompt-save');
    expect(store.aiFieldActions.isOverridden('task.translate'), isTrue);
    await _leaveEditor(tester);
    expect(_key('srs-field-ai-sheet'), findsOneWidget, reason: '回到抽屉');

    // 抽屉：这个提示词不用要求 → 要求框禁用 + 提示，预设按钮隐藏。
    expect(
      tester.widget<FushiTextField>(_key('srs-field-ai-instruction')).enabled,
      isFalse,
    );
    expect(_key('srs-field-ai-instruction-unused'), findsOneWidget);
    expect(_key('ai-saved-prompts-srs_field'), findsNothing);

    await _tap(tester, 'srs-field-ai-run');
    expect(
      h.client.sent.single[1].content,
      'Translate 毎日<b>通う</b> into English',
    );
  });

  test('插入占位符：光标前不是空白 / 行首才补空格；有选区就替换', () {
    TextEditingValue at(String text, int start, [int? end]) => TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
    );
    expect(
      srsFieldAiInsertPlaceholder(at('abc', 3), '{{x}}').text,
      'abc {{x}}',
    );
    expect(
      srsFieldAiInsertPlaceholder(at('abc ', 4), '{{x}}').text,
      'abc {{x}}',
    );
    expect(
      srsFieldAiInsertPlaceholder(at('abc\n', 4), '{{x}}').text,
      'abc\n{{x}}',
    );
    expect(srsFieldAiInsertPlaceholder(at('abc', 0), '{{x}}').text, '{{x}}abc');
    final TextEditingValue replaced = srsFieldAiInsertPlaceholder(
      at('a XX b', 2, 4),
      '{{x}}',
    );
    expect(replaced.text, 'a {{x}} b');
    expect(replaced.selection, const TextSelection.collapsed(offset: 7));
    expect(
      srsFieldAiInsertPlaceholder(
        const TextEditingValue(text: 'end'),
        '{{x}}',
      ).text,
      'end {{x}}',
      reason: '没有光标接在末尾',
    );
  });

  testWidgets('编辑页：认不出的占位符警告、超长 / 空模板不能保存、有未保存修改时离开先问', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');

    await tester.enterText(_key('srs-field-ai-prompt-text'), 'Use {{Nope}}');
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-notice-unknown'), findsOneWidget);
    expect(
      _selectable(tester, 'srs-field-ai-prompt-preview-user'),
      'Use {{Nope}}',
    );

    await tester.enterText(
      _key('srs-field-ai-prompt-text'),
      'x' * (kAiSrsFieldPromptMax + 1),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        t.srs_field_ai_prompt_too_long(
          n: kAiSrsFieldPromptMax + 1,
          max: kAiSrsFieldPromptMax,
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<FushiIconButton>(_key('srs-field-ai-prompt-save')).enabled,
      isFalse,
    );
    await tester.enterText(_key('srs-field-ai-prompt-text'), '  ');
    await tester.pumpAndSettle();
    expect(find.text(t.srs_field_ai_prompt_template_empty), findsOneWidget);
    expect(
      tester.widget<FushiIconButton>(_key('srs-field-ai-prompt-save')).enabled,
      isFalse,
    );

    await Navigator.of(
      tester.element(_key('srs-field-ai-prompt-editor')),
    ).maybePop();
    await tester.pumpAndSettle();
    expect(find.text(t.srs_field_ai_prompt_discard_confirm), findsOneWidget);
    await tester.tap(find.text(t.srs_field_ai_prompt_discard));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-prompt-editor'), findsNothing);
    expect(store.aiFieldActions.isEmpty, isTrue, reason: '放弃 = 什么都没写');
  });

  testWidgets('回复格式切换 + 高级里的 AI 说明（清空 = 只有应用规则）；保存；恢复默认三部分一起回去', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');
    expect(
      _selectable(tester, 'srs-field-ai-prompt-preview-rules'),
      contains('Reply with a single JSON object'),
    );
    await _tap(tester, 'srs-field-ai-prompt-mode-plain');
    final String plainRules = _selectable(
      tester,
      'srs-field-ai-prompt-preview-rules',
    );
    expect(plainRules, contains('Reply with only the new content'));
    expect(plainRules, isNot(contains('JSON')));

    // 高级默认收起。
    expect(_key('srs-field-ai-prompt-guidance'), findsNothing);
    await _tap(tester, 'srs-field-ai-prompt-advanced');
    final TextEditingController guidance = tester
        .widget<FushiTextField>(_key('srs-field-ai-prompt-guidance'))
        .controller!;
    expect(guidance.text, kAiSrsFieldGuidance);
    await tester.enterText(
      _key('srs-field-ai-prompt-guidance'),
      'Answer in {{output_language}}.',
    );
    await tester.pumpAndSettle();
    expect(
      _selectable(tester, 'srs-field-ai-prompt-preview-guidance'),
      'Answer in English.',
    );
    await tester.enterText(_key('srs-field-ai-prompt-guidance'), '');
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-prompt-preview-guidance'), findsNothing);
    expect(_key('srs-field-ai-prompt-preview-guidance-empty'), findsOneWidget);

    await _tap(tester, 'srs-field-ai-prompt-save');
    final AiSrsFieldActionPrompt saved = store.aiFieldActions.promptOf(
      'task.translate',
    )!;
    expect(saved.mode, AiSrsFieldResponseMode.plain);
    expect(saved.guidance, '');
    expect(saved.template, _builtin(AiSrsFieldTask.translate).template);
    await _leaveEditor(tester);

    // 纯文本回复：整条回复就是字段内容，系统消息只有应用规则。
    h.client.reply = 'I go every day.';
    await _tap(tester, 'srs-field-ai-run');
    expect(h.client.sent.single[0].content, plainRules);
    expect(find.text('I go every day.'), findsOneWidget);

    await _tap(tester, 'srs-field-ai-edit-prompt');
    await _tap(tester, 'srs-field-ai-prompt-reset');
    await tester.tap(find.text(t.settings_reset_to_default).last);
    await tester.pumpAndSettle();
    expect(store.aiFieldActions.isEmpty, isTrue);
    expect(
      _selectable(tester, 'srs-field-ai-prompt-preview-rules'),
      contains('Reply with a single JSON object'),
      reason: '恢复默认后回复格式也回到附带说明',
    );
  });

  testWidgets('新建变体 › 复制当前（三部分照抄）→ 抽屉选中变体、生成用变体；删掉变体 → 退回默认', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');
    await _tap(tester, 'srs-field-ai-prompt-mode-plain');
    await _tap(tester, 'srs-field-ai-prompt-new-variant');
    await _tap(tester, 'srs-field-ai-new-variant-copy');
    final AiSrsFieldVariant v = store.aiFieldActions.variants.single;
    expect(v.task, AiSrsFieldTask.translate);
    expect(
      v.prompt,
      _builtin(
        AiSrsFieldTask.translate,
      ).copyWith(mode: AiSrsFieldResponseMode.plain),
      reason: '复制当前（未保存的）三部分',
    );
    expect(_key('srs-field-ai-prompt-name'), findsOneWidget, reason: '现在编辑变体');

    await tester.enterText(_key('srs-field-ai-prompt-name'), 'Literal');
    await tester.enterText(
      _key('srs-field-ai-prompt-text'),
      'Translate word by word: {{Sentence}}',
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'srs-field-ai-prompt-save');
    expect(store.aiFieldActions.variant(v.id)!.name, 'Literal');
    expect(
      store.aiFieldActions.isOverridden('task.translate'),
      isFalse,
      reason: '内置动作没被改',
    );
    await _leaveEditor(tester);

    expect(_key('srs-field-ai-variant'), findsOneWidget);
    h.client.reply = 'Every day go.';
    await _tap(tester, 'srs-field-ai-run');
    expect(
      h.client.sent.last[1].content,
      'Translate word by word: 毎日<b>通う</b>',
    );
    expect(find.text('Every day go.'), findsOneWidget);

    // 换任务：变体只属于翻译，下拉消失。
    await tester.tap(find.text(t.srs_note_field_ai_define));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-variant'), findsNothing);
    await tester.tap(find.text(t.srs_note_field_ai_translate));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-variant'), findsOneWidget);

    h.client.reply = '{"value": "I go.", "explanation": "direct"}';
    await _tap(tester, 'srs-field-ai-run');
    expect(
      h.client.sent.last[1].content,
      startsWith('Translate the example sentence'),
      reason: '换任务后回到默认',
    );
    // 删除路径：编辑默认 → 复制出第二个变体 → 删掉它 → 抽屉退回默认。
    await _tap(tester, 'srs-field-ai-edit-prompt');
    await _tap(tester, 'srs-field-ai-prompt-new-variant');
    await _tap(tester, 'srs-field-ai-new-variant-copy');
    expect(store.aiFieldActions.variants, hasLength(2));
    await _tap(tester, 'srs-field-ai-prompt-delete');
    await tester.tap(find.text(t.dialog_delete));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-prompt-editor'), findsNothing);
    expect(
      store.aiFieldActions.variants.map((AiSrsFieldVariant x) => x.id),
      <String>[v.id],
    );
    await _tap(tester, 'srs-field-ai-run');
    expect(
      h.client.sent.last[1].content,
      startsWith('Translate the example sentence'),
      reason: '删掉的变体不再选中',
    );
  });

  testWidgets('内置提示词更新过（迁移来的 P1 覆盖）：提示 + 对比', (WidgetTester tester) async {
    final _Store store = _Store(
      decodeAiSrsFieldActions(
        '{"overrides": {"task.translate": {"text": "Mine.", "baseVersion": 2}}}',
      ),
    );
    await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');
    expect(_key('srs-field-ai-prompt-outdated'), findsOneWidget);
    await _tap(tester, 'srs-field-ai-prompt-compare');
    expect(
      _selectable(tester, 'srs-field-ai-prompt-compare-template-yours'),
      aiSrsFieldMigrateP1TaskText('Mine.'),
    );
    expect(
      _selectable(tester, 'srs-field-ai-prompt-compare-template-builtin'),
      _builtin(AiSrsFieldTask.translate).template,
    );
  });

  testWidgets('自定义：提示词要用户的一句话而没写 → 生成键禁用；写了才可用', (WidgetTester tester) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store, fieldName: 'Notes');
    await tester.tap(find.text(t.srs_note_field_ai_custom));
    await tester.pumpAndSettle();
    FushiFilledButton run() =>
        tester.widget<FushiFilledButton>(_key('srs-field-ai-run'));
    expect(run().onPressed, isNull);
    await tester.enterText(_key('srs-field-ai-instruction'), 'A mnemonic');
    await tester.pumpAndSettle();
    expect(run().onPressed, isNotNull);
    h.client.reply = 'Think of a commuter.';
    await _tap(tester, 'srs-field-ai-run');
    expect(
      h.client.sent.single[1].content,
      startsWith(
        'A mnemonic\n\nField to write: SentenceTranslation\n\nNote:\n{',
      ),
    );
    expect(find.text('Think of a commuter.'), findsOneWidget);
  });

  testWidgets('回复读不懂：说明 + 显示原文 + 「当作文字用」走普通结果，仍要点替换才写', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    h.client.reply = 'Sure! Here it is: I go.';
    await _tap(tester, 'srs-field-ai-run');
    expect(_key('srs-field-ai-reply-error'), findsOneWidget);
    expect(find.text(t.srs_note_field_ai_reply_unreadable), findsOneWidget);
    expect(_key('srs-field-ai-result'), findsNothing);
    await _tap(tester, 'srs-field-ai-show-reply');
    expect(
      _selectable(tester, 'srs-field-ai-raw-reply'),
      'Sure! Here it is: I go.',
    );
    await _tap(tester, 'srs-field-ai-use-as-text');
    expect(_key('srs-field-ai-reply-error'), findsNothing);
    expect(
      _richText(tester, 'srs-field-ai-result-text'),
      'Sure! Here it is: I go.',
    );
    expect(h.closed, isFalse, reason: '还没写');
    await _tap(tester, 'srs-field-ai-append');
    expect(h.result, 'old<br>Sure! Here it is: I go.');

    // 空回复：只有说明，没有「当作文字用」。
    final _Harness h2 = await _pump(tester, _Store());
    h2.client.reply = '{"value": "  ", "explanation": "x"}';
    await _tap(tester, 'srs-field-ai-run');
    // 默认翻译提示词用得上要求、但这次没写：建议重试 / 改提示词，不说「换个说法」。
    expect(find.text(t.srs_note_field_ai_reply_empty_retry), findsOneWidget);
    expect(_key('srs-field-ai-use-as-text'), findsNothing);
    expect(h2.result, isNull);
  });

  testWidgets('请求超限：抽屉报错且不发', (WidgetTester tester) async {
    final _Store store = _Store(
      AiSrsFieldActions.empty.withTemplatePrompt(
        'task.translate',
        _builtin(AiSrsFieldTask.translate).copyWith(
          template: List<String>.filled(13, '{{Sentence}}').join('\n'),
        ),
      ),
    );
    final _Harness h = await _pump(
      tester,
      store,
      values: <String, String>{'f0': 'x' * 1999},
    );
    expect(_key('srs-field-ai-notice-over-limit'), findsOneWidget);
    expect(
      tester.widget<FushiFilledButton>(_key('srs-field-ai-run')).onPressed,
      isNull,
    );
    await tester.tap(_key('srs-field-ai-run'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(h.client.sent, isEmpty);
  });

  testWidgets('从设置打开（示例笔记）：注明示例、字段标成示例笔记的字段、预览用示例句', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: SrsFieldAiPromptEditorPage(
              store: _Store(),
              target: const SrsFieldAiPromptRef.template('task.translate'),
              preview: srsFieldAiSamplePreview(
                task: AiSrsFieldTask.translate,
                outputLanguage: 'English',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.srs_field_ai_prompt_preview_sample), findsOneWidget);
    expect(
      _selectable(tester, 'srs-field-ai-prompt-preview-user'),
      contains('毎日のように図書館に<b>通って</b>いる。'),
    );
    expect(_key('srs-field-ai-notice-unknown'), findsNothing);
    await _tap(tester, 'srs-field-ai-prompt-insert');
    expect(_key('srs-field-ai-placeholder-field-Sentence'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('srs-field-ai-placeholder-field-Sentence'),
        matching: find.textContaining(t.srs_field_ai_placeholder_field_sample),
      ),
      findsOneWidget,
    );
  });

  testWidgets('内置预设按任务筛（改写 = shorter + simpler + format_only）', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    await _pump(tester, store);
    await tester.tap(find.text(t.srs_note_field_ai_rewrite));
    await tester.pumpAndSettle();
    await _tap(tester, 'ai-saved-prompts-srs_field');
    for (final String slug in <String>['shorter', 'simpler', 'format_only']) {
      expect(
        _key('ai-saved-prompt-builtin:srs_field:$slug'),
        findsOneWidget,
        reason: slug,
      );
    }
    expect(_key('ai-saved-prompt-builtin:srs_field:casual'), findsNothing);
    expect(_key('ai-saved-prompt-builtin:srs_field:one_sense'), findsNothing);
  });

  testWidgets('编辑页 › 新建变体 › 从样例：有未保存修改先问；照样例建变体（任务 / 模板 / 回复格式）并切过去编辑', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');
    await tester.enterText(_key('srs-field-ai-prompt-text'), 'unsaved edit');
    await tester.pumpAndSettle();
    await _tap(tester, 'srs-field-ai-prompt-new-variant');
    expect(_key('srs-field-ai-new-variant-sheet'), findsOneWidget);
    await _tap(tester, 'srs-field-ai-new-variant-sample.translate.literal');
    // 照样例会换掉正在编辑的内容：先问。
    expect(find.text(t.srs_field_ai_prompt_discard_confirm), findsOneWidget);
    await tester.tap(find.text(t.srs_field_ai_prompt_discard));
    await tester.pumpAndSettle();

    final AiSrsFieldSample sample = kAiSrsFieldSamples.singleWhere(
      (AiSrsFieldSample x) => x.id == 'sample.translate.literal',
    );
    final AiSrsFieldVariant v = store.aiFieldActions.variants.single;
    expect(v.task, AiSrsFieldTask.translate);
    expect(v.name, sample.name);
    expect(v.prompt.template, sample.template);
    expect(v.prompt.mode, AiSrsFieldResponseMode.structured);
    expect(v.prompt.guidance, kAiSrsFieldGuidance);
    expect(store.aiFieldActions.isOverridden('task.translate'), isFalse);
    // 编辑页现在编辑的是新变体。
    expect(
      tester
          .widget<FushiTextField>(_key('srs-field-ai-prompt-name'))
          .controller!
          .text,
      sample.name,
    );
    expect(
      _selectable(tester, 'srs-field-ai-prompt-preview-user'),
      startsWith(
        'Give a close, literal translation of this sentence into English, '
        'for a learner who wants to see its structure:\n毎日<b>通う</b>\n',
      ),
    );
    await _leaveEditor(tester);

    // 抽屉选中新变体，生成用样例的模板。
    expect(_key('srs-field-ai-variant'), findsOneWidget);
    await _tap(tester, 'srs-field-ai-run');
    expect(
      h.client.sent.last[1].content,
      startsWith('Give a close, literal translation of this sentence'),
    );
  });

  testWidgets('抽屉 › 新建变体：复制当前直接进编辑页；从别的任务的样例 = 在那个任务下新建并切过去', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-new-variant');
    // 当前任务（翻译）的样例在最前。
    expect(
      tester.getTopLeft(_key('srs-field-ai-new-variant-group-translate')).dy,
      lessThan(
        tester.getTopLeft(_key('srs-field-ai-new-variant-group-define')).dy,
      ),
    );
    expect(
      _key('srs-field-ai-new-variant-sample.custom.grammar_note'),
      findsOneWidget,
    );
    await _tap(tester, 'srs-field-ai-new-variant-copy');
    expect(_key('srs-field-ai-prompt-editor'), findsOneWidget);
    final AiSrsFieldVariant copy = store.aiFieldActions.variants.single;
    expect(copy.task, AiSrsFieldTask.translate);
    expect(copy.prompt, _builtin(AiSrsFieldTask.translate));
    expect(
      copy.name,
      t.srs_field_ai_prompt_copy_name(name: t.srs_note_field_ai_translate),
    );
    await _leaveEditor(tester);

    await _tap(tester, 'srs-field-ai-new-variant');
    await _tap(tester, 'srs-field-ai-new-variant-sample.custom.grammar_note');
    expect(_key('srs-field-ai-prompt-editor'), findsOneWidget);
    final AiSrsFieldSample sample = kAiSrsFieldSamples.singleWhere(
      (AiSrsFieldSample x) => x.id == 'sample.custom.grammar_note',
    );
    final AiSrsFieldVariant created = store.aiFieldActions.variants.last;
    expect(store.aiFieldActions.variants, hasLength(2));
    expect(created.task, AiSrsFieldTask.custom);
    expect(created.name, sample.name);
    expect(created.prompt, sample.prompt);
    expect(
      find.text(
        t.srs_field_ai_prompt_variant_of(task: t.srs_note_field_ai_custom),
      ),
      findsOneWidget,
    );
    await _leaveEditor(tester);

    // 抽屉切到自定义、选中新变体；样例不用一句话要求 → 要求框禁用，照样能生成。
    expect(_key('srs-field-ai-instruction-unused'), findsOneWidget);
    h.client.reply = '<ul><li>に: direction</li></ul>';
    await _tap(tester, 'srs-field-ai-run');
    expect(
      h.client.sent.last[1].content,
      startsWith(
        'Explain the grammar of this sentence for a learner, in English:\n'
        '毎日<b>通う</b>\n',
      ),
    );
  });
  testWidgets('弹层正文留边：抽屉 / 新建变体 / 占位符清单 / 已保存的提示词，控件不贴面板左右边缘', (
    WidgetTester tester,
  ) async {
    // FushiModalSheetFrame 默认不给正文留边；这几个弹层以前没传 bodyPadding，分段、输入框、
    // 搜索框、分组标题贴着面板边缘（集成测试截图 01 / 09 / 18 / 02，两套设计系统都一样）。
    void expectInset(String frameKey, Finder content, String what) {
      final Rect frame = tester.getRect(_key(frameKey));
      final Rect box = tester.getRect(content.first);
      expect(
        box.left - frame.left,
        greaterThanOrEqualTo(16),
        reason: '$what: left inset',
      );
      expect(
        frame.right - box.right,
        greaterThanOrEqualTo(16),
        reason: '$what: right inset',
      );
    }

    final _Store store = _Store();
    await _pump(tester, store);
    expectInset(
      'srs-field-ai-sheet',
      _key('srs-field-ai-instruction'),
      'field AI sheet instruction box',
    );
    expectInset(
      'srs-field-ai-sheet',
      find.byWidgetPredicate(
        (Widget w) => w.runtimeType.toString().contains('Segmented'),
      ),
      'field AI sheet task selector',
    );

    await _tap(tester, 'ai-saved-prompts-srs_field');
    expectInset(
      'ai-saved-prompt-sheet',
      find.text(t.ai_prompt_library_presets_header),
      'saved prompts section title',
    );
    await Navigator.of(
      tester.element(_key('ai-saved-prompt-sheet')),
    ).maybePop();
    await tester.pumpAndSettle();

    await _tap(tester, 'srs-field-ai-new-variant');
    expectInset(
      'srs-field-ai-new-variant-sheet',
      find.text(t.srs_field_ai_prompt_new_variant_samples),
      'new variant section title',
    );
    await Navigator.of(
      tester.element(_key('srs-field-ai-new-variant-sheet')),
    ).maybePop();
    await tester.pumpAndSettle();

    await _tap(tester, 'srs-field-ai-edit-prompt');
    await _tap(tester, 'srs-field-ai-prompt-insert');
    expectInset(
      'srs-field-ai-placeholder-sheet',
      _key('srs-field-ai-placeholder-search'),
      'placeholder search field',
    );
  });

  testWidgets('重新生成失败（读不懂 / 空 / 网络）：先清掉上一次的建议，不能再把旧结果替换 / 追加进去', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _pump(tester, _Store());
    await _tap(tester, 'srs-field-ai-run');
    expect(_key('srs-field-ai-result'), findsOneWidget);
    expect(_key('srs-field-ai-replace'), findsOneWidget);

    Future<void> expectNoStale(String what) async {
      expect(_key('srs-field-ai-result'), findsNothing, reason: what);
      expect(_key('srs-field-ai-replace'), findsNothing, reason: what);
      expect(_key('srs-field-ai-append'), findsNothing, reason: what);
    }

    h.client.reply = 'Sure! {broken';
    await _tap(tester, 'srs-field-ai-run');
    expect(_key('srs-field-ai-reply-error'), findsOneWidget);
    await expectNoStale('malformed');
    // 生成过就一直是「重新生成」。
    expect(find.text(t.srs_note_field_ai_again), findsOneWidget);

    h.client.reply = '{"value": "I go.", "explanation": "direct"}';
    await _tap(tester, 'srs-field-ai-run');
    expect(_key('srs-field-ai-result'), findsOneWidget);
    h.client.reply = '{"value": " ", "explanation": "x"}';
    await _tap(tester, 'srs-field-ai-run');
    expect(_key('srs-field-ai-reply-error'), findsOneWidget);
    await expectNoStale('empty');

    h.client.reply = '{"value": "I go.", "explanation": "direct"}';
    await _tap(tester, 'srs-field-ai-run');
    expect(_key('srs-field-ai-result'), findsOneWidget);
    h.client.failNext = const AiChatFailure('timeout');
    await _tap(tester, 'srs-field-ai-run');
    expect(_key('srs-field-ai-error'), findsOneWidget);
    await expectNoStale('network');
    expect(h.closed, isFalse);
  });

  testWidgets('建议带格式预览：加粗 / 斜体 / 换行 / 注音照写进字段的 HTML 画', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _pump(tester, _Store());
    h.client.reply =
        '{"value": "When I <b>noticed</b> <i>it</i><br>'
        '<ruby>気<rt>き</rt></ruby>づく", "explanation": "x"}';
    await _tap(tester, 'srs-field-ai-run');
    final InlineSpan span = tester
        .widget<Text>(_key('srs-field-ai-result-text'))
        .textSpan!;
    final List<TextSpan> spans = _textSpans(span);
    final TextSpan bold = spans.singleWhere(
      (TextSpan s) => s.text == 'noticed',
    );
    expect(bold.style?.fontWeight, FontWeight.w700);
    final TextSpan italic = spans.singleWhere((TextSpan s) => s.text == 'it');
    expect(italic.style?.fontStyle, FontStyle.italic);
    expect(spans.any((TextSpan s) => s.text == '\n'), isTrue, reason: '<br>');
    // 注音：读音画在基字上方。
    expect(
      find.descendant(
        of: _key('srs-field-ai-result'),
        matching: find.text('き'),
      ),
      findsOneWidget,
    );
    expect(
      _richText(tester, 'srs-field-ai-result-text'),
      startsWith('When I noticed it\n'),
    );
    await _tap(tester, 'srs-field-ai-replace');
    expect(
      h.result,
      'When I <b>noticed</b> <i>it</i><br><ruby>気<rt>き</rt></ruby>づく',
    );
  });

  test('带格式预览（纯函数）：空白折叠、段落 / 列表各自成行、嵌套缩进、rp 不画、实体解码', () {
    String plain(String html) => srsFieldAiFormattedSpan(
      html,
      style: const TextStyle(fontSize: 16),
      rubyStyle: const TextStyle(fontSize: 9),
      markColor: const Color(0xFFFFFF00),
    ).toPlainText();
    expect(plain('a  \n b'), 'a b');
    expect(plain('<p>one</p><p>two</p>'), 'one\ntwo');
    expect(plain('x<ol><li>a</li><li>b</li></ol>y'), 'x\n1. a\n2. b\ny');
    expect(plain('<ul><li>a<ul><li>b</li></ul></li></ul>'), '• a\n    • b');
    expect(plain('1 &lt; 2 &amp; 3'), '1 < 2 & 3');
    expect(plain('<ruby>気<rp>(</rp><rt>き</rt><rp>)</rp></ruby>'), '￼');
    final List<TextSpan> spans = _textSpans(
      srsFieldAiFormattedSpan(
        '<u>u</u><mark>m</mark>',
        style: const TextStyle(fontSize: 16),
        rubyStyle: const TextStyle(fontSize: 9),
        markColor: const Color(0xFFFFFF00),
      ),
    );
    expect(spans[0].style?.decoration, TextDecoration.underline);
    expect(spans[1].style?.backgroundColor, const Color(0xFFFFFF00));
  });

  testWidgets('提示词不用要求：要求框禁用且框里写明「不使用」、写过的要求不显示也不丢；回复为空的建议按有没有要求措辞', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    // 默认翻译用得上要求：写一句，空回复 → 「换个说法」。
    await tester.enterText(_key('srs-field-ai-instruction'), 'Be casual.');
    await tester.pumpAndSettle();
    h.client.reply = '{"value": " ", "explanation": "x"}';
    await _tap(tester, 'srs-field-ai-run');
    expect(find.text(t.ai_assist_empty), findsOneWidget);

    // 改成不带 {{instruction}} 的提示词。
    await store.setAiFieldActions(
      store.aiFieldActions.withTemplatePrompt(
        'task.translate',
        _builtin(
          AiSrsFieldTask.translate,
        ).copyWith(template: 'Translate {{Sentence}}.'),
      ),
    );
    await _tap(tester, 'srs-field-ai-edit-prompt');
    await _leaveEditor(tester);
    final FushiTextField box = tester.widget<FushiTextField>(
      _key('srs-field-ai-instruction'),
    );
    expect(box.enabled, isFalse);
    expect(box.hintText, t.srs_note_field_ai_instruction_unused_hint);
    expect(box.prefixIcon, isNotNull);
    expect(box.controller!.text, isEmpty, reason: '写过的要求不显示在禁用框里');
    expect(_key('srs-field-ai-instruction-unused'), findsOneWidget);
    expect(_key('ai-saved-prompts-srs_field'), findsNothing);

    await _tap(tester, 'srs-field-ai-run');
    expect(h.client.sent.last[1].content, 'Translate 毎日<b>通う</b>.');
    expect(find.text(t.srs_note_field_ai_reply_empty_retry), findsOneWidget);
    expect(find.text(t.ai_assist_empty), findsNothing);
  });

  testWidgets('回复读不懂的卡片用错误色调，与说明 / 显示回复 / 当作文字用读作一组', (
    WidgetTester tester,
  ) async {
    final _Harness h = await _pump(tester, _Store());
    h.client.reply = 'Sure! {broken';
    await _tap(tester, 'srs-field-ai-run');
    final FushiCard errorCard = tester.widget<FushiCard>(
      _key('srs-field-ai-reply-error'),
    );
    expect(errorCard.tone, FushiCardTone.error);
    // MD3：柔和错误底（抽屉面 + 12% 错误色），不是饱和的 errorContainer 大色块。
    final ColorScheme scheme = Theme.of(
      tester.element(_key('srs-field-ai-reply-error')),
    ).colorScheme;
    expect(
      errorCard.color,
      Color.alphaBlend(
        scheme.error.withValues(alpha: 0.12),
        scheme.surfaceContainerHigh,
      ),
    );
    expect(errorCard.color, isNot(scheme.errorContainer));
    expect(errorCard.borderColor, scheme.error.withValues(alpha: 0.45));
    for (final String key in <String>[
      'srs-field-ai-reply-error-text',
      'srs-field-ai-show-reply',
      'srs-field-ai-use-as-text',
    ]) {
      expect(
        find.descendant(
          of: _key('srs-field-ai-reply-error'),
          matching: _key(key),
        ),
        findsOneWidget,
        reason: key,
      );
    }
  });

  test('等宽字体链按平台给系统一定有的字体，UI 字体接在后面兜 CJK', () {
    expect(fushiMonospaceFamilies(TargetPlatform.windows).first, 'Consolas');
    expect(
      fushiMonospaceFamilies(TargetPlatform.windows),
      contains('Cascadia Mono'),
    );
    expect(fushiMonospaceFamilies(TargetPlatform.macOS).first, 'Menlo');
    expect(fushiMonospaceFamilies(TargetPlatform.iOS), contains('SF Mono'));
    expect(
      fushiMonospaceFamilies(TargetPlatform.android),
      contains('monospace'),
    );
    expect(fushiMonospaceFamilies(TargetPlatform.linux), contains('monospace'));
    final TextStyle mono = const TextStyle(
      fontFamily: 'UiFont',
      fontFamilyFallback: <String>['Noto Sans JP'],
      fontSize: 13,
    ).monospace;
    final List<String> chain = fushiMonospaceFamilies(defaultTargetPlatform);
    expect(mono.fontFamily, chain.first);
    expect(mono.fontSize, 13);
    expect(mono.fontFamilyFallback, <String>[
      ...chain.skip(1),
      'UiFont',
      'Noto Sans JP',
    ]);
  });

  testWidgets('等宽：提示词框 / 预览 / 原始回复都用平台等宽字体链（不是解析不了的 monospace）', (
    WidgetTester tester,
  ) async {
    final String mono = fushiMonospaceFamilies(defaultTargetPlatform).first;
    final _Harness h = await _pump(tester, _Store());
    h.client.reply = 'Sure! {broken';
    await _tap(tester, 'srs-field-ai-run');
    await _tap(tester, 'srs-field-ai-show-reply');
    expect(
      tester
          .widget<SelectableText>(_key('srs-field-ai-raw-reply'))
          .style
          ?.fontFamily,
      mono,
    );
    await _tap(tester, 'srs-field-ai-edit-prompt');
    expect(
      tester
          .widget<FushiTextField>(_key('srs-field-ai-prompt-text'))
          .style
          ?.fontFamily,
      mono,
    );
    expect(
      tester
          .widget<SelectableText>(_key('srs-field-ai-prompt-preview-user'))
          .style
          ?.fontFamily,
      mono,
    );
  });

  testWidgets('编辑页桌面宽窗口限宽居中；预览两段消息同一结构（分组标题在卡外）', (WidgetTester tester) async {
    await _pump(tester, _Store(), size: const Size(1600, 4000));
    await _tap(tester, 'srs-field-ai-edit-prompt');
    final Rect body = tester.getRect(_key('srs-field-ai-prompt-editor'));
    expect(body.width, lessThanOrEqualTo(900));
    expect(body.center.dx, closeTo(800, 1), reason: '居中');

    for (final String key in <String>[
      'srs-field-ai-prompt-preview-user-title',
      'srs-field-ai-prompt-preview-system-title',
    ]) {
      final FushiSectionTitle title = tester.widget<FushiSectionTitle>(
        _key(key),
      );
      expect(title.level, FushiSectionTitleLevel.group, reason: key);
    }
    double top(String k) => tester.getTopLeft(_key(k)).dy;
    expect(
      top('srs-field-ai-prompt-preview-user-title'),
      lessThan(top('srs-field-ai-prompt-preview-user-card')),
    );
    expect(
      top('srs-field-ai-prompt-preview-user-card'),
      lessThan(top('srs-field-ai-prompt-preview-system-title')),
    );
    expect(
      top('srs-field-ai-prompt-preview-system-title'),
      lessThan(top('srs-field-ai-prompt-preview-guidance-card')),
    );
    expect(
      top('srs-field-ai-prompt-preview-guidance-card'),
      lessThan(top('srs-field-ai-prompt-preview-rules-card')),
    );
    // 标题不在卡片里。
    expect(
      find.descendant(
        of: _key('srs-field-ai-prompt-preview-user-card'),
        matching: find.text(t.srs_field_ai_prompt_preview_user),
      ),
      findsNothing,
    );
  });

  test('变体名去重：默认名按任务避开已有名字，长名截短后序号不丢', () {
    AiSrsFieldActions a = AiSrsFieldActions.empty;
    String fmt(String b, int n) => n == 1 ? '$b (copy)' : '$b (copy $n)';
    expect(a.uniqueVariantName(AiSrsFieldTask.translate, 'T', fmt), 'T (copy)');
    a = a
        .addVariant(
          task: AiSrsFieldTask.translate,
          name: 'T (copy)',
          prompt: _builtin(AiSrsFieldTask.translate),
        )
        .$1;
    expect(
      a.uniqueVariantName(AiSrsFieldTask.translate, 'T', fmt),
      'T (copy 2)',
    );
    // 别的任务不算重名。
    expect(a.uniqueVariantName(AiSrsFieldTask.define, 'T', fmt), 'T (copy)');
    expect(a.variantNameTaken(AiSrsFieldTask.translate, ' t (COPY) '), isTrue);
    final String long = 'x' * kAiSrsFieldVariantNameMax;
    final String first = a.uniqueVariantName(
      AiSrsFieldTask.translate,
      long,
      fmt,
    );
    expect(first.length, lessThanOrEqualTo(kAiSrsFieldVariantNameMax));
    expect(first, endsWith(' (copy)'), reason: '截的是名字、不是序号');
    a = a
        .addVariant(
          task: AiSrsFieldTask.translate,
          name: first,
          prompt: _builtin(AiSrsFieldTask.translate),
        )
        .$1;
    expect(a.variants.last.name, first, reason: '存进去不再被截');
    final String next = a.uniqueVariantName(
      AiSrsFieldTask.translate,
      long,
      fmt,
    );
    expect(next.length, lessThanOrEqualTo(kAiSrsFieldVariantNameMax));
    expect(next, endsWith(' (copy 2)'));
  });

  testWidgets('变体重名：复制两次 / 同一样例两次自动编号；改名撞上同任务的变体时提示，保存前确认', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    await _pump(tester, store);
    final String translate = t.srs_note_field_ai_translate;
    Future<void> copyCurrent() async {
      await _tap(tester, 'srs-field-ai-new-variant');
      await _tap(tester, 'srs-field-ai-new-variant-copy');
      await _leaveEditor(tester);
    }

    await copyCurrent();
    // 抽屉此时选中了第一个副本：切走再切回（换任务 = 回到默认），再复制一次默认。
    await tester.tap(find.text(t.srs_note_field_ai_define).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(translate).first);
    await tester.pumpAndSettle();
    await copyCurrent();
    expect(
      <String>[
        for (final AiSrsFieldVariant v in store.aiFieldActions.variants) v.name,
      ],
      <String>[
        t.srs_field_ai_prompt_copy_name(name: translate),
        t.srs_field_ai_prompt_copy_name_n(name: translate, n: 2),
      ],
    );

    final AiSrsFieldSample sample = kAiSrsFieldSamples.singleWhere(
      (AiSrsFieldSample x) => x.id == 'sample.custom.grammar_note',
    );
    for (int i = 0; i < 2; i++) {
      await _tap(tester, 'srs-field-ai-new-variant');
      await _tap(tester, 'srs-field-ai-new-variant-sample.custom.grammar_note');
      await _leaveEditor(tester);
    }
    final List<String> custom = <String>[
      for (final AiSrsFieldVariant v in store.aiFieldActions.variantsFor(
        AiSrsFieldTask.custom,
      ))
        v.name,
    ];
    expect(custom, <String>[
      sample.name,
      t.srs_field_ai_prompt_name_numbered(name: sample.name, n: 2),
    ]);

    // 编辑第二个样例变体：改成第一个的名字 → 名称框下提示；保存先确认，取消不写。
    await _tap(tester, 'srs-field-ai-edit-prompt');
    await tester.enterText(_key('srs-field-ai-prompt-name'), sample.name);
    await tester.pumpAndSettle();
    final String taken = t.srs_field_ai_prompt_name_taken(
      task: t.srs_note_field_ai_custom,
      name: sample.name,
    );
    expect(
      tester
          .widget<FushiTextField>(_key('srs-field-ai-prompt-name'))
          .helperText,
      taken,
    );
    await _tap(tester, 'srs-field-ai-prompt-save');
    expect(find.text(t.srs_field_ai_prompt_name_taken_title), findsOneWidget);
    await tester.tap(find.text(t.cancel).last);
    await tester.pumpAndSettle();
    expect(
      store.aiFieldActions.variantsFor(AiSrsFieldTask.custom).last.name,
      t.srs_field_ai_prompt_name_numbered(name: sample.name, n: 2),
    );
    await _tap(tester, 'srs-field-ai-prompt-save');
    await tester.tap(find.text(t.srs_field_ai_prompt_save_anyway).last);
    await tester.pumpAndSettle();
    expect(
      store.aiFieldActions.variantsFor(AiSrsFieldTask.custom).last.name,
      sample.name,
      reason: '确认后照样保存',
    );
  });

  testWidgets('「新建变体」是与「编辑提示词」同样式的文字按钮（≥48dp）；预设书签有提示与无障碍标签', (
    WidgetTester tester,
  ) async {
    await _pump(tester, _Store());
    final FushiTextButton newVariant = tester.widget<FushiTextButton>(
      _key('srs-field-ai-new-variant'),
    );
    expect(newVariant, isNotNull);
    expect(
      _key('srs-field-ai-edit-prompt').evaluate().single.widget,
      isA<FushiTextButton>(),
    );
    expect(
      find.descendant(
        of: _key('srs-field-ai-new-variant'),
        matching: find.text(t.srs_field_ai_prompt_new_variant),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSize(_key('srs-field-ai-new-variant')).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(_key('srs-field-ai-new-variant')).height,
      tester.getSize(_key('srs-field-ai-edit-prompt')).height,
    );
    expect(
      find.descendant(
        of: _key('ai-saved-prompts-srs_field'),
        matching: find.byTooltip(t.ai_prompt_library_title),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(t.ai_prompt_library_title), findsWidgets);
  });
}
