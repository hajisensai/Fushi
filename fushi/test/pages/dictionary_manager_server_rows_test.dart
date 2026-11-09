import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart'
    show RemoteDictionary;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_manager_panels.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// 词典管理页的服务器托管词典行（设计稿 1）：与本机词典同一条按语言分组的列表，
/// 每行一个来源标签，列表上方来源筛选，服务器行的开关写配置的 hidden，服务器上
/// 已没有的行才有「忘掉」，混排重排两张表一起写。全部用焦点 + 按键驱动。
class _FakeAppModel extends AppModel {
  _FakeAppModel(this.store, this.remote) : super(testPlatformServices());

  final List<Dictionary> store;
  List<RemoteDictionary> remote;
  final List<(String, bool)> hiddenWrites = <(String, bool)>[];
  final List<(String, String)> forgotten = <(String, String)>[];
  final List<(List<Dictionary>, List<RemoteDictionary>)> mixedOrderWrites =
      <(List<Dictionary>, List<RemoteDictionary>)>[];
  bool lookupOn = true;

  List<Dictionary> _sorted() =>
      List<Dictionary>.of(store)
        ..sort((Dictionary a, Dictionary b) => a.order.compareTo(b.order));

  List<Dictionary> _ofType(DictionaryType type) =>
      _sorted().where((Dictionary d) => d.type == type).toList();

  @override
  List<Dictionary> get dictionaries => _sorted();
  @override
  List<Dictionary> get termDictionaries => _ofType(DictionaryType.term);
  @override
  List<Dictionary> get kanjiDictionaries => _ofType(DictionaryType.kanji);
  @override
  List<Dictionary> get kanjiSectionDictionaries =>
      kanjiSectionDictionariesOf(_sorted());
  @override
  List<Dictionary> get freqDictionaries => _ofType(DictionaryType.frequency);
  @override
  List<Dictionary> get pitchDictionaries => _ofType(DictionaryType.pitch);

  @override
  List<RemoteDictionary> get remoteDictionaries =>
      List<RemoteDictionary>.of(remote)..sort(RemoteDictionary.compareByOrder);

  @override
  Future<Map<String, String>> remoteDictionaryHostNames() async =>
      <String, String>{'h1': 'Box'};

  @override
  Map<String, bool> get remoteDictionaryConfigAppliedByHost =>
      const <String, bool>{'h1': false};

  @override
  bool get remoteLookupEnabled => lookupOn;

  @override
  Future<void> setRemoteLookupEnabled(bool value) async => lookupOn = value;

  @override
  Future<void> setRemoteDictionaryHidden(
    RemoteDictionary dictionary,
    bool hidden,
  ) async {
    hiddenWrites.add((dictionary.name, hidden));
    remote = <RemoteDictionary>[
      for (final RemoteDictionary r in remote)
        r.key == dictionary.key ? r.copyWith(hidden: hidden) : r,
    ];
  }

  @override
  Future<void> forgetRemoteDictionary(String hostId, String name) async {
    forgotten.add((hostId, name));
    remote = <RemoteDictionary>[
      for (final RemoteDictionary r in remote)
        if (!(r.hostId == hostId && r.name == name)) r,
    ];
  }

  @override
  Future<void> updateMixedDictionaryOrder(
    List<Dictionary> newDictionaries,
    List<RemoteDictionary> remoteDictionaries,
  ) async {
    mixedOrderWrites.add((newDictionaries, remoteDictionaries));
    for (final Dictionary d in newDictionaries) {
      store.firstWhere((Dictionary s) => s.name == d.name).order = d.order;
    }
    final Map<String, int> orders = <String, int>{
      for (final RemoteDictionary r in remoteDictionaries) r.key: r.order,
    };
    remote = <RemoteDictionary>[
      for (final RemoteDictionary r in remote)
        orders.containsKey(r.key) ? r.copyWith(order: orders[r.key]) : r,
    ];
  }

  @override
  Map<String, DictionaryFormat> get dictionaryFormats =>
      <String, DictionaryFormat>{'yomichan': YomichanFormat.instance};

