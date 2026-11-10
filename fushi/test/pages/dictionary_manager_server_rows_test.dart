import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/sync/dictionary_transfer_service.dart';
import 'package:fushi/src/models/dictionary_repository.dart'
    show DictionaryRepository, RemoteDictionary, RemoteDictionaryHostSource;
import 'package:fushi/src/sync/remote_dictionary_catalog_service.dart'
    show RemoteDictionaryHostReachability;
import 'package:fushi/src/utils/components/content_language_picker.dart'
    show contentLanguageLabelOf;
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_manager_panels.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart' show ToastSeverity;
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// 词典管理页的服务器托管词典行（设计稿 1）：与本机词典同一条按语言分组的列表，
/// 每行一个来源标签，列表上方来源筛选，服务器行的开关写配置的 hidden，服务器上
/// 已没有的行才有「忘掉」，混排重排两张表一起写。全部用焦点 + 按键驱动。
class _FakeAppModel extends AppModel {
  _FakeAppModel(this.store, this.remote, {List<RemoteDictionary>? catalog})
    : catalogRows = catalog,
      super(testPlatformServices());

  final List<Dictionary> store;
  List<RemoteDictionary> remote;

  /// 来源条用的全部目录行（含参与查词以外的类型）；null = 与 [remote] 相同。
  final List<RemoteDictionary>? catalogRows;
  final Map<String, bool> hostLookup = <String, bool>{'h1': true, 'h2': true};
  final List<(String, bool)> hostLookupWrites = <(String, bool)>[];
  final List<String> refreshedHosts = <String>[];
  final List<(String, String?)> localNameWrites = <(String, String?)>[];
  Map<String, RemoteDictionaryHostReachability> reachability =
      const <String, RemoteDictionaryHostReachability>{};
  int profilesOpened = 0;
  final List<(String, bool)> hiddenWrites = <(String, bool)>[];
  final List<(String, String)> forgotten = <(String, String)>[];
  final List<(List<Dictionary>, List<RemoteDictionary>)> mixedOrderWrites =
      <(List<Dictionary>, List<RemoteDictionary>)>[];

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
      <String, String>{'h1': 'Box', 'h2': 'Laptop'};

  @override
  Future<List<RemoteDictionaryHostSource>> remoteDictionaryHostSources() async {
    final List<RemoteDictionary> rows = catalogRows ?? remote;
    final Map<String, String> names = await remoteDictionaryHostNames();
    return <RemoteDictionaryHostSource>[
      for (final String host in <String>{
        for (final RemoteDictionary r in rows) r.hostId,
      })
        RemoteDictionaryHostSource(
          hostId: host,
          name: names[host]!,
          lookupEnabled: hostLookup[host] ?? true,
          catalog: <RemoteDictionary>[
            for (final RemoteDictionary r in rows)
              if (r.hostId == host) r,
          ],
        ),
    ];
  }

  @override
  Future<void> setRemoteDictionaryHostLookupEnabled(
    String hostId,
    bool enabled,
  ) async {
    hostLookupWrites.add((hostId, enabled));
    hostLookup[hostId] = enabled;
  }

  @override
  Future<void> refreshRemoteDictionaryHost(String hostId) async =>
      refreshedHosts.add(hostId);

  @override
  Map<String, RemoteDictionaryHostReachability>
  get remoteDictionaryHostReachability => reachability;

  @override
  bool get canRefreshRemoteDictionaries => true;

  @override
  Future<String?> activeProfileName() async => 'Default';

  @override
  Future<void> showProfilesMenu() async => profilesOpened++;

  @override
  Future<void> setRemoteDictionaryLocalDisplayName(
    RemoteDictionary dictionary,
    String? displayName,
  ) async {
    localNameWrites.add((dictionary.name, displayName));
    remote = <RemoteDictionary>[
      for (final RemoteDictionary r in remote)
        r.key == dictionary.key
            ? RemoteDictionary(
                hostId: r.hostId,
                name: r.name,
                type: r.type,
                order: r.order,
                lastSeenAt: r.lastSeenAt,
                hidden: r.hidden,
                revision: r.revision,
                sourceLanguage: r.sourceLanguage,
                missingSince: r.missingSince,
                localDisplayName: displayName,
              )
            : r,
    ];
  }

