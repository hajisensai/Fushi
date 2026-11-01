import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_saved_prompts.dart';
import 'package:fushi/src/ai/ai_srs_field_assistant.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_ai_sheet.dart';
import 'package:fushi/utils.dart' show FushiFilledButton;
import 'package:material_ui/material_ui.dart';

/// 内存实现：记录每次写回。
class _MemoryStore implements AiSavedPromptStore {
  _MemoryStore(this._prompts);

  List<AiSavedPrompt> _prompts;
  int writes = 0;

  @override
  List<AiSavedPrompt> get aiSavedPrompts => List<AiSavedPrompt>.of(_prompts);

  @override
  Future<void> setAiSavedPrompts(Iterable<AiSavedPrompt> prompts) async {
    writes++;
    _prompts = List<AiSavedPrompt>.of(prompts);
  }
}

Finder _key(String key) => find.byKey(ValueKey<String>(key));

/// 反馈 _LLhOKwmI3：复习字段 AI 抽屉的提示词输入框接上「已保存的提示词」——
/// 选内置预设 / 已存条目即填回输入框并随请求发出；保存当前、删除都写回存储。
void main() {
  testWidgets('字段 AI 抽屉：选预设填入并发出、保存当前、删除', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _MemoryStore store = _MemoryStore(<AiSavedPrompt>[
      const AiSavedPrompt(id: 'g', name: 'General one', text: 'general text'),
      const AiSavedPrompt(
        id: 'th',
        name: 'Theme only',
        text: 'theme text',
        sceneWire: 'theme',
      ),
    ]);
    final List<(AiSrsFieldTask, String)> calls = <(AiSrsFieldTask, String)>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey<String>('open'),
                  onPressed: () => showSrsFieldAiSheet(
                    context,
                    fieldLabel: 'Definition',
                    fieldName: 'MainDefinition',
                    current: '',
                    promptStore: store,
                    run: (AiSrsFieldTask task, String instruction) async {
                      calls.add((task, instruction));
                      return const AiSrsFieldSuggestion(value: 'ok');
                    },
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(_key('open'));
    await tester.pumpAndSettle();

    // 1. 打开库：通用条目可见、别的场景的条目不可见、内置预设可见。
    await tester.tap(_key('ai-saved-prompts-srs_field'));
    await tester.pumpAndSettle();
    expect(_key('ai-saved-prompt-sheet'), findsOneWidget);
    expect(_key('ai-saved-prompt-g'), findsOneWidget);
    expect(_key('ai-saved-prompt-th'), findsNothing);
    expect(_key('ai-saved-prompt-builtin:srs_field:example'), findsOneWidget);
    // 输入框为空时「保存当前」不可用。
    final FushiFilledButton saveButton = tester.widget<FushiFilledButton>(
      _key('ai-saved-prompt-save-current'),
    );
    expect(saveButton.onPressed, isNull);

    // 2. 选内置预设 → 填回输入框 → 生成时作为指令发出。
    await tester.tap(_key('ai-saved-prompt-builtin:srs_field:example'));
    await tester.pumpAndSettle();
    expect(_key('ai-saved-prompt-sheet'), findsNothing);
    final String presetText = t.ai_prompt_preset_srs_field_example_text;
    expect(find.text(presetText), findsOneWidget);
    await tester.tap(_key('srs-field-ai-run'));
    await tester.pumpAndSettle();
    expect(calls.single.$2, presetText);

    // 3. 改写输入框后「保存当前」：命名对话框提交 → 写回存储并出现在列表里。
    await tester.enterText(_key('srs-field-ai-instruction'), 'my own rule');
    await tester.pumpAndSettle();
    await tester.tap(_key('ai-saved-prompts-srs_field'));
    await tester.pumpAndSettle();
    await tester.tap(_key('ai-saved-prompt-save-current'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'Mine');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final AiSavedPrompt mine = store.aiSavedPrompts.last;
    expect(mine.name, 'Mine');
    expect(mine.text, 'my own rule');
    expect(mine.scene, AiPromptScene.srsField);
    expect(_key('ai-saved-prompt-${mine.id}'), findsOneWidget);

    // 4. 删除：菜单 → 删除 → 存储与列表都没了。
    await tester.tap(_key('ai-saved-prompt-menu-${mine.id}'));
    await tester.pumpAndSettle();
    await tester.tap(_key('ai-saved-prompt-action-delete'));
    await tester.pumpAndSettle();
    expect(store.aiSavedPrompts.map((AiSavedPrompt p) => p.id), <String>[
      'g',
      'th',
    ]);
    expect(_key('ai-saved-prompt-${mine.id}'), findsNothing);
  });
}