  @override
  bool get autoUpdateDictionaries => false;
  @override
  DictionaryUpdateInterval get dictionaryUpdateInterval =>
      DictionaryUpdateInterval.weekly;
  @override
  DateTime? get lastDictionaryUpdateAt => null;
}

const int _seenAt = 1762646400000;

List<Dictionary> _local() => <Dictionary>[
  Dictionary(name: 'JMdict', formatKey: 'yomichan', order: 0),
  Dictionary(name: 'Local only', formatKey: 'yomichan', order: 2),
];

List<RemoteDictionary> _remote() => const <RemoteDictionary>[
  // 与本机 JMdict 同名：不单独成行，本机行标「两者」。
  RemoteDictionary(
    hostId: 'h1',
    name: 'JMdict',
    type: DictionaryType.term,
    order: 5,
    lastSeenAt: _seenAt,
  ),
  RemoteDictionary(
    hostId: 'h1',
    name: 'Server Dict',
    type: DictionaryType.term,
    order: 1,
    lastSeenAt: _seenAt,
  ),
  RemoteDictionary(
    hostId: 'h1',
    name: 'Gone Dict',
    type: DictionaryType.term,
    order: 3,
    lastSeenAt: _seenAt - 1000,
    missingSince: _seenAt,
  ),
];

const String _serverKey = 'server:h1/Server Dict';
const String _goneKey = 'server:h1/Gone Dict';

Future<_FakeAppModel> _pumpPage(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final _FakeAppModel model = _FakeAppModel(_local(), _remote());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appProvider.overrideWith((ref) => model)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(
            Brightness.light,
          ).copyWith(platform: TargetPlatform.windows),
          home: const DictionaryDialogPage(),
        ),
      ),
    ),
  );
  await _settle(tester);
  return model;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

/// 把焦点交给 [target] 子树里最深处所在的那个焦点节点（控件自己的 Focus）。
Future<void> _focusInside(WidgetTester tester, Finder target) async {
  final Element leaf = tester.element(
    find
        .descendant(of: target, matching: find.byWidgetPredicate((_) => true))
        .last,
  );
  Focus.of(leaf).requestFocus();
  await tester.pump();
}

Future<void> _pressEnter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _settle(tester);
}