  @override
  Map<String, bool> get remoteDictionaryConfigAppliedByHost =>
      const <String, bool>{'h1': false};

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
  Future<void> setDictionaryHidden(Dictionary dictionary, bool hidden) async {
    store.firstWhere((Dictionary d) => d.name == dictionary.name)
      .hiddenLanguages = hidden ? <String>['ja'] : <String>[];
    dictionary.hiddenLanguages = hidden ? <String>['ja'] : <String>[];
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

  /// 「推送到 / 下载到本机」的假服务；null = 弹窗进程（没有这两个动作）。
  _FakeTransferService? transfer = _FakeTransferService();

  @override
  DictionaryTransferService? get dictionaryTransferService => transfer;

  @override
  Future<Set<String>> remoteDictionaryPushHostIds() async => <String>{
    'h1',
    'h2',
  };

  final List<DictionaryDownloadOutcome> outcomes =
      <DictionaryDownloadOutcome>[];

  late final DictionaryDownloadController _downloads =
      DictionaryDownloadController(showOutcome: outcomes.add);

  @override
  DictionaryDownloadController get dictionaryDownloadController => _downloads;

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

class _FakeTransferService implements DictionaryTransferService {
  final List<(String, String)> pushes = <(String, String)>[];
  final List<(String, String)> downloads = <(String, String)>[];
  DictionaryTransferResult result = const DictionaryTransferDone();

  @override
  Future<DictionaryTransferResult> pushToHost(
    String hostId,
    String dictionaryName, {
    void Function(DictionaryTransferProgress progress)? onProgress,
  }) async {
    pushes.add((hostId, dictionaryName));
    onProgress?.call(
      const DictionaryTransferProgress(
        stage: DictionaryTransferStage.transferring,
        fraction: 0.5,
      ),
    );
    return result;
  }

  @override
  Future<DictionaryTransferResult> downloadFromHost(
    String hostId,
    String dictionaryName, {
    void Function(DictionaryTransferProgress progress)? onProgress,
  }) async {
    downloads.add((hostId, dictionaryName));
    onProgress?.call(
      const DictionaryTransferProgress(
        stage: DictionaryTransferStage.importing,
      ),
    );
    return result;
  }
}

const int _seenAt = 1762646400000;

List<Dictionary> _local() => <Dictionary>[
  Dictionary(
    name: 'JMdict',
    formatKey: 'yomichan',
    order: 0,
    metadata: const <String, String>{'revision': '6'},
  ),
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
    revision: '7',
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
  List<RemoteDictionary>? remote,
  List<RemoteDictionary>? catalog,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final _FakeAppModel model = _FakeAppModel(
    _local(),
    remote ?? _remote(),
    catalog: catalog,
  );
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

/// 焦点驱动换分区：分区条是单个焦点停靠点（FushiAdjustableSegmented），
/// 方向键 Right 前进一个分区。
Future<void> _stepSection(WidgetTester tester, int steps) async {
  final Finder stop = find.descendant(
    of: find.byType(FushiAdjustableSegmented<DictionaryType>),
    matching: find.byType(ExcludeFocus),
  );
  Focus.of(tester.element(stop.first)).requestFocus();
  await tester.pump();
  for (int i = 0; i < steps; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
  }
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
    Finder chipIn(String key) => find.descendant(
      of: find.byKey(ValueKey<String>('dict-row-source-$key')),
      matching: find.byType(FushiTag),
    );
    // 文字 chip 只给例外状态：两者 / 服务器上已没有 / 旧版服务器（h1 上次没套用
    // 本端选择）；只在本机的行与普通服务器行不画文字 chip。
    expect(chipIn('Local only'), findsNothing);
    expect(
      find.descendant(of: chipIn('JMdict'), matching: find.text('Both')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chipIn(_goneKey),
        matching: find.text('Not on server'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chipIn(_serverKey),
        matching: find.text('Older server'),
      ),
      findsOneWidget,
    );
    // 只有一台参与查词的 host：chip 不写设备名。
    expect(find.text('Both · Box'), findsNothing);
    // 服务器行改由序号徽标上的服务器小图标说明，设备名进 tooltip / Semantics。
    expect(
      find.byKey(const ValueKey<String>('dict-row-server-glyph')),
      findsNWidgets(2),
    );
    expect(
      tester
          .widgetList<DictionaryOrderBadge>(find.byType(DictionaryOrderBadge))
          .map((DictionaryOrderBadge b) => b.serverHostName)
          .toList(),
      <String?>[null, 'Box', null, 'Box'],
    );
    expect(find.bySemanticsLabel('Server · Box'), findsWidgets);
    // 「两者」行版本不同：副标题写明两边版本。
    expect(find.text('Server rev 7, this device rev 6'), findsOneWidget);
    // 同名服务器词典不单独成行：JMdict 只出现一次。
    expect(find.text('JMdict'), findsOneWidget);
    // 来源条（取代列表底部的 host 提示）：状态 / 本数 / 老版本警告。
    expect(
      find.byKey(const ValueKey<String>('dict-server-source-h1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-server-notice-h1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-server-source-older-h1')),
      findsOneWidget,
    );
    expect(find.textContaining('runs an older version'), findsOneWidget);
    expect(find.text('2 of 2 enabled'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('dict-server-source-status-h1')),
          )
          .data,
      startsWith('Last seen '),
    );
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
    // 列表头跟着筛后的行计数。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('dict-list-summary')))
          .data,
      '2 of 4 shown · 2 enabled',
    );

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

  testWidgets('Both row switch mirrors its state to the server copy', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    final Finder toggle = find.byKey(
      const ValueKey<String>('dict-row-switch-JMdict'),
    );
    await _focusInside(tester, toggle);
    await _pressEnter(tester);
    expect(model.hiddenWrites, <(String, bool)>[('JMdict', true)]);
    expect(
      model.remote.firstWhere((RemoteDictionary r) => r.name == 'JMdict').hidden,
      isTrue,
    );
    await _focusInside(tester, toggle);
    await _pressEnter(tester);
    expect(model.hiddenWrites, <(String, bool)>[
      ('JMdict', true),
      ('JMdict', false),
    ]);
    expect(
      model.remote.firstWhere((RemoteDictionary r) => r.name == 'JMdict').hidden,
      isFalse,
    );
    expect(tester.takeException(), isNull);
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

  testWidgets('app bar names the active profile; Enter opens profiles', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    expect(find.text('Profile · Default'), findsOneWidget);
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-profile-subtitle')),
    );
    await _pressEnter(tester);
    expect(model.profilesOpened, 1);
  });

  testWidgets('sources strip: lookup switch, refresh, unreachable status', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-server-source-lookup-h1')),
    );
    await _pressEnter(tester);
    expect(model.hostLookupWrites, <(String, bool)>[('h1', false)]);

    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-server-source-refresh-h1')),
    );
    await _pressEnter(tester);
    expect(model.refreshedHosts, <String>['h1']);

