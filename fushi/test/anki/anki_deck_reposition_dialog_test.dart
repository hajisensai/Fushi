import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_deck_reposition_dialogs.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_anki/fushi_anki.dart';

// 「按词频重排新卡」弹窗的行为守卫：
//   - 词典来源下没有装载词频词典 → 预览按钮禁用并给出原因；切到「笔记字段」
//     来源就能跑；
//   - 装载了词典时按名字渲染多选 chip，且勾选状态从设置里恢复；
//   - 设置页真的接了入口行（接线守卫），且非 AnkiConnect 后端置灰。

class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({required this.supported, AnkiSettings? settings})
      : _settings = settings ?? const AnkiSettings();

  final bool supported;
  AnkiSettings _settings;

  @override
  bool get supportsDeckReposition => supported;

  @override
  Future<AnkiSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AnkiSettings s) async => _settings = s;

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}

const AnkiSettings _settings = AnkiSettings(
  selectedDeckId: 1,
  availableDecks: <AnkiDeck>[
    AnkiDeck(id: 1, name: 'Mining'),
    AnkiDeck(id: 2, name: 'Other'),
  ],
  repositionDictionaries: <String>['JPDB'],
);

Future<AnkiViewModel> _pumpDialog(
  WidgetTester tester, {
  required List<String> loaded,
}) async {
  final _FakeRepo repo = _FakeRepo(supported: true, settings: _settings);
  final AnkiViewModel vm = AnkiViewModel(repo);
  // 让 vm.state.settings 拿到牌组表（弹窗初始化只读一次快照）。
  await vm.setRepositionOptions(
    source: AnkiRepositionSource.dictionaries,
    dictionaries: const <String>['JPDB'],
    aggregate: 'harmonic',
  );
  late BuildContext hostContext;
  await tester.pumpWidget(TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Builder(builder: (BuildContext ctx) {
          hostContext = ctx;
          return const SizedBox.shrink();
        }),
      ),
    ),
  ));
  showAnkiDeckRepositionDialog(
    hostContext,
    viewModel: vm,
    loadedFrequencyDictionaries: loaded,
  );
  await tester.pumpAndSettle();
  return vm;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('没有词频词典时预览禁用；切到笔记字段来源后可用', (WidgetTester tester) async {
    await _pumpDialog(tester, loaded: const <String>[]);
    expect(find.text(t.anki_reposition_dicts_none), findsOneWidget);
    FilledButton preview = tester.widget<FilledButton>(
      find.byKey(const Key('anki_reposition_preview')),
    );
    expect(preview.onPressed, isNull);

    await tester.tap(find.text(t.anki_reposition_source_field));
    await tester.pumpAndSettle();
    expect(find.text(t.anki_reposition_source_field_hint), findsOneWidget);
    preview = tester.widget<FilledButton>(
      find.byKey(const Key('anki_reposition_preview')),
    );
    expect(preview.onPressed, isNotNull);
  });

  testWidgets('按词典名渲染 chip，勾选状态从设置恢复，多本时显示复合方式', (WidgetTester tester) async {
    await _pumpDialog(tester, loaded: const <String>['JPDB', 'BCCWJ']);
    final FilterChip jpdb = tester.widget<FilterChip>(
      find.byKey(const Key('anki_reposition_dict_JPDB')),
    );
    final FilterChip bccwj = tester.widget<FilterChip>(
      find.byKey(const Key('anki_reposition_dict_BCCWJ')),
    );
    expect(jpdb.selected, isTrue);
    expect(bccwj.selected, isFalse);
    // 只勾一本：复合方式无意义，不显示。
    expect(find.byKey(const Key('anki_reposition_aggregate')), findsNothing);

    await tester.tap(find.byKey(const Key('anki_reposition_dict_BCCWJ')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('anki_reposition_aggregate')), findsOneWidget);
    final FilledButton preview = tester.widget<FilledButton>(
      find.byKey(const Key('anki_reposition_preview')),
    );
    expect(preview.onPressed, isNotNull);
  });

  test('view model 的支持位随后端走', () {
    expect(AnkiViewModel(_FakeRepo(supported: false)).supportsDeckReposition,
        isFalse);
    expect(AnkiViewModel(_FakeRepo(supported: true)).supportsDeckReposition,
        isTrue);
  });

  test('接线守卫：设置页接了入口行并按后端能力置灰', () {
    final String page = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();
    expect(page, contains('_buildDeckRepositionRow(vm)'));
    expect(page, contains('vm.supportsDeckReposition'));
    expect(page, contains('showAnkiDeckRepositionDialog('));
  });
}
