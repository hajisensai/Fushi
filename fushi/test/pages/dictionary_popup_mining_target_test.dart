import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_mining_target.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi_anki/fushi_anki.dart'
    show AnkiDeck, AnkiSettings, BaseAnkiRepository;
import 'package:fushi_core/fushi_core.dart' show ProfileRow;
import 'package:material_ui/material_ui.dart';

ProfileRow _profile(int id, String name) =>
    ProfileRow(id: id, name: name, createdAt: 0, updatedAt: 0);

/// 制卡目标菜单背后的「仓库真值」：测试按需改它、按需放行两个视图模型的异步装载。
class _MiningWorld {
  _MiningWorld({
    required this.ankiSettings,
    required this.profiles,
    required this.activeProfileId,
    bool loaded = true,
  }) {
    if (loaded) releaseLoads();
  }

  AnkiSettings ankiSettings;
  List<ProfileRow> profiles;
  int activeProfileId;

  /// 两个视图模型的装载闸门：未放行前它们停在构造时的空态（= 生产里异步装载中）。
  Completer<void> ankiGate = Completer<void>();
  Completer<void> profileGate = Completer<void>();

  void releaseLoads() {
    if (!ankiGate.isCompleted) ankiGate.complete();
    if (!profileGate.isCompleted) profileGate.complete();
  }

  /// 换一组没放行的闸门：模拟切配置时 provider 被 invalidate 后重新装载。
  void rearmLoads() {
    ankiGate = Completer<void>();
    profileGate = Completer<void>();
  }
}

class _FakeAnkiRepository implements BaseAnkiRepository {
  _FakeAnkiRepository(this._world);
  final _MiningWorld _world;

  @override
  bool get switchesAppPerNote => false;