    model.reachability = const <String, RemoteDictionaryHostReachability>{
      'h1': RemoteDictionaryHostReachability(failingSince: _seenAt),
    };
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-server-h1')),
    );
    await _pressEnter(tester);
    // 卡片上只放相对时间（默认宽度下放得下），完整时刻在悬停提示里。
    final Finder status = find.byKey(
      const ValueKey<String>('dict-server-source-status-h1'),
    );
    expect(tester.widget<Text>(status).data, startsWith('Unreachable · '));
    expect(tester.widget<Text>(status).data, endsWith(' ago'));
    expect(
      find.ancestor(
        of: status,
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is FushiTooltip &&
              (w.message ?? '').startsWith('Unreachable since '),
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail pane clears when the section or the filter changes', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester);
    Focus.of(tester.element(find.text('Server Dict'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-$_serverKey')),
      findsOneWidget,
    );
    // 换筛选：侧板回到概览。
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-thisDevice')),
    );
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-$_serverKey')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('dict-overview')), findsOneWidget);

    // 换分区：本机行的详情同样收回。
    Focus.of(tester.element(find.text('Local only'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-Local only')),
      findsOneWidget,
    );
    await _stepSection(tester, 2);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-Local only')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Both row detail shows the server copy and both revisions', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester);
    Focus.of(tester.element(find.text('JMdict'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    final Finder section = find.byKey(
      const ValueKey<String>('dict-detail-server-copy-JMdict'),
    );
    expect(section, findsOneWidget);
    expect(
      find.descendant(of: section, matching: find.text('Version on server')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: section, matching: find.text('7')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: section, matching: find.text('6')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: section, matching: find.text('Box')),
      findsOneWidget,
    );
  });

  testWidgets('local detail offers Push per host that lacks it; Enter pushes', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    // 「Local only」只在本机：两台查词 host 都缺它，各给一行。
    Focus.of(tester.element(find.text('Local only'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-push-h1-Local only')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-detail-push-h2-Local only')),
      findsOneWidget,
    );
    expect(find.text('Push to Laptop'), findsOneWidget);

    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-detail-push-h2-Local only')),
    );
    await _pressEnter(tester);
    await _settle(tester);
    expect(model.transfer!.pushes, <(String, String)>[('h2', 'Local only')]);
    expect(model.outcomes.single.message, 'Local only is now on Laptop');
    expect(model.outcomes.single.severity, ToastSeverity.success);
  });

  testWidgets('Both row hides Push for the host that already has it', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester);
    Focus.of(tester.element(find.text('JMdict'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    // h1 已有 JMdict（「两者」），只剩 h2。
    expect(
      find.byKey(const ValueKey<String>('dict-detail-push-h1-JMdict')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-detail-push-h2-JMdict')),
      findsOneWidget,
    );
  });

  testWidgets('no transfer service: no Push and no Download actions', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    model.transfer = null;
    Focus.of(tester.element(find.text('Server Dict'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-download-$_serverKey')),
      findsNothing,
    );
    Focus.of(tester.element(find.text('Local only'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-transfer-Local only')),
      findsNothing,
    );
  });

  testWidgets('server-only detail: Download to this device; errors toast', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    Focus.of(tester.element(find.text('Server Dict'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    final Finder download = find.byKey(
      const ValueKey<String>('dict-detail-download-$_serverKey'),
    );
    expect(download, findsOneWidget);
    // 已缺席的行不给下载。
    expect(
      find.byKey(const ValueKey<String>('dict-detail-download-$_goneKey')),
      findsNothing,
    );

    model.transfer!.result = const DictionaryTransferFailed(
      DictionaryTransferFailureKind.unreachable,
    );
    await _focusInside(tester, download);
    await _pressEnter(tester);
    await _settle(tester);
    expect(model.transfer!.downloads, <(String, String)>[
      ('h1', 'Server Dict'),
    ]);
    expect(model.outcomes.single.message, 'Could not reach Box');
    expect(model.outcomes.single.severity, ToastSeverity.error);
  });

  testWidgets('server row detail: Source label, language label, local rename', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      remote: const <RemoteDictionary>[
        RemoteDictionary(
          hostId: 'h1',
          name: 'Server Dict',
          type: DictionaryType.term,
          order: 1,
          lastSeenAt: _seenAt,
          sourceLanguage: 'ja',
        ),
      ],
    );
    Focus.of(tester.element(find.text('Server Dict'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    final Finder detail = find.byKey(
      const ValueKey<String>('dict-detail-$_serverKey'),
    );
    expect(detail, findsOneWidget);
    expect(
      find.descendant(of: detail, matching: find.text('Source')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: detail, matching: find.text('Updates')),
      findsNothing,
    );
    // 内容语言与本机词典同一格式。
    expect(
      find.descendant(
        of: detail,
        matching: find.text(
          '${t.dict_language_auto} · ${contentLanguageLabelOf('ja')}',
        ),
      ),
      findsOneWidget,
    );

    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-detail-rename-$_serverKey')),
    );
    await _pressEnter(tester);
    await tester.enterText(find.byType(EditableText), 'My server dict');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(model.localNameWrites, <(String, String?)>[
      ('Server Dict', 'My server dict'),
    ]);
    expect(find.text('My server dict'), findsWidgets);
  });

  testWidgets('kanji note and shadowed copies across two servers', (
    WidgetTester tester,
  ) async {
    const List<RemoteDictionary> remote = <RemoteDictionary>[
      RemoteDictionary(
        hostId: 'h1',
        name: 'Server Dict',
        type: DictionaryType.term,
        order: 1,
        lastSeenAt: _seenAt,
      ),
      RemoteDictionary(
        hostId: 'h2',
        name: 'Server Dict',
        type: DictionaryType.term,
        order: 4,
        lastSeenAt: _seenAt,
      ),
      RemoteDictionary(
        hostId: 'h1',
        name: 'Gone Dict',
        type: DictionaryType.term,
        order: 3,
        lastSeenAt: _seenAt,
        missingSince: _seenAt,
      ),
    ];
    await _pumpPage(
      tester,
      remote: remote,
      catalog: <RemoteDictionary>[
        ...remote,
        const RemoteDictionary(
          hostId: 'h1',
          name: 'KANJIDIC',
          type: DictionaryType.kanji,
          order: 9,
          lastSeenAt: _seenAt,
        ),
      ],
    );
    // 概览的「汉字」格与那条说明说同一件事：本机 0 · 服务器 1。
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('dict-overview-sources-kanji')),
          )
          .data,
      '0 on this device · 1 on server',
    );

    // 两台参与查词的 host：例外 chip 写上设备名。
    expect(find.text('Not on server · Box'), findsOneWidget);
    // 同名只列排得最前的一份；详情说明另一台上也有。
    expect(find.text('Server Dict'), findsOneWidget);
    Focus.of(tester.element(find.text('Server Dict'))).requestFocus();
    await tester.pump();
    await _pressEnter(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-shadowed-$_serverKey')),
      findsOneWidget,
    );
    expect(
      find.text('Also on Laptop; only the first copy is listed'),
      findsOneWidget,
    );

    await _stepSection(tester, 1);
    expect(
      find.text(
        'Server kanji dictionaries are not managed here yet (1 on Box)',
      ),
      findsOneWidget,
    );
    // 有服务器汉字词典的说明时，不再叠一句自相矛盾的「导入一本词典」。
    expect(find.text('Import a dictionary for use'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('kanji section without server kanji keeps the import empty '
      'state', (WidgetTester tester) async {
    await _pumpPage(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-overview-sources-kanji')),
      findsNothing,
    );
    await _stepSection(tester, 1);
    expect(find.text('Import a dictionary for use'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('region-tagged server language: header is the native name '
      'with the full tag', (WidgetTester tester) async {
    await _pumpPage(
      tester,
      remote: const <RemoteDictionary>[
        RemoteDictionary(
          hostId: 'h1',
          name: 'Korean Server',
          type: DictionaryType.term,
          order: 1,
          lastSeenAt: _seenAt,
          sourceLanguage: 'ko-KR',
        ),
      ],
    );
    expect(find.text('한국어 (ko-KR) · 1'), findsOneWidget);
    expect(find.text('ko-KR · 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sources strip follows the filter: hidden under This device, '
      'under Hidden only with a hidden server row', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(tester);
    final Finder strip = find.byKey(
      const ValueKey<String>('dict-server-sources'),
    );
    expect(strip, findsOneWidget, reason: '「全部」下列出服务器行，来源条在');

    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-thisDevice')),
    );
    await _pressEnter(tester);
    expect(strip, findsNothing, reason: '「本机」下不列服务器行，来源条不该出现');

    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-server-h1')),
    );
    await _pressEnter(tester);
    expect(strip, findsOneWidget);

    // 「已隐藏」：此刻没有隐藏的服务器行 → 不出现。
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-hidden')),
    );
    await _pressEnter(tester);
    expect(strip, findsNothing, reason: '没有隐藏的服务器行时「已隐藏」下不出现');

    // 把一本服务器词典隐藏后再看「已隐藏」：出现。
    model.remote = <RemoteDictionary>[
      for (final RemoteDictionary r in model.remote)
        r.name == 'Server Dict' ? r.copyWith(hidden: true) : r,
    ];
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-all')),
    );
    await _pressEnter(tester);
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-source-filter-hidden')),
    );
    await _pressEnter(tester);
    expect(strip, findsOneWidget, reason: '有隐藏的服务器行时「已隐藏」下出现');
    expect(tester.takeException(), isNull);
  });

  // 用户拍板（2026-11-09）：全局「远程查词」并入每台 host 的开关，「远程查词已关闭：
  // 显示但不参与查词」那条条底提示随之删除；卡片上的「开启」就是拨这台 host 的开关。
  testWidgets('host lookup off: card says its dictionaries are not listed; '
      '"Turn on" flips only the host switch', (WidgetTester tester) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      remote: const <RemoteDictionary>[],
      catalog: _remote(),
    );
    model.hostLookup['h1'] = false;
    // 广播一次服务器词典变化：页面整份重读来源条数据。
    DictionaryRepository.remoteDictionariesRevision.value++;
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-server-sources')),
      findsOneWidget,
      reason: '没有服务器行时筛选回落「全部」，来源条照常出现',
    );
    expect(
      find.byKey(const ValueKey<String>('dict-server-source-lookup-off-h1')),
      findsOneWidget,
    );
    expect(find.text(t.dictionary_source_lookup_off_hint), findsOneWidget);
    await _focusInside(
      tester,
      find.byKey(
        const ValueKey<String>('dict-server-source-lookup-turn-on-h1'),
      ),
    );
    await _pressEnter(tester);
    expect(model.hostLookupWrites, <(String, bool)>[('h1', true)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one server: no filter-bar refresh (the card has it)', (
    WidgetTester tester,
  ) async {
    await _pumpPage(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-server-refresh')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-server-source-refresh-h1')),
      findsOneWidget,
    );
  });

  testWidgets('filter bar: refresh-all only when given a callback', (
    WidgetTester tester,
  ) async {
    int refreshed = 0;
    Widget bar({VoidCallback? onRefresh}) => TranslationProvider(
      child: MaterialApp(
        theme: buildFushiFallbackTheme(
          Brightness.light,
        ).copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: DictionarySourceFilterBar(
            hosts: const <String, String>{'h1': 'Box', 'h2': 'Laptop'},
            selected: DictionarySourceFilter.all,
            onSelected: (DictionarySourceFilter _) {},
            onRefresh: onRefresh,
            refreshing: false,
          ),
        ),
      ),
    );
    await tester.pumpWidget(bar());
    expect(
      find.byKey(const ValueKey<String>('dict-server-refresh')),
      findsNothing,
    );
    await tester.pumpWidget(bar(onRefresh: () => refreshed++));
    await tester.pump();
    await _focusInside(
      tester,
      find.byKey(const ValueKey<String>('dict-server-refresh')),
    );
    await _pressEnter(tester);
    expect(refreshed, 1);
  });
}
