// ignore_for_file: invalid_use_of_protected_member
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_config_controls.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-1902：新手引导配置 Anki 那一步缺少「创建 Lapis 卡组 / 刷新卡组 / 选择牌组」
/// （用户 2026-08-28 报告）。
///
/// 根因是这三样只活在 `anki_settings_page.dart` 的**私有实例方法**里，跨文件不可见，
/// 引导页只能显示三行只读文本（未选时是「—」）。修法是把它们抽成共享组件，
/// 两页共用同一份实现，而不是复制一份进引导页。
///
/// 这里守两层：① 组件本身的真实行为（选中即写回 view model、建 Lapis 会回报在途
/// 状态）；② 两个页面确实都用了这份共享实现（接线守卫——那正是缺失的东西）。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo();

  AnkiSettings _settings = const AnkiSettings();
  int createNoteTypeCalls = 0;
  int createDeckCalls = 0;

  @override
  Future<AnkiSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => _settings = s;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async {
    createNoteTypeCalls++;
    return true;
  }

  @override
  Future<bool> createDeck(String name) async {
    createDeckCalls++;
    return true;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    final List<AnkiDeck> decks = <AnkiDeck>[
      const AnkiDeck(id: 1, name: 'Lapis'),
      const AnkiDeck(id: 2, name: 'Mining'),
    ];
    final List<AnkiNoteType> noteTypes = <AnkiNoteType>[
      AnkiNoteType(id: 7, name: 'Lapis', fields: LapisNoteType.fields),
      const AnkiNoteType(id: 8, name: 'Basic', fields: <String>['Front']),
    ];
    _settings = _settings.copyWith(
      availableDecks: decks,
      availableNoteTypes: noteTypes,
    );
    return AnkiFetchResult.success(decks: decks, noteTypes: noteTypes);
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      const MineOutcome.notConfigured();

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
}

AnkiSettings _loadedSettings() => AnkiSettings(
      availableDecks: const <AnkiDeck>[
        AnkiDeck(id: 1, name: 'Lapis'),
        AnkiDeck(id: 2, name: 'Mining'),
      ],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(id: 7, name: 'Lapis', fields: LapisNoteType.fields),
        const AnkiNoteType(id: 8, name: 'Basic', fields: <String>['Front']),
      ],
      selectedDeckId: 1,
      selectedNoteTypeId: 7,
    );

Widget _host(Widget child) => TranslationProvider(
      child: MaterialApp(
          home: Scaffold(body: ListView(children: <Widget>[child]))),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('牌组选择行渲染可选项并把选择写回 view model', (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    final AnkiViewModel vm = AnkiViewModel(repo);

    await tester.pumpWidget(_host(
      AnkiDeckPickerRow(settings: _loadedSettings(), viewModel: vm),
    ));
    await tester.pumpAndSettle();

    // controlBelow: true 会把标题渲染两次（标签 + 控件自身），所以是 findsWidgets。
    expect(find.text(t.anki_deck), findsWidgets);
    // 当前选中的牌组名真的显示出来 —— 引导页此前这里只有一个「—」，正是本 bug。
    // （其余候选项要展开 picker 才渲染，不在本用例范围内。）
    expect(find.textContaining('Lapis'), findsWidgets);
  });

  testWidgets('笔记类型选择行渲染标题与可选项', (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    final AnkiViewModel vm = AnkiViewModel(repo);

    await tester.pumpWidget(_host(
      AnkiNoteTypePickerRow(settings: _loadedSettings(), viewModel: vm),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.anki_note_type), findsWidgets);
    // 当前选中的笔记类型必须显示出来（引导页此前是「—」）。
    expect(find.textContaining('Lapis'), findsWidgets);
  });

  testWidgets('创建 Lapis 卡组：点一下真的调后端，并把在途状态回报给宿主页', (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    final AnkiViewModel vm = AnkiViewModel(repo);

    final List<bool> busyLog = <bool>[];
    await tester.pumpWidget(_host(
      AnkiCreateLapisRow(
        viewModel: vm,
        isFetching: false,
        onBusyChanged: busyLog.add,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.anki_create_lapis), findsOneWidget);

    await tester.tap(find.text(t.anki_create_lapis));
    await tester.pumpAndSettle();

    expect(repo.createNoteTypeCalls, 1);
    expect(repo.createDeckCalls, 1);
    // 在途状态必须回报：设置页的「刷新牌组」行靠它把「获取中…」压住
    // （createLapisSetup 内部也会置 AnkiUiState.isFetching，两者分不开）。
    expect(busyLog, <bool>[true, false]);
  });

  testWidgets('外部拉取在途时创建行禁用（两个动作不打架）', (WidgetTester tester) async {
    final _FakeRepo repo = _FakeRepo();
    final AnkiViewModel vm = AnkiViewModel(repo);

    await tester.pumpWidget(_host(
      AnkiCreateLapisRow(viewModel: vm, isFetching: true),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.anki_create_lapis));
    await tester.pumpAndSettle();

    expect(repo.createDeckCalls, 0);
  });

  test('接线守卫：引导页与制卡设置页都用共享组件，且实现只有一份（BUG-1902）', () {
    final String onboarding = File(
      'lib/src/pages/implementations/onboarding_wizard_page.dart',
    ).readAsStringSync();
    final String settings = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();
    final String shared =
        File('lib/src/anki/anki_config_controls.dart').readAsStringSync();

    for (final String widgetName in <String>[
      'AnkiCreateLapisRow',
      'AnkiDeckPickerRow',
      'AnkiNoteTypePickerRow',
    ]) {
      expect(onboarding.contains(widgetName), isTrue,
          reason: '新手引导必须提供 $widgetName —— 缺的正是这个（BUG-1902）');
      expect(settings.contains(widgetName), isTrue,
          reason: '制卡设置页必须复用同一份 $widgetName，而不是自己再写一份');
    }

    // 单一实现不变量：调用 view model 的那几个动作只能出现在共享组件里。
    // 任何一页重新长出自己的 selectDeck/selectNoteType/createLapisSetup 调用，
    // 就是重复实现回潮。
    for (final String call in <String>[
      'createLapisSetup(',
      'selectDeck(',
      'selectNoteType(',
    ]) {
      expect(shared.contains(call), isTrue, reason: '共享组件应当是 $call 的唯一 UI 调用点');
      expect(onboarding.contains(call), isFalse,
          reason: '引导页不得自己调 $call —— 走共享组件');
      expect(settings.contains(call), isFalse,
          reason: '设置页不得自己调 $call —— 走共享组件');
    }
  });
}
