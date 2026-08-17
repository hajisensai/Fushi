import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/dictionary/user_dictionary_store.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

class _FakeUserDictAppModel extends AppModel {
  _FakeUserDictAppModel(this._entries) : super(testPlatformServices());

  List<UserDictionaryEntry> _entries;

  /// 每次保存收到的完整列表（页面契约：整份列表交给 AppModel，一处收口）。
  final List<List<UserDictionaryEntry>> savedCalls =
      <List<UserDictionaryEntry>>[];

  @override
  List<UserDictionaryEntry> get userDictionaryEntries => _entries;

  @override
  Future<void> saveUserDictionaryEntries(
    List<UserDictionaryEntry> entries,
  ) async {
    savedCalls.add(entries);
    _entries = entries;
  }
}

Widget _buildApp(AppModel appModel) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
      platformServicesProvider.overrideWithValue(testPlatformServices()),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF386A58),
          ),
        ),
        home: const UserDictionaryEditorPage(),
      ),
    ),
  );
}

void main() {
  testWidgets('空态渲染占位文案；添加词条走完整表单流程', (WidgetTester tester) async {
    final _FakeUserDictAppModel appModel =
        _FakeUserDictAppModel(<UserDictionaryEntry>[]);
    await tester.pumpWidget(_buildApp(appModel));
    await tester.pumpAndSettle();

    expect(find.text(t.dict_user_empty), findsOneWidget);

    await tester.tap(find.text(t.dict_user_entry_add));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), '手向け');
    await tester.enterText(find.byType(TextFormField).at(1), 'たむけ');
    await tester.enterText(find.byType(TextFormField).at(2), '饯别；供奉');
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(appModel.savedCalls, hasLength(1));
    final UserDictionaryEntry saved = appModel.savedCalls.single.single;
    expect(saved.expression, '手向け');
    expect(saved.reading, 'たむけ');
    expect(saved.meaning, '饯别；供奉');
    expect(find.text('手向け【たむけ】'), findsOneWidget);
    expect(find.text(t.dict_user_empty), findsNothing);
  });

  testWidgets('词头为空不允许保存（对话框保持打开、零保存调用）', (WidgetTester tester) async {
    final _FakeUserDictAppModel appModel =
        _FakeUserDictAppModel(<UserDictionaryEntry>[]);
    await tester.pumpWidget(_buildApp(appModel));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.dict_user_entry_add));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    // 对话框未关闭（字段标签仍在），也没有触发任何保存。
    expect(find.text(t.dict_user_field_expression), findsOneWidget);
    expect(appModel.savedCalls, isEmpty);
  });

  testWidgets('点行进入编辑，保存后整条替换', (WidgetTester tester) async {
    final _FakeUserDictAppModel appModel =
        _FakeUserDictAppModel(<UserDictionaryEntry>[
      const UserDictionaryEntry(
        expression: '手向け',
        reading: 'たむけ',
        meaning: '饯别',
      ),
    ]);
    await tester.pumpWidget(_buildApp(appModel));
    await tester.pumpAndSettle();

    await tester.tap(find.text('手向け【たむけ】'));
    await tester.pumpAndSettle();
    expect(find.text(t.dict_user_entry_edit), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(2), '改后的释义');
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(appModel.savedCalls, hasLength(1));
    final UserDictionaryEntry saved = appModel.savedCalls.single.single;
    expect(saved.expression, '手向け');
    expect(saved.meaning, '改后的释义');
    expect(find.text('改后的释义'), findsOneWidget);
  });

  testWidgets('删除需确认；确认后列表清空回到空态', (WidgetTester tester) async {
    final _FakeUserDictAppModel appModel =
        _FakeUserDictAppModel(<UserDictionaryEntry>[
      const UserDictionaryEntry(expression: 'のみ', meaning: '仅仅'),
    ]);
    await tester.pumpWidget(_buildApp(appModel));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text(t.dict_user_entry_delete_confirm), findsOneWidget);

    await tester.tap(find.text(t.dialog_delete));
    await tester.pumpAndSettle();

    expect(appModel.savedCalls, hasLength(1));
    expect(appModel.savedCalls.single, isEmpty);
    expect(find.text(t.dict_user_empty), findsOneWidget);
  });
}