List<String> _rowNames(WidgetTester tester) {
  final List<String> keys = <String>[];
  for (final Element e
      in find
          .byWidgetPredicate(
            (Widget w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'dict-row-source-',
                ),
          )
          .evaluate()) {
    keys.add(
      (e.widget.key! as ValueKey<String>).value.substring(
        'dict-row-source-'.length,
      ),
    );
  }
  return keys;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  test(
    'mixDictionaryManagerRows merges by order, local wins ties and names',
    () {
      final List<DictionaryManagerRow> rows = mixDictionaryManagerRows(
        localSection: _local(),
        allLocal: _local(),
        remote: _remote(),
        sectionType: DictionaryType.term,
        localOrder: (Dictionary d) => d.order,
      );
      expect(rows.map((DictionaryManagerRow r) => r.key).toList(), <String>[
        'JMdict',
        _serverKey,
        'Local only',
        _goneKey,
      ]);
      expect(rows.map((DictionaryManagerRow r) => r.source).toList(), <Object>[
        DictionarySourceKind.both,
        DictionarySourceKind.server,
        DictionarySourceKind.thisDevice,
        DictionarySourceKind.missing,
      ]);
      // 「已隐藏」筛选看的是开关，按服务器筛时「两者」行一并列出。
      expect(
        DictionarySourceFilter.server('h1').matches(rows.first, enabled: true),
        isTrue,
      );
      expect(
        DictionarySourceFilter.thisDevice.matches(rows[1], enabled: true),
        isFalse,
      );
      expect(
        DictionarySourceFilter.hidden.matches(rows[2], enabled: false),
        isTrue,
      );
    },
  );

  testWidgets('every row kind shows its source chip in one mixed list', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester);
    expect(tester.takeException(), isNull);
    expect(_rowNames(tester), <String>[
      'JMdict',
      _serverKey,
      'Local only',
      _goneKey,
    ]);
    String chipText(String key) => tester
        .widget<DictionarySourceChip>(
          find.byKey(ValueKey<String>('dict-row-source-$key')),
        )
        .kind
        .name;
    expect(chipText('JMdict'), 'both');
    expect(chipText('Local only'), 'thisDevice');
    expect(chipText(_serverKey), 'server');
    expect(chipText(_goneKey), 'missing');
    expect(find.text('Both'), findsWidgets);
    expect(find.text('This device'), findsWidgets);
    expect(find.text('Server · Box'), findsWidgets);
    expect(find.text('Not on server'), findsOneWidget);
    // 同名服务器词典不单独成行：JMdict 只出现一次。
    expect(find.text('JMdict'), findsOneWidget);
    // 底部 host 提示：最近在线 + 老版本说明。
    expect(
      find.byKey(const ValueKey<String>('dict-server-notice-h1')),
      findsOneWidget,
    );
    expect(find.textContaining('runs an older version'), findsOneWidget);
    // 概览格：本机 / 服务器分开计（术语 4 行：2 本机 + 2 服务器）。
    expect(find.text('2 on this device · 2 on server'), findsOneWidget);
  });

  testWidgets('filter chip hides rows of other sources', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester);
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-thisDevice')),
    );
    await _pressEnter(tester);
    expect(_rowNames(tester), <String>['JMdict', 'Local only']);
    expect(find.text('Server Dict'), findsNothing);

    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-server-h1')),
    );
    await _pressEnter(tester);
    expect(_rowNames(tester), <String>['JMdict', _serverKey, _goneKey]);
    expect(find.text('Local only'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server row switch writes the profile hidden flag', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-row-switch-$_serverKey')),
    );
    await _pressEnter(tester);
    expect(model.hiddenWrites, <(String, bool)>[('Server Dict', true)]);
    // 关掉之后出现在「已隐藏」筛选里。
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-hidden')),
    );
    await _pressEnter(tester);
    expect(_rowNames(tester), <String>[_serverKey]);
  });

  testWidgets('Forget is offered only for rows no longer on the server', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-row-forget-$_goneKey')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-row-forget-$_serverKey')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-row-forget-JMdict')),
      findsNothing,
    );

    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-row-forget-$_goneKey')),
    );
    await _pressEnter(tester);
    // 先确认：还没忘。
    expect(find.text('Forget Gone Dict?'), findsOneWidget);
    expect(model.forgotten, isEmpty);
    await _focusInside(
      tester,
      find.descendant(of: find.byType(Dialog), matching: find.text('Forget')),
    );
    await _pressEnter(tester);
    expect(model.forgotten, <(String, String)>[('h1', 'Gone Dict')]);
    expect(find.text('Gone Dict'), findsNothing);
  });

  testWidgets('Alt+Down on a server row renumbers local and server together', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    Focus.of(tester.element(find.text('Server Dict'))).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await _settle(tester);

    expect(model.mixedOrderWrites, hasLength(1));
    final (List<Dictionary> locals, List<RemoteDictionary> remotes) =
        model.mixedOrderWrites.single;
    expect(
      <String, int>{for (final Dictionary d in locals) d.name: d.order},
      <String, int>{'JMdict': 0, 'Local only': 1},
    );
    expect(
      <String, int>{for (final RemoteDictionary r in remotes) r.name: r.order},
      <String, int>{'Server Dict': 2, 'Gone Dict': 3},
    );
    expect(_rowNames(tester), <String>[
      'JMdict',
      'Local only',
      _serverKey,
      _goneKey,
    ]);
  });

  testWidgets('remote lookup off: notice offers to turn it on', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    final _FakeAppModel model = await _pumpPage(tester);
    model.lookupOn = false;
    // 触发一次重建（筛选切回「全部」）。
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-thisDevice')),
    );
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-remote-lookup-off')),
      findsOneWidget,
    );
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-remote-lookup-turn-on')),
    );
    await _pressEnter(tester);
    expect(model.lookupOn, isTrue);
    expect(
      find.byKey(const ValueKey<String>('dict-remote-lookup-off')),
      findsNothing,
    );
  });
}
