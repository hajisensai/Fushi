import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_actions.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_prompt_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsFieldDef;
import 'package:material_ui/material_ui.dart';

/// 内存实现：字段 AI 提示词改动 + 已保存的提示词。
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

const List<SrsFieldDef> _fields = <SrsFieldDef>[
  SrsFieldDef(id: 'f0', name: 'Sentence', ord: 0),
  SrsFieldDef(id: 'f1', name: 'SentenceTranslation', ord: 1),
];

const Map<String, String> _values = <String, String>{'f0': '毎日<b>通う</b>'};

SrsFieldAiPromptPreview _preview(AiSrsFieldTask task) =>
    SrsFieldAiPromptPreview(
      noteTypeName: 'T',
      fields: _fields,
      valuesById: _values,
      targetFieldId: 'f1',
      outputLanguage: 'English',
      task: task,
    );

Finder _key(String key) => find.byKey(ValueKey<String>(key));

class _Harness {
  final List<(AiSrsFieldAction, AiSrsFieldPrompt)> runs =
      <(AiSrsFieldAction, AiSrsFieldPrompt)>[];
  String? result;
}

Future<_Harness> _pump(
  WidgetTester tester,
  _Store store, {
  String fieldName = 'SentenceTranslation',
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Harness h = _Harness();
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
                      promptStore: store,
                      actionStore: store,
                      editPrompt:
                          (BuildContext context, AiSrsFieldAction action) =>
                              openSrsFieldAiPromptEditor(
                                context,
                                store: store,
                                target: SrsFieldAiPromptRef.forAction(action),
                                preview: _preview(action.task),
                              ),
                      // 与生产 runner 同一条拼装路径：每次现读存储。
                      run: (AiSrsFieldAction action, String instruction) async {
                        h.runs.add((
                          action,
                          buildAiSrsFieldPrompt(
                            noteTypeName: 'T',
                            fields: _fields,
                            valuesById: _values,
                            targetFieldId: 'f1',
                            action: action,
                            actions: store.aiFieldActions,
                            instruction: instruction,
                            outputLanguage: 'English',
                          ),
                        ));
                        return const AiSrsFieldSuggestion(value: 'I go.');
                      },
                    );
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

void main() {
  testWidgets('没有变体就没有变体下拉；Edit prompt 打开编辑页，保存后生成用改过的提示词，替换照旧', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    expect(_key('srs-field-ai-variant'), findsNothing);

    await tester.tap(_key('srs-field-ai-edit-prompt'));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-prompt-editor'), findsOneWidget);
    expect(
      find.text(aiSrsFieldTaskTemplate(AiSrsFieldTask.translate).text),
      findsOneWidget,
      reason: '打开的是当前任务（翻译）的模板',
    );
    // 当前笔记的字段都有占位符 chip。
    expect(_key('srs-field-ai-prompt-chip-Sentence'), findsOneWidget);
    expect(_key('srs-field-ai-prompt-chip-output_language'), findsOneWidget);

    await tester.enterText(
      _key('srs-field-ai-prompt-text'),
      'Task: translate {{Sentence}} into ',
    );
    await tester.tap(_key('srs-field-ai-prompt-chip-output_language'));
    await tester.pumpAndSettle();
    // 预览按当前正文现拼。
    final SelectableText preview = tester.widget<SelectableText>(
      _key('srs-field-ai-prompt-preview-user'),
    );
    expect(preview.data, contains('Task: translate 毎日<b>通う</b> into English'));
    await tester.tap(_key('srs-field-ai-prompt-save'));
    await tester.pumpAndSettle();
    expect(store.aiFieldActions.isOverridden('task.translate'), isTrue);
    await _leaveEditor(tester);
    expect(_key('srs-field-ai-sheet'), findsOneWidget, reason: '回到抽屉');

    await tester.tap(_key('srs-field-ai-run'));
    await tester.pumpAndSettle();
    expect(h.runs.single.$1, const AiSrsFieldAction(AiSrsFieldTask.translate));
    expect(
      h.runs.single.$2.user,
      contains('Task: translate 毎日<b>通う</b> into English'),
    );
    expect(h.runs.single.$2.system, kAiSrsFieldSystemPrompt);

    await tester.tap(_key('srs-field-ai-replace'));
    await tester.pumpAndSettle();
    expect(h.result, 'I go.');
  });

  testWidgets('编辑页：认不出的占位符警告、超长不能保存、有未保存修改时离开先问', (WidgetTester tester) async {
    final _Store store = _Store();
    await _pump(tester, store);
    await tester.tap(_key('srs-field-ai-edit-prompt'));
    await tester.pumpAndSettle();

    await tester.enterText(_key('srs-field-ai-prompt-text'), 'Use {{Nope}}');
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-prompt-unknown'), findsOneWidget);

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

  testWidgets('复制为变体 → 抽屉选中变体、生成用变体正文；删掉变体 → 退回默认', (
    WidgetTester tester,
  ) async {
    final _Store store = _Store();
    final _Harness h = await _pump(tester, store);
    await tester.tap(_key('srs-field-ai-edit-prompt'));
    await tester.pumpAndSettle();
    await tester.tap(_key('srs-field-ai-prompt-duplicate'));
    await tester.pumpAndSettle();
    final AiSrsFieldVariant v = store.aiFieldActions.variants.single;
    expect(v.task, AiSrsFieldTask.translate);
    expect(
      v.text,
      aiSrsFieldTaskTemplate(AiSrsFieldTask.translate).text,
      reason: '复制当前正文',
    );
    expect(_key('srs-field-ai-prompt-name'), findsOneWidget, reason: '现在编辑变体');

    await tester.enterText(_key('srs-field-ai-prompt-name'), 'Literal');
    await tester.enterText(
      _key('srs-field-ai-prompt-text'),
      'Task: translate word by word.',
    );
    await tester.tap(_key('srs-field-ai-prompt-save'));
    await tester.pumpAndSettle();
    expect(store.aiFieldActions.variant(v.id)!.name, 'Literal');
    expect(
      store.aiFieldActions.isOverridden('task.translate'),
      isFalse,
      reason: '内置模板没被改',
    );
    await _leaveEditor(tester);

    expect(_key('srs-field-ai-variant'), findsOneWidget);
    await tester.tap(_key('srs-field-ai-run'));
    await tester.pumpAndSettle();
    expect(
      h.runs.last.$1,
      AiSrsFieldAction(AiSrsFieldTask.translate, variantId: v.id),
    );
    expect(h.runs.last.$2.user, contains('Task: translate word by word.'));

    // 换任务：变体只属于翻译，下拉消失。
    await tester.tap(find.text(t.srs_note_field_ai_define));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-variant'), findsNothing);
    await tester.tap(find.text(t.srs_note_field_ai_translate));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-variant'), findsOneWidget);

    await tester.tap(_key('srs-field-ai-run'));
    await tester.pumpAndSettle();
    expect(h.runs.last.$1.variantId, isNull, reason: '换任务后回到默认');
    // 删除路径：编辑默认模板 → 复制出第二个变体 → 删掉它 → 抽屉退回默认。
    await tester.tap(_key('srs-field-ai-edit-prompt'));
    await tester.pumpAndSettle();
    await tester.tap(_key('srs-field-ai-prompt-duplicate'));
    await tester.pumpAndSettle();
    expect(store.aiFieldActions.variants, hasLength(2));
    await tester.tap(_key('srs-field-ai-prompt-delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-prompt-editor'), findsNothing);
    expect(
      store.aiFieldActions.variants.map((AiSrsFieldVariant x) => x.id),
      <String>[v.id],
    );
    await tester.tap(_key('srs-field-ai-run'));
    await tester.pumpAndSettle();
    expect(
      h.runs.last.$1,
      const AiSrsFieldAction(AiSrsFieldTask.translate),
      reason: '删掉的变体不再选中',
    );
  });

  testWidgets('内置提示词更新过：提示 + 对比两份', (WidgetTester tester) async {
    final _Store store = _Store(
      decodeAiSrsFieldActions(
        '{"overrides": {"task.translate": {"text": "Mine.", "baseVersion": 0}}}',
      ),
    );
    await _pump(tester, store);
    await tester.tap(_key('srs-field-ai-edit-prompt'));
    await tester.pumpAndSettle();
    expect(_key('srs-field-ai-prompt-outdated'), findsOneWidget);
    await tester.tap(_key('srs-field-ai-prompt-compare'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(_key('srs-field-ai-prompt-compare-yours'))
          .data,
      'Mine.',
    );
    expect(
      tester
          .widget<SelectableText>(_key('srs-field-ai-prompt-compare-builtin'))
          .data,
      aiSrsFieldTaskTemplate(AiSrsFieldTask.translate).text,
    );
  });

  testWidgets('总体说明的编辑页显示锁定的契约', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Store store = _Store();
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: SrsFieldAiPromptEditorPage(
              store: store,
              target: const SrsFieldAiPromptRef.template(
                kAiSrsFieldSystemTemplateId,
              ),
              preview: srsFieldAiSamplePreview(
                task: AiSrsFieldTask.define,
                outputLanguage: 'English',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(
            find.descendant(
              of: _key('srs-field-ai-prompt-contract'),
              matching: find.byType(SelectableText),
            ),
          )
          .data,
      kAiSrsFieldContract,
    );
    await tester.enterText(_key('srs-field-ai-prompt-text'), '');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(_key('srs-field-ai-prompt-preview-system'))
          .data,
      kAiSrsFieldContract,
      reason: '说明清空，契约照样在',
    );
    // 示例笔记：不列示例的字段 chip。
    expect(_key('srs-field-ai-prompt-chip-Sentence'), findsNothing);
    expect(find.text(t.srs_field_ai_prompt_preview_sample), findsOneWidget);
  });

  testWidgets('内置预设按任务筛（改写 = concise + example）', (WidgetTester tester) async {
    final _Store store = _Store();
    await _pump(tester, store);
    await tester.tap(find.text(t.srs_note_field_ai_rewrite));
    await tester.pumpAndSettle();
    await tester.tap(_key('ai-saved-prompts-srs_field'));
    await tester.pumpAndSettle();
    expect(_key('ai-saved-prompt-builtin:srs_field:concise'), findsOneWidget);
    expect(_key('ai-saved-prompt-builtin:srs_field:example'), findsOneWidget);
    expect(_key('ai-saved-prompt-builtin:srs_field:list'), findsNothing);
  });
}
