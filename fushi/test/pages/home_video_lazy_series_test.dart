// 媒体服务器剧名合集「懒收养」（BUG-5601）的视频库页层验证。
//
// 媒体服务器（[DerivedSeriesGroupingSource]）的清单不再收养进库：库页按剧名叠加出
// 负 id 的虚拟合集，用户在虚拟组上做写入动作时库层经
// `VirtualCollectionHooks.materialize` 先把整部剧物化成真合集。本文件驱动真页面：
// 加载清单后库里零合集、卡数与按剧名折叠一致；进虚拟组详情成员与顺序正确；菜单改名 /
// 手动排序 / 详情页重排各自触发物化，结果落库正确、界面不出重复卡。
//
// 交互一律走焦点：卡片 / 菜单项 / 按钮先拿焦点再按 Enter，确认弹窗用 Enter。没有键盘
// 入口的两处手势（视频卡长按菜单、拖动重排）直接调组件上同一个回调——长按 / 拖动
// 识别器最终调用的就是它，不发坐标点击。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/remote_series_catalog.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_list_store.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/remote_series_overlay.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show decodeShelfManualOrder;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

const String _type = 'playlist';

RemoteVideoInfo _ep(String id, String series, int slot) => RemoteVideoInfo(
  id: id,
  title: id,
  collection: RemoteCollectionMembership(
    collectionName: series,
    collectionType: _type,
    sortIndex: slot,
  ),
);

/// 两部剧 + 一部无归属的电影。Alpha 的目录序（a1, a2, a3）与集序（a2 → a3 → a1）
/// 故意不同：组内序必须按 `sortIndex` 排，不按目录先后。
const List<String> _alphaOrder = <String>['video/a2', 'video/a3', 'video/a1'];

