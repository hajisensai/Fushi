import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/ai/ai_srs_field_reply.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_prompt_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
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

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required List<AiChatMessage> messages,
    int maxTokens = 2048,
  }) async {
    sent.add(List<AiChatMessage>.of(messages));
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
}) async {
  tester.view.physicalSize = const Size(900, 4000);
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

  testWidgets('复制为变体（三部分照抄）→ 抽屉选中变体、生成用变体；删掉变体 → 退回默认', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await _tap(tester, 'srs-field-ai-edit-prompt');
    await _tap(tester, 'srs-field-ai-prompt-mode-plain');
    await _tap(tester, 'srs-field-ai-prompt-duplicate');
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
    await _tap(tester, 'srs-field-ai-prompt-duplicate');
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
      startsWith('A mnemonic\n\nField to write: SentenceTranslation\nNote:\n{'),
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
      _selectable(tester, 'srs-field-ai-result-text'),
      'Sure! Here it is: I go.',
    );
    expect(h.closed, isFalse, reason: '还没写');
    await _tap(tester, 'srs-field-ai-append');
    expect(h.result, 'old<br>Sure! Here it is: I go.');

    // 空回复：只有说明，没有「当作文字用」。
    final _Harness h2 = await _pump(tester, _Store());
    h2.client.reply = '{"value": "  ", "explanation": "x"}';
    await _tap(tester, 'srs-field-ai-run');
    expect(find.text(t.ai_assist_empty), findsOneWidget);
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

  testWidgets('内置预设按任务筛（改写 = concise + example）', (WidgetTester tester) async {
    final _Store store = _Store();
    await _pump(tester, store);
    await tester.tap(find.text(t.srs_note_field_ai_rewrite));
    await tester.pumpAndSettle();
    await _tap(tester, 'ai-saved-prompts-srs_field');
    expect(_key('ai-saved-prompt-builtin:srs_field:concise'), findsOneWidget);
    expect(_key('ai-saved-prompt-builtin:srs_field:example'), findsOneWidget);
    expect(_key('ai-saved-prompt-builtin:srs_field:list'), findsNothing);
  });
}
