import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_overwrite_fields_selector.dart';

/// 只桩字段清单 / 笔记类型 / 设置读写；选择器其余逻辑走真实代码。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo(this.settings);

  AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => settings = s;

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => <String, String>{
    'Expression': '仕業',
    'Sentence': '旧句',
    'Picture': '',
  };

  @override
  Future<String?> overwriteNoteTypeName(int noteId) async => 'Lapis';

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

Future<void> _pump(
  WidgetTester tester,
  _FakeRepo repo,
  List<bool> reports,
) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: AnkiOverwriteFieldsSelector(
            repo: repo,
            noteId: 1,
            onNothingSelectedChanged: reports.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 反馈 nWWjBp3Clo：覆写对话框「覆写哪些字段」的勾选规则。
void main() {
  const List<String> fields = <String>['Expression', 'Sentence', 'Picture'];

  group('toggleOverwriteField', () {
    test('从「全部字段」取消勾一个 → 其余字段', () {
      expect(
        toggleOverwriteField(
          allFields: fields,
          selection: null,
          field: 'Expression',
          checked: false,
        ),
        <String>{'Sentence', 'Picture'},
      );
    });

    test('勾满全部字段 → 收回 null（全部字段）', () {
      expect(
        toggleOverwriteField(
          allFields: fields,
          selection: <String>{'Sentence', 'Picture'},
          field: 'Expression',
          checked: true,
        ),
        isNull,
      );
    });

    test('取消勾最后一个 → 空选择（拍板 lt2wobUYfE：允许暂时空选）', () {
      final Set<String>? r = toggleOverwriteField(
        allFields: fields,
        selection: <String>{'Sentence'},
        field: 'Sentence',
        checked: false,
      );
      expect(r, isEmpty);
      expect(isOverwriteSelectionEmpty(r), isTrue);
    });

    test('从空选择勾一个 → 只有这一个', () {
      expect(
        toggleOverwriteField(
          allFields: fields,
          selection: <String>{},
          field: 'Picture',
          checked: true,
        ),
        <String>{'Picture'},
      );
    });
  });

  group('toggleAllOverwriteFields（拍板 lt2wobUYfE：全选 / 全不选）', () {
    test('勾上 = 全部字段，取消 = 一个都不写', () {
      expect(toggleAllOverwriteFields(checked: true), isNull);
      expect(toggleAllOverwriteFields(checked: false), isEmpty);
      expect(
        isOverwriteSelectionEmpty(toggleAllOverwriteFields(checked: false)),
        isTrue,
      );
      expect(isOverwriteSelectionEmpty(null), isFalse);
      expect(isOverwriteSelectionEmpty(<String>{'Sentence'}), isFalse);
    });
  });

  group('effectiveOverwriteSelection', () {
    test('null 原样 = 全部字段', () {
      expect(
        effectiveOverwriteSelection(allFields: fields, stored: null),
        isNull,
      );
    });

    test('卡上没有的旧字段名不算数（与后端只点名卡上有的字段同口径）', () {
      expect(
        effectiveOverwriteSelection(
          allFields: fields,
          stored: <String>{'Sentence', 'OldName'},
        ),
        <String>{'Sentence'},
      );
      expect(
        effectiveOverwriteSelection(
          allFields: fields,
          stored: <String>{'OldName'},
        ),
        isEmpty,
      );
    });
  });

  group('AnkiOverwriteFieldsSelector（拍板 lt2wobUYfE）', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    testWidgets('「全部字段」勾满后再点 = 全不选：记成空选择、报给父组件、提示至少勾一个', (
      WidgetTester tester,
    ) async {
      final _FakeRepo repo = _FakeRepo(const AnkiSettings());
      final List<bool> reports = <bool>[];
      await _pump(tester, repo, reports);
      expect(reports, <bool>[false], reason: '加载完成先报一次当前状态');

      await tester.tap(
        find.byKey(const ValueKey<String>('anki-overwrite-fields-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-overwrite-fields-all')),
      );
      await tester.pumpAndSettle();

      expect(repo.settings.overwriteFieldsFor('Lapis'), isEmpty);
      expect(reports.last, isTrue);
      expect(find.text(t.anki_overwrite_fields_none_selected), findsWidgets);

      // 再点一次 = 全选，回到「全部字段」（删掉条目）。
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-overwrite-fields-all')),
      );
      await tester.pumpAndSettle();
      expect(repo.settings.overwriteFieldsFor('Lapis'), isNull);
      expect(reports.last, isFalse);
      expect(find.text(t.anki_overwrite_fields_none_selected), findsNothing);
    });

    testWidgets('存着空选择时加载即报「一个都没勾」并展开', (WidgetTester tester) async {
      final _FakeRepo repo = _FakeRepo(
        const AnkiSettings().withOverwriteFields('Lapis', const <String>[]),
      );
      final List<bool> reports = <bool>[];
      await _pump(tester, repo, reports);
      expect(reports, <bool>[true]);
      expect(
        find.byKey(const ValueKey<String>('anki-overwrite-field-Sentence')),
        findsOneWidget,
      );
    });
  });
}