List<RemoteVideoInfo> _catalog() => <RemoteVideoInfo>[
  _ep('video/a1', 'Alpha', 20002),
  _ep('video/a2', 'Alpha', 10001),
  _ep('video/a3', 'Alpha', 10002),
  _ep('video/b1', 'Beta', 10001),
  _ep('video/b2', 'Beta', 10002),
  const RemoteVideoInfo(id: 'video/movie', title: 'Movie'),
];

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_lazy_series_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    RemoteSeriesCatalog.instance.debugReset();
    VirtualCollectionRegistry.instance.debugReset();
    RemoteVideoListStore.debugReset();
    RemoteVideoListStore.debugSetDirResolver(() async => null);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setJellyfinAutoListVideos(true);
    storeDir = Directory.systemTemp.createTempSync('fushi_lazy_series');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    // wireDatabaseForTesting 把本库挂给 VirtualCollectionRegistry：库层写入口遇到
    // 负 id 就经它物化（与 app 打开主库同一接线）。
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    RemoteVideoListStore.debugSetDirResolver(null);
    RemoteSeriesCatalog.instance.debugReset();
    VirtualCollectionRegistry.instance.debugReset();
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Widget buildApp(_FakeMediaServerClient client) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeVideoPage(
            repo: VideoBookRepository(db),
            section: VideoLibrarySection.series,
            remoteVideoClientLoader: () async => client,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    // 顶部 hero / 横滚行之下的墙在矮视口里会被懒构建跳过；抬高视口。
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(_FakeMediaServerClient(_catalog())));
    await tester.pumpAndSettle();
  }

  /// 库页上全部合集卡的 id（显示顺序 = 墙上自上而下、自左而右）。
  List<int> cardIds(WidgetTester tester) {
    const String prefix = 'home_video_collection_card_';
    final List<({int id, Offset at})> cards = <({int id, Offset at})>[
      for (final Element e
          in find
              .byWidgetPredicate(
                (Widget w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(prefix),
              )
              .evaluate())
        (
          id: int.parse(
            (e.widget.key! as ValueKey<String>).value.substring(prefix.length),
          ),
          at: tester.getTopLeft(find.byWidget(e.widget)),
        ),
    ];
    cards.sort(
      (({int id, Offset at}) a, ({int id, Offset at}) b) => a.at.dy != b.at.dy
          ? a.at.dy.compareTo(b.at.dy)
          : a.at.dx.compareTo(b.at.dx),
    );
    return <int>[for (final ({int id, Offset at}) c in cards) c.id];
  }

  Finder card(int id) =>
      find.byKey(ValueKey<String>('home_video_collection_card_$id'));

  /// 库页合集卡 id → 合集名（虚拟行查登记表，真行查库）。
  Future<Map<String, int>> cardIdsByName(WidgetTester tester) async {
    final Map<String, int> out = <String, int>{};
    for (final int id in cardIds(tester)) {
      final MediaCollectionRow? row = id < 0
          ? VirtualCollectionRegistry.instance.rowOf(id)
          : await db.getMediaCollectionById(id);
      out[row!.name] = id;
    }
    return out;
  }

  /// [target] 的焦点节点：控件自带的（卡片 / 按钮的 Focus 在它下面）优先，否则取
  /// 包着它的那个（菜单项文字在可聚焦行里面）。
  FocusNode focusNodeOf(WidgetTester tester, Finder target) {
    for (final Element e
        in find
            .descendant(of: target, matching: find.byType(Focus))
            .evaluate()) {
      FocusNode? node;
      e.visitChildElements(
        (Element child) =>
            node ??= Focus.maybeOf(child, createDependency: false),
      );
      if (node != null && node!.canRequestFocus && !node!.skipTraversal) {
        return node!;
      }
    }
    return Focus.of(tester.element(target), createDependency: false);
  }

  /// 焦点落到 [target] 所在的可聚焦控件上再按 Enter（与键盘 / 手柄 A 同一条路）。
  Future<void> activate(WidgetTester tester, Finder target) async {
    expect(target, findsOneWidget);
    focusNodeOf(tester, target).requestFocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      focusNodeOf(tester, target),
      reason: '焦点必须真的落到目标上，Enter 才是对它按的',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  /// 卡片菜单：视频卡没有键盘唤菜单的入口，调长按回调本身（不发坐标手势）。
  Future<void> openCardMenu(WidgetTester tester, int id) async {
    tester.widget<FushiCard>(card(id)).onLongPress!();
    await tester.pumpAndSettle();
  }

  Future<void> renameViaMenu(WidgetTester tester, int id, String name) async {
    await openCardMenu(tester, id);
    await activate(tester, find.text(t.rename_collection));
    await tester.enterText(find.byType(EditableText), name);
    // 输入框里的回车经输入法回报为「完成」动作（onSubmitted），不是硬件键事件。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<List<String>> itemKeys(int collectionId) async => <String>[
    for (final MediaCollectionItemRow m in await db.getCollectionItems(
      collectionId,
    ))
      m.entryKey,
  ];

  testWidgets('加载媒体服务器清单：库里零合集，墙上按剧名折成两张虚拟合集卡', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(
      await db.getAllMediaCollections(),
      isEmpty,
      reason: 'BUG-5601：媒体服务器目录不再被动收养进库',
    );
    final List<int> ids = cardIds(tester);
    expect(ids, hasLength(2), reason: 'Alpha / Beta 两部剧各一张卡，电影无归属不成组');
    expect(ids, everyElement(isNegative), reason: '临时分组是负 id 的虚拟合集');
    final Map<String, int> byName = await cardIdsByName(tester);
    expect(byName.keys.toSet(), <String>{'Alpha', 'Beta'});
    expect(
      find.descendant(
        of: card(byName['Alpha']!),
        matching: find.text(t.collection_watched_progress(done: 0, total: 3)),
      ),
      findsOneWidget,
      reason: 'Alpha 三集全折进这一张卡',
    );
    expect(
      find.descendant(
        of: card(byName['Beta']!),
        matching: find.text(t.collection_watched_progress(done: 0, total: 2)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('点开虚拟组卡片进详情：成员齐全、按集序排列，且不落库', (WidgetTester tester) async {
    await pumpPage(tester);
    final int alpha = (await cardIdsByName(tester))['Alpha']!;

    await activate(tester, card(alpha));

    expect(find.byType(MediaCollectionDetailPage), findsOneWidget);
    final FushiReorderableGrid grid = tester.widget<FushiReorderableGrid>(
      find.descendant(
        of: find.byType(MediaCollectionDetailPage),
        matching: find.byType(FushiReorderableGrid),
      ),
    );
    expect(
      <String>[
        for (int i = 0; i < grid.itemCount; i++)
          (grid.keyForIndex(i) as ValueKey<String>).value,
      ],
      <String>[for (final String k in _alphaOrder) 'collection-episode-row-$k'],
    );
    expect(await db.getAllMediaCollections(), isEmpty, reason: '只读浏览不物化');
  });

  testWidgets('菜单改名虚拟组：物化成改名后的真合集，成员齐全且钉住，墙上只一张卡', (WidgetTester tester) async {
    await pumpPage(tester);
    final int alpha = (await cardIdsByName(tester))['Alpha']!;

    await renameViaMenu(tester, alpha, 'My Alpha');

    final List<MediaCollectionRow> rows = await db.getAllMediaCollections();
    expect(
      <String>[for (final MediaCollectionRow r in rows) r.name],
      <String>['My Alpha'],
      reason: '只物化被改名的那部剧，Beta 仍是临时分组',
    );
    final MediaCollectionRow real = rows.single;
    expect(real.collectionType, _type);
    final List<MediaCollectionItemRow> items = await db.getCollectionItems(
      real.id,
    );
    expect(<String>[
      for (final MediaCollectionItemRow m in items) m.entryKey,
    ], _alphaOrder);
    expect(
      items.map((MediaCollectionItemRow m) => m.pinnedByUser),
      everyElement(isTrue),
      reason: '物化 = 用户认领：成员钉住，存量清理据此保留',
    );

    final Map<String, int> byName = await cardIdsByName(tester);
    expect(byName.keys.toSet(), <String>{'My Alpha', 'Beta'});
    expect(byName['My Alpha'], real.id, reason: '改名后的卡就是真合集');
    expect(cardIds(tester), hasLength(2), reason: '旧剧名不再另起一张虚拟卡');
    expect(find.text('Alpha'), findsNothing);
    expect(
      find.descendant(
        of: card(real.id),
        matching: find.text(t.collection_watched_progress(done: 0, total: 3)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('手动排序拖过虚拟组 → 改名物化后名次沿用', (WidgetTester tester) async {
    await pumpPage(tester);
    final Map<String, int> before = await cardIdsByName(tester);
    // 把排在最前的那张合集卡拖到末尾（菜单「排序」进排序模式，拖动 = 网格
    // onReorder）。拖到末尾而不是最前：没有名次的单元排在最前，名次丢了才看得出来。
    final int moved = cardIds(tester).first;
    final String movedName = before.entries
        .firstWhere((MapEntry<String, int> e) => e.value == moved)
        .key;
    final String otherName = movedName == 'Alpha' ? 'Beta' : 'Alpha';
    final String movedKey = 's:$_type:$movedName';
    await openCardMenu(tester, moved);
    await activate(tester, find.text(t.library_reorder_action));
    final FushiReorderableGrid grid = tester.widget<FushiReorderableGrid>(
      find.byKey(const ValueKey<String>('home_video_reorder_grid')),
    );
    final List<String> units = <String>[
      for (int i = 0; i < grid.itemCount; i++)
        (grid.keyForIndex(i) as ValueKey<String>).value,
    ];
    expect(units, contains(movedKey), reason: '虚拟组在排序网格里按自然键出现');
    grid.onReorder(units.indexOf(movedKey), units.length - 1);
    await tester.pumpAndSettle();
    await activate(
      tester,
      find.byKey(const ValueKey<String>('library_reorder_done')),
    );

    final Map<String, int> ranks = decodeShelfManualOrder(
      prefs.libraryManualOrder('video'),
    );
    expect(
      ranks.keys.where((String k) => k.startsWith('c')),
      isEmpty,
      reason: '负 id 不进手动序',
    );
    expect(
      ranks.keys.where((String k) => k.startsWith('s:')).toList(),
      <String>['s:$_type:$otherName', movedKey],
      reason: '虚拟组按自然键记名次（负 id 只在本会话稳定）',
    );
    expect(cardIds(tester).last, moved, reason: '拖动生效');

    // 改名 = 物化 + 换名：真合集的当前名对不上 `s:` 键，名次要跟着搬到 `c<id>`。
    await renameViaMenu(tester, moved, 'Renamed');

    final MediaCollectionRow real = (await db.getAllMediaCollections()).single;
    expect(real.name, 'Renamed');
    expect(cardIds(tester), hasLength(2));
    expect(
      cardIds(tester).last,
      real.id,
      reason: '物化（且改了名）后的真合集沿用拖出来的名次，不跳回最前',
    );
    final Map<String, int> after = decodeShelfManualOrder(
      prefs.libraryManualOrder('video'),
    );
    expect(after.containsKey(movedKey), isFalse, reason: '旧自然键的名次已搬走');
    expect(
      after.keys
          .where((String k) => k == 's:$_type:$otherName' || k == 'c${real.id}')
          .toList(),
      <String>['s:$_type:$otherName', 'c${real.id}'],
      reason: '名次换到真合集名下，先后不变',
    );
  });

  testWidgets('详情页重排虚拟组的集 → 物化整部剧并按新顺序落库', (WidgetTester tester) async {
    await pumpPage(tester);
    final int alpha = (await cardIdsByName(tester))['Alpha']!;
    await activate(tester, card(alpha));
    expect(find.byType(MediaCollectionDetailPage), findsOneWidget);

    // 把末集（a1）拖到最前。
    final Finder detailGrid = find.descendant(
      of: find.byType(MediaCollectionDetailPage),
      matching: find.byType(FushiReorderableGrid),
    );
    tester.widget<FushiReorderableGrid>(detailGrid).onReorder(2, 0);
    await tester.pumpAndSettle();

    final MediaCollectionRow real = (await db.getAllMediaCollections()).single;
    expect(real.name, 'Alpha');
    expect(await itemKeys(real.id), <String>[
      'video/a1',
      'video/a2',
      'video/a3',
    ], reason: '整部剧落库，顺序是拖完的顺序');
    expect(
      (await db.getCollectionItems(
        real.id,
      )).map((MediaCollectionItemRow m) => m.pinnedByUser),
      everyElement(isTrue),
    );
    final FushiReorderableGrid after = tester.widget<FushiReorderableGrid>(
      detailGrid,
    );
    expect(
      <String>[
        for (int i = 0; i < after.itemCount; i++)
          (after.keyForIndex(i) as ValueKey<String>).value,
      ],
      <String>[
        'collection-episode-row-video/a1',
        'collection-episode-row-video/a2',
        'collection-episode-row-video/a3',
      ],
      reason: '详情页接着显示新顺序（持有旧负 id 也读到真合集）',
    );

    // 回库页：只剩这一张真合集卡 + Beta 的虚拟卡，没有重复。
    // 系统返回（Android 返回键 / 桌面返回）。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MediaCollectionDetailPage), findsNothing);
    final Map<String, int> byName = await cardIdsByName(tester);
    expect(byName, <String, int>{'Alpha': real.id, 'Beta': byName['Beta']!});
    expect(byName['Beta'], isNegative);
    expect(cardIds(tester), hasLength(2));
    expect(await itemKeys(real.id), hasLength(3));
  });

  testWidgets('改名物化后移出一集：不以旧剧名冒出分组，被移出的集散着显示', (WidgetTester tester) async {
    await pumpPage(tester);
    final int alpha = (await cardIdsByName(tester))['Alpha']!;
    await renameViaMenu(tester, alpha, 'My Alpha');
    final MediaCollectionRow real = (await db.getAllMediaCollections()).single;

    // 详情页里把 a1 移出合集（集卡菜单 → 「移出合集」→ 确认弹窗）。
    await activate(tester, card(real.id));
    expect(find.byType(MediaCollectionDetailPage), findsOneWidget);
    final FushiReorderableGrid grid = tester.widget<FushiReorderableGrid>(
      find.descendant(
        of: find.byType(MediaCollectionDetailPage),
        matching: find.byType(FushiReorderableGrid),
      ),
    );
    final int a1 = <String>[
      for (int i = 0; i < grid.itemCount; i++)
        (grid.keyForIndex(i) as ValueKey<String>).value,
    ].indexOf('collection-episode-row-video/a1');
    // 集卡没有键盘唤菜单的入口：调网格的右键 / 长按回调本身。
    grid.onContextMenu!(a1, Offset.zero);
    await tester.pumpAndSettle();
    if (find.text(t.collection_remove_member).evaluate().isEmpty) {
      await activate(
        tester,
        find.byKey(const ValueKey<String>('item_menu_more')),
      );
    }
    await activate(tester, find.text(t.collection_remove_member));
    // 确认弹窗：确认按钮与标题同文案，按钮在页脚、排在最后。
    await activate(tester, find.text(t.collection_remove_member).last);
    expect(await itemKeys(real.id), <String>['video/a2', 'video/a3']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    void expectNoGhost(String when) {
      expect(
        find.byKey(const ValueKey<String>('remote_video_card_video_a1')),
        findsOneWidget,
        reason: '$when：移出的那一集散着显示',
      );
      expect(cardIds(tester), hasLength(2), reason: '$when：只有 My Alpha 与 Beta');
      expect(find.text('Alpha'), findsNothing, reason: '$when：旧剧名不另起分组');
    }

    expectNoGhost('移出之后');
    expect((await cardIdsByName(tester)).keys.toSet(), <String>{
      'My Alpha',
      'Beta',
    });

    expect(await db.getAllMediaCollections(), hasLength(1), reason: '移出不另建合集');
  });
}

/// 媒体服务器假来源：`implements JellyfinVideoClient` → 同时是
/// [DerivedSeriesGroupingSource]，库页走临时分组、不收养。只实现库页与详情页这条路径
/// 用到的成员，其余经 [noSuchMethod] 报出来。
class _FakeMediaServerClient implements JellyfinVideoClient {
  _FakeMediaServerClient(this._library);

  final List<RemoteVideoInfo> _library;

  @override
  String get remoteLibrarySourceId => 'jellyfin:http://nas:8096|u1';

  @override
  String get coverCacheNamespace => 'jellyfin-test';

  @override
  Future<String?> takeRemoteLibraryStamp() async => null;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => _library;

  @override
  Future<List<RemoteVideoInfo>> remoteVideosByIds(List<String> ids) async =>
      <RemoteVideoInfo>[
        for (final RemoteVideoInfo v in _library)
          if (ids.contains(v.id)) v,
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