  @override
  Future<AnkiSettings> loadSettings() async {
    await _world.ankiGate.future;
    return _world.ankiSettings;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository(this._world);
  final _MiningWorld _world;

  @override
  Future<void> ensureDefaultProfile() async {}

  @override
  Future<List<ProfileRow>> getAllProfiles() async {
    await _world.profileGate.future;
    return _world.profiles;
  }

  @override
  Future<int> getActiveProfileId() async => _world.activeProfileId;

  @override
  Future<Map<String, int>> getAllMediaTypeBindings() async =>
      const <String, int>{};

  @override
  Future<Map<String, int>> getAllLanguageBindings() async =>
      const <String, int>{};

  @override
  Stream<void> watchProfilesChanged() => const Stream<void>.empty();

  @override
  Future<void> snapshotCurrentSettings(int profileId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 与生产同形的接线：配置仓库 watch Anki 仓库，invalidate Anki 仓库会把两个视图
/// 模型一起重建（`ProfileViewModel` 的 onApplied 正是这么做的）。
List<Override> _overrides(_MiningWorld world) => <Override>[
  ankiRepositoryProvider.overrideWith((Ref ref) => _FakeAnkiRepository(world)),
  profileRepositoryProvider.overrideWith((Ref ref) {
    ref.watch(ankiRepositoryProvider);
    return _FakeProfileRepository(world);
  }),
];

/// 用户建议 #fiwDIpFep7：查词弹窗顶栏就地切换制卡目标（配置 / 牌组）。
void main() {
  group('buildDictionaryPopupMiningTargetItems', () {
    test('配置一节 + 牌组一节，当前项打勾，节间有分隔', () {
      final List<PopupMenuEntry<DictionaryPopupMiningTarget>> items =
          buildDictionaryPopupMiningTargetItems(
            profiles: <ProfileRow>[
              _profile(1, 'Default'),
              _profile(2, 'Lapis'),
            ],
            activeProfileId: 2,
            decks: const <AnkiDeck>[
              AnkiDeck(id: 10, name: 'Mining'),
              AnkiDeck(id: 11, name: 'Audio'),
            ],
            selectedDeckId: 10,
          );
      final List<CheckedPopupMenuItem<DictionaryPopupMiningTarget>> checked =
          items
              .whereType<CheckedPopupMenuItem<DictionaryPopupMiningTarget>>()
              .toList();
      expect(
        checked
            .map(
              (CheckedPopupMenuItem<DictionaryPopupMiningTarget> i) => i.value,
            )
            .toList(),
        <DictionaryPopupMiningTarget>[
          const DictionaryPopupProfileTarget(1),
          const DictionaryPopupProfileTarget(2),
          const DictionaryPopupDeckTarget(AnkiDeck(id: 10, name: 'Mining')),
          const DictionaryPopupDeckTarget(AnkiDeck(id: 11, name: 'Audio')),
        ],
      );
      expect(
        checked
            .map(
              (CheckedPopupMenuItem<DictionaryPopupMiningTarget> i) =>
                  i.checked,
            )
            .toList(),
        <bool>[false, true, true, false],
      );
      expect(items.whereType<PopupMenuDivider>(), hasLength(1));
    });

    test('没有任何候选：只给一条不可点的提示，不弹空菜单', () {
      final List<PopupMenuEntry<DictionaryPopupMiningTarget>> items =
          buildDictionaryPopupMiningTargetItems(
            profiles: const <ProfileRow>[],
            activeProfileId: -1,
            decks: const <AnkiDeck>[],
            selectedDeckId: null,
          );
      expect(items, hasLength(1));
      final PopupMenuItem<DictionaryPopupMiningTarget> only =
          items.single as PopupMenuItem<DictionaryPopupMiningTarget>;
      expect(only.enabled, isFalse);
      expect((only.child! as Text).data, t.popup_mining_target_empty);
    });
  });

  group('dictionaryPopupMiningTargetReady', () {
    test('任一视图模型还在异步首装：不就绪（空列表不是真值）', () {
      const AnkiUiState ankiLoaded = AnkiUiState(settingsLoaded: true);
      const AnkiUiState ankiLoading = AnkiUiState();
      const ProfileUiState profilesLoaded = ProfileUiState();
      const ProfileUiState profilesLoading = ProfileUiState(isLoading: true);
      expect(
        dictionaryPopupMiningTargetReady(
          anki: ankiLoaded,
          profiles: profilesLoaded,
        ),
        isTrue,
      );
      expect(
        dictionaryPopupMiningTargetReady(
          anki: ankiLoading,
          profiles: profilesLoaded,
        ),
        isFalse,
      );
      expect(
        dictionaryPopupMiningTargetReady(
          anki: ankiLoaded,
          profiles: profilesLoading,
        ),
        isFalse,
      );
    });
  });

  group('runDictionaryPopupMiningTargetSwitch', () {
    test('写入失败：不抛出、记日志并给用户一条失败提示', () async {
      final List<String> notified = <String>[];
      final bool ok = await runDictionaryPopupMiningTargetSwitch(
        () async => throw StateError('db locked'),
        notifyFailure: notified.add,
      );
      expect(ok, isFalse);
      expect(notified, hasLength(1));
      expect(notified.single, contains('db locked'));
    });

    test('写入成功：不提示', () async {
      final List<String> notified = <String>[];
      final bool ok = await runDictionaryPopupMiningTargetSwitch(
        () async {},
        notifyFailure: notified.add,
      );
      expect(ok, isTrue);
      expect(notified, isEmpty);
    });
  });

  Future<void> pumpLayer(
    WidgetTester tester, {
    required bool show,
    required double width,
    _MiningWorld? world,
  }) async {
    final _MiningWorld w =
        world ??
        _MiningWorld(
          ankiSettings: const AnkiSettings(),
          profiles: <ProfileRow>[_profile(1, 'Default')],
          activeProfileId: 1,
        );
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(w),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 240,
                child: DictionaryPopupLayer(
                  result: null,
                  isSearching: false,
                  webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
                  headerWidget: const SizedBox(
                    key: Key('test-popup-header'),
                    width: 96,
                    height: 40,
                  ),
                  showMiningTargetSwitch: show,
                  onClose: () {},
                  onDismiss: () {},
                  onTextSelected: (String text, Rect rect, List<Object?> _) {},
                  onLinkClick: (String query, Rect rect) {},
                  onMineEntry: (Map<String, String> fields) async =>
                      const MinePopupResult(),
                  onDuplicateCheck: (String expression, String reading) async =>
                      false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  final Finder button = find.byKey(
    const ValueKey<String>('popup_mining_target'),
  );

  /// 菜单里所有可勾选项 → 是否打勾（菜单没弹出时为空）。
  Map<DictionaryPopupMiningTarget, bool> menuChecks(
    WidgetTester tester,
  ) => <DictionaryPopupMiningTarget, bool>{
    for (final CheckedPopupMenuItem<DictionaryPopupMiningTarget> item
        in tester.widgetList<CheckedPopupMenuItem<DictionaryPopupMiningTarget>>(
          find.byType(CheckedPopupMenuItem<DictionaryPopupMiningTarget>),
        ))
      item.value!: item.checked,
  };

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> closeMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(790, 590));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('制卡宿主的顶栏出现切换键，且不压到居中 header', (WidgetTester tester) async {
    for (final double width in <double>[
      kLookupPopupMinWidth,
      kDictionaryPopupTopBarCompactWidth + 40,
    ]) {
      await pumpLayer(tester, show: true, width: width);
      expect(tester.takeException(), isNull);
      expect(button, findsOneWidget, reason: 'width=$width');
      final Rect header = tester.getRect(
        find.byKey(const Key('test-popup-header')),
      );
      expect(
        tester.getRect(button).right,
        lessThanOrEqualTo(header.left + 0.5),
        reason: 'width=$width：左簇不得压到居中 header',
      );
    }
  });

  testWidgets('不制卡的层（默认）不出现切换键', (WidgetTester tester) async {
    await pumpLayer(tester, show: false, width: 400);
    expect(button, findsNothing);
  });

  const AnkiDeck mining = AnkiDeck(id: 10, name: 'Mining');
  const AnkiDeck audio = AnkiDeck(id: 11, name: 'Audio');

  // 审查 PR #2083：菜单曾在打开时 ref.read 两个异步装载的视图模型——本会话第一次
  // 点开时 AnkiViewModel 还是构造时的空态，牌组一节整个不出。
  testWidgets('首次打开：装载完成前不可点，完成后牌组与配置两节都在且勾选正确', (WidgetTester tester) async {
    final _MiningWorld world = _MiningWorld(
      ankiSettings: const AnkiSettings(
        availableDecks: <AnkiDeck>[mining, audio],
        selectedDeckId: 10,
      ),
      profiles: <ProfileRow>[_profile(1, 'Default'), _profile(2, 'Lapis')],
      activeProfileId: 1,
      loaded: false,
    );
    await pumpLayer(tester, show: true, width: 400, world: world);

    // 装载中：按钮不可点，不会弹出缺节的菜单，更不会误报「没有可选项」。
    await openMenu(tester);
    expect(menuChecks(tester), isEmpty);
    expect(find.text(t.popup_mining_target_empty), findsNothing);

    world.releaseLoads();
    await tester.pump();
    await tester.pump();

    await openMenu(tester);
    expect(menuChecks(tester), <DictionaryPopupMiningTarget, bool>{
      const DictionaryPopupProfileTarget(1): true,
      const DictionaryPopupProfileTarget(2): false,
      const DictionaryPopupDeckTarget(mining): true,
      const DictionaryPopupDeckTarget(audio): false,
    });
  });

  // 审查 PR #2083：切配置会 invalidate ankiRepositoryProvider，两个视图模型重建成
  // 空态再装载；菜单必须等新真值，而不是拿重建后的空态（牌组节消失 / 勾错）。
  testWidgets('切配置后再打开：取的是新配置的真值', (WidgetTester tester) async {
    final _MiningWorld world = _MiningWorld(
      ankiSettings: const AnkiSettings(
        availableDecks: <AnkiDeck>[mining, audio],
        selectedDeckId: 10,
      ),
      profiles: <ProfileRow>[_profile(1, 'Default'), _profile(2, 'Lapis')],
      activeProfileId: 1,
    );
    await pumpLayer(tester, show: true, width: 400, world: world);
    await openMenu(tester);
    expect(menuChecks(tester)[const DictionaryPopupDeckTarget(mining)], isTrue);
    await closeMenu(tester);

    // 切到配置 2：它的快照里牌组是 Audio。照生产路径 invalidate Anki 仓库。
    world
      ..rearmLoads()
      ..activeProfileId = 2
      ..ankiSettings = const AnkiSettings(
        availableDecks: <AnkiDeck>[mining, audio],
        selectedDeckId: 11,
      );
    ProviderScope.containerOf(
      tester.element(button),
    ).invalidate(ankiRepositoryProvider);
    await tester.pump();
    await tester.pump();

    // 重建后的空态期间：不可点。
    await openMenu(tester);
    expect(menuChecks(tester), isEmpty);

    world.releaseLoads();
    await tester.pump();
    await tester.pump();

    await openMenu(tester);
    expect(menuChecks(tester), <DictionaryPopupMiningTarget, bool>{
      const DictionaryPopupProfileTarget(1): false,
      const DictionaryPopupProfileTarget(2): true,
      const DictionaryPopupDeckTarget(mining): false,
      const DictionaryPopupDeckTarget(audio): true,
    });
  });
}
