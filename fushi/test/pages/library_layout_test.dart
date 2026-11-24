import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/collections/book_continue.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart'
    show filterShelfEntriesByMangaSplit;
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi_core/fushi_core.dart' show BookTagRow;
import 'package:fushi_engine/media/collections/shelf_sort.dart';

import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_layout.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_scope_bar.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_library_title_menu.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_sidebar_library_section.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_grid_zoom.dart';
import 'package:fushi/src/pages/implementations/library_layout/material/material_library_layout.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem, AppleSidebarSection, AppleSidebarTabsShell;
import 'package:fushi/src/utils/adaptive/apple_sidebar_library_host.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot, FushiShellTitleScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/components/section_tab_order.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// Cupertino 库页独立布局（2026-11-24 用户拍板方案 A + C 的缩放）守卫：
///
/// - [LibraryLayout] 只按 `isGlassDesign` 分派：M3E 主题恒走
///   [MaterialLibraryLayout]（任何平台），Cupertino 主题走 [AppleLibraryLayout]；
/// - Apple：大标题下拉菜单切一级分组、标题下分区胶囊行切二级、macOS 档侧栏
///   承载分区时内容区不再画胶囊行；
/// - 网格缩放的逐档换算、侧栏子项的组装、Apple 叠层不画扇形。
class _MemoryStore implements SectionTabOrderStore {
  _MemoryStore(this.ids);

  List<String> ids;

  @override
  List<String> read(String orderKey) => ids;

  @override
  Future<void> write(String orderKey, List<String> next) async => ids = next;
}

void main() {
  MediaLibraryViewSpec view(MediaLibraryViewKind kind, String label) =>
      MediaLibraryViewSpec(
        kind: kind,
        label: label,
        builder: (BuildContext context, Widget navigation) =>
            Center(child: Text('body-$label')),
      );

  final List<MediaLibraryViewSpec> views = <MediaLibraryViewSpec>[
    view(MediaLibraryViewKind.library, 'Shelf'),
    view(MediaLibraryViewKind.mediaServers, 'Servers'),
    view(MediaLibraryViewKind.onlineSources, 'Sources'),
    view(MediaLibraryViewKind.extensions, 'Extensions'),
    view(MediaLibraryViewKind.sources, 'Import'),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required bool glass,
    TargetPlatform platform = TargetPlatform.android,
    Size size = const Size(420, 860),
    AppleSidebarLibraryHost? host,
    List<MediaLibraryViewSpec>? withViews,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget shell = MediaLibraryShell(
      focusIdPrefix: 'test-library-view',
      views: withViews ?? views,
    );
    if (host != null) {
      shell = AppleSidebarLibraryScope(host: host, child: shell);
    }
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: glass,
          ).copyWith(platform: platform),
          home: FushiGlassScope(
            child: SectionTabOrderScope(
              store: _MemoryStore(<String>[]),
              child: Scaffold(
                body: FushiShellTitleScope(title: 'Books', child: shell),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('LibraryLayout dispatch', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      testWidgets('M3E theme on ${platform.name} keeps the Material shell', (
        WidgetTester tester,
      ) async {
        await pump(tester, glass: false, platform: platform);
        expect(
          find.byType(MaterialLibraryLayout<MediaLibraryViewKind>),
          findsOneWidget,
        );
        expect(
          find.byType(AppleLibraryLayout<MediaLibraryViewKind>),
          findsNothing,
        );
        // M3E 一级 / 二级照旧是 LibrarySectionTabs（两级页签）。
        expect(
          find.byType(LibrarySectionTabs<MediaLibraryViewKind>),
          findsNWidgets(2),
        );
        expect(
          find.byType(AppleLibraryScopeBar<MediaLibraryViewKind>),
          findsNothing,
        );
      });
    }

    testWidgets('Cupertino theme uses the Apple shell (no M3E tabs)', (
      WidgetTester tester,
    ) async {
      await pump(tester, glass: true);
      expect(
        find.byType(AppleLibraryLayout<MediaLibraryViewKind>),
        findsOneWidget,
      );
      expect(
        find.byType(MaterialLibraryLayout<MediaLibraryViewKind>),
        findsNothing,
      );
      expect(
        find.byType(LibrarySectionTabs<MediaLibraryViewKind>),
        findsNothing,
      );
      // 横滑切分区与导入钮两套都在。
      expect(
        find.byType(SectionSwipeNavigator<MediaLibraryViewKind>),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('test-library-view-import')),
        findsOneWidget,
      );
    });
  });

  group('Apple shell (iOS tier)', () {
    testWidgets('scope bar switches sections inside the current group', (
      WidgetTester tester,
    ) async {
      await pump(tester, glass: true);
      final Finder bar = find.byType(
        AppleLibraryScopeBar<MediaLibraryViewKind>,
      );
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: find.text('Shelf')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('Servers')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(of: bar, matching: find.text('Servers')),
      );
      await tester.pumpAndSettle();
      expect(find.text('body-Servers'), findsOneWidget);
    });

    testWidgets('title menu switches the first-level group', (
      WidgetTester tester,
    ) async {
      await pump(tester, glass: true);
      final Finder title = find.byKey(
        const ValueKey<String>('test-library-view-title-menu'),
      );
      expect(title, findsOneWidget);
      expect(find.byType(AppleLibraryTitleMenu), findsOneWidget);
      await tester.tap(title);
      await tester.pumpAndSettle();
      // 菜单里第二组（在线）。
      await tester.tap(find.text('Online').last);
      await tester.pumpAndSettle();
      expect(find.text('body-Sources'), findsOneWidget);
      // 胶囊行换成在线组的分区。
      final Finder bar = find.byType(
        AppleLibraryScopeBar<MediaLibraryViewKind>,
      );
      expect(
        find.descendant(of: bar, matching: find.text('Extensions')),
        findsOneWidget,
      );
    });

    testWidgets('import toggles and anchors the library group', (
      WidgetTester tester,
    ) async {
      await pump(tester, glass: true);
      await tester.tap(
        find.byKey(const ValueKey<String>('test-library-view-import')),
      );
      await tester.pumpAndSettle();
      expect(find.text('body-Import'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('test-library-view-import')),
      );
      await tester.pumpAndSettle();
      expect(find.text('body-Shelf'), findsOneWidget);
    });
  });

  group('Apple shell (macOS tier with sidebar)', () {
    testWidgets('sidebar hosts the sections; no scope bar in content', (
      WidgetTester tester,
    ) async {
      final AppleSidebarLibraryHost host = AppleSidebarLibraryHost();
      addTearDown(host.dispose);
      host.reportSidebarMode(true);
      await pump(
        tester,
        glass: true,
        platform: TargetPlatform.macOS,
        size: const Size(1280, 800),
        host: host,
      );
      expect(
        find.byType(AppleLibraryScopeBar<MediaLibraryViewKind>),
        findsNothing,
      );
      // 侧栏行：书架 / 媒体服务器 / 在线（折叠成一行），末尾「导入」（导入页拍板第 2 条）。
      expect(
        host.rows.map((AppleSidebarLibraryRow r) => r.label).toList(),
        <String>['Shelf', 'Servers', 'Online', 'Import'],
      );
      expect(host.rows.first.selected, isTrue);
      host.rows[1].onTap();
      await tester.pumpAndSettle();
      expect(find.text('body-Servers'), findsOneWidget);
      // 内容区标题换成当前分区名。
      expect(find.text('Servers'), findsWidgets);
    });

    testWidgets('sidebar collapsed to tab bar: scope bar comes back', (
      WidgetTester tester,
    ) async {
      final AppleSidebarLibraryHost host = AppleSidebarLibraryHost();
      addTearDown(host.dispose);
      host.reportSidebarMode(false);
      await pump(
        tester,
        glass: true,
        platform: TargetPlatform.macOS,
        size: const Size(1280, 800),
        host: host,
      );
      expect(
        find.byType(AppleLibraryScopeBar<MediaLibraryViewKind>),
        findsOneWidget,
      );
    });
  });

  group('appleSidebarLibraryRows', () {
    LibraryChromeSpec<String> spec({
      required String selected,
      required LibrarySectionGroup? currentGroup,
    }) => LibraryChromeSpec<String>(
      title: 'Video',
      groups: const <LibraryChromeGroup<String>>[
        LibraryChromeGroup<String>(
          group: LibrarySectionGroup.library,
          label: 'Library',
          value: 'home',
          members: <LibrarySectionTab<String>>[
            LibrarySectionTab<String>(value: 'home', label: 'Home'),
            LibrarySectionTab<String>(value: 'series', label: 'Series'),
          ],
          subFocusIdPrefix: 'v',
        ),
        LibraryChromeGroup<String>(
          group: LibrarySectionGroup.online,
          label: 'Online',
          value: 'discover',
          members: <LibrarySectionTab<String>>[
            LibrarySectionTab<String>(value: 'discover', label: 'Discover'),
            LibrarySectionTab<String>(value: 'ext', label: 'Extensions'),
          ],
          subFocusIdPrefix: 'v',
        ),
      ],
      selected: selected,
      currentGroup: currentGroup,
      onSelect: (_) {},
      focusIdPrefix: 'v',
      actionsSlot: FushiShellActionsSlot(),
      chrome: FushiFloatingChromeController(),
    );

    List<String> describe(List<AppleSidebarLibraryRow> rows) => <String>[
      for (final AppleSidebarLibraryRow r in rows)
        '${r.depth}:${r.label}${r.selected ? '*' : ''}',
    ];

    test('online group folds into one row outside the group', () {
      final LibraryChromeSpec<String> s = spec(
        selected: 'series',
        currentGroup: LibrarySectionGroup.library,
      );
      expect(
        describe(
          appleSidebarLibraryRows<String>(
            spec: s,
            ordered: (LibraryChromeGroup<String> g) => g.members,
          ),
        ),
        <String>['1:Home', '1:Series*', '1:Online'],
      );
    });

    test('online group expands one level deeper when current', () {
      final LibraryChromeSpec<String> s = spec(
        selected: 'ext',
        currentGroup: LibrarySectionGroup.online,
      );
      expect(
        describe(
          appleSidebarLibraryRows<String>(
            spec: s,
            ordered: (LibraryChromeGroup<String> g) => g.members,
          ),
        ),
        <String>[
          '1:Home',
          '1:Series',
          '1:Online',
          '2:Discover',
          '2:Extensions*',
        ],
      );
    });

    test('import page highlights nothing', () {
      final LibraryChromeSpec<String> s = spec(
        selected: 'home',
        currentGroup: null,
      );
      expect(
        appleSidebarLibraryRows<String>(
          spec: s,
          ordered: (LibraryChromeGroup<String> g) => g.members,
        ).where((AppleSidebarLibraryRow r) => r.selected),
        isEmpty,
      );
    });
  });

  group('libraryGridZoomStep', () {
    const List<int> choices = <int>[4, 5, 6, 7, 8];

    test('zoom in = fewer columns, zoom out = more', () {
      expect(
        libraryGridZoomStep(current: 6, choices: choices, zoomIn: true),
        5,
      );
      expect(
        libraryGridZoomStep(current: 6, choices: choices, zoomIn: false),
        7,
      );
    });

    test('auto column count off the choice list snaps to the neighbour', () {
      // 自动算出 3 列（不在宽档可选里）：放大没有更少的档，缩小到 4。
      expect(
        libraryGridZoomStep(current: 3, choices: choices, zoomIn: true),
        isNull,
      );
      expect(
        libraryGridZoomStep(current: 3, choices: choices, zoomIn: false),
        4,
      );
    });

    test('stops at both ends', () {
      expect(
        libraryGridZoomStep(current: 4, choices: choices, zoomIn: true),
        isNull,
      );
      expect(
        libraryGridZoomStep(current: 8, choices: choices, zoomIn: false),
        isNull,
      );
    });
  });

  group('LibraryGridZoom', () {
    Future<List<int>> pumpZoom(
      WidgetTester tester, {
      required bool glass,
      required TargetPlatform platform,
    }) async {
      final List<int> changes = <int>[];
      final LibraryGridZoomHub hub = LibraryGridZoomHub();
      addTearDown(hub.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: glass,
          ).copyWith(platform: platform),
          home: LibraryGridZoomHubScope(
            hub: hub,
            child: Scaffold(
              body: LibraryGridZoom(
                columns: 5,
                choices: const <int>[4, 5, 6],
                onColumnsChanged: changes.add,
                child: const Focus(autofocus: true, child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return changes;
    }

    testWidgets('two-finger pinch out steps to fewer columns (Apple)', (
      WidgetTester tester,
    ) async {
      final List<int> changes = await pumpZoom(
        tester,
        glass: true,
        platform: TargetPlatform.iOS,
      );
      final Offset c = tester.getCenter(find.byType(SizedBox).last);
      final TestGesture a = await tester.startGesture(c - const Offset(40, 0));
      final TestGesture b = await tester.startGesture(c + const Offset(40, 0));
      await a.moveTo(c - const Offset(80, 0));
      await b.moveTo(c + const Offset(80, 0));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(changes, <int>[4]);
    });

    testWidgets('M3E: pinch does nothing', (WidgetTester tester) async {
      final List<int> changes = await pumpZoom(
        tester,
        glass: false,
        platform: TargetPlatform.iOS,
      );
      final Offset c = tester.getCenter(find.byType(SizedBox).last);
      final TestGesture a = await tester.startGesture(c - const Offset(40, 0));
      final TestGesture b = await tester.startGesture(c + const Offset(40, 0));
      await a.moveTo(c - const Offset(80, 0));
      await b.moveTo(c + const Offset(80, 0));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
    });
  });

  group('ShelfCoverPile', () {
    Future<void> pumpPile(WidgetTester tester, {required bool glass}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: glass,
          ),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 180,
                child: ShelfCoverPile(
                  material: ShelfCoverMaterial.glossyBook,
                  front: ColoredBox(color: Colors.red),
                  behind: <Widget>[
                    ColoredBox(color: Colors.green),
                    ColoredBox(color: Colors.blue),
                    ColoredBox(color: Colors.yellow),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('M3E: books fan out (rotated layers)', (
      WidgetTester tester,
    ) async {
      await pumpPile(tester, glass: false);
      expect(find.byType(AnimatedRotation), findsNWidgets(3));
    });

    testWidgets('Apple: stacked layers, no fan, at most two behind', (
      WidgetTester tester,
    ) async {
      await pumpPile(tester, glass: true);
      expect(find.byType(AnimatedRotation), findsNothing);
      expect(find.byType(ColoredBox), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is ColoredBox && w.color == Colors.yellow,
        ),
        findsNothing,
      );
    });
  });
  group('第 12 项：「继续」只收本库', () {
    MediaItem item(String key, {bool manga = false}) => MediaItem(
      mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(key),
      title: key,
      mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: manga
          ? MangaFushiSource.kUniqueKey
          : ReaderFushiSource.instance.uniqueKey,
      position: 40,
      duration: 100,
      canDelete: false,
      canEdit: true,
    );
    List<String> pick(
      List<MediaItem> all, {
      required bool mangaOnly,
    }) => <String>[
      for (final BookContinueCandidate<MediaItem> c
          in selectMediaItemContinueCandidates(
            // 与书架 `_pickShelfContinue` 同一输入口径：先按本库分架。
            books: filterShelfEntriesByMangaSplit(all, mangaOnly: mangaOnly),
            lastReadAtByUid: const <String, int>{'novel': 1, 'comic': 9},
            epubUidByKey: const <String, String>{},
            completedBookKeys: const <String>{},
            primaryCollectionIdByEntry: const <String, int>{},
            collectionIds: const <int>{},
            memberSortIndex: const <String, int>{},
          ))
        c.item.title,
    ];

    test('书架不出漫画、漫画库不出书（漫画读得更近也一样）', () {
      final List<MediaItem> all = <MediaItem>[
        item('novel'),
        item('comic', manga: true),
      ];
      expect(pick(all, mangaOnly: false), <String>['novel']);
      expect(pick(all, mangaOnly: true), <String>['comic']);
    });
  });

  group('26 项功能在 Apple 外壳里都在', () {
    const BookTagRow tag = BookTagRow(
      id: 7,
      name: 'Favorites',
      colorValue: 0xFF2196F3,
      sortOrder: 0,
      createdAt: 0,
    );
    final TextEditingController search = TextEditingController();
    tearDownAll(search.dispose);

    /// 书架视图的替身：真实的库页工具行（搜索 + 标签 / 排序 / 筛选 / 选择）、
    /// 网格缩放、选择模式底栏与空状态，挂在真实的 [MediaLibraryShell] 下。
    final List<int> toggledTags = <int>[];

    FushiTagFilterBar tagBar(FushiTagFilterBarPart part, bool selecting) =>
        FushiTagFilterBar(
          tags: const <BookTagRow>[tag],
          part: part,
          tagsInMenu: true,
          onToggleFilter: toggledTags.add,
          onReorder: (_, __) async {},
          selectionMode: selecting,
          onToggleSelectionMode: () {},
          sortMode: ShelfSortMode.recent,
          sortModeLabel: (ShelfSortMode m) => 'sort-${m.name}',
          onSortModeChanged: (_) {},
          filterOptionsTitle: 'Status',
          filterOptions: <LibraryViewOption>[
            LibraryViewOption(label: 'All', selected: true, onSelected: () {}),
          ],
        );

    Widget shelfBody({required bool selecting}) => Column(
      children: <Widget>[
        LibraryToolbar(
          search: LibrarySearchField(
            fieldKey: const ValueKey<String>('shelf_search_field'),
            controller: search,
            hintText: 'Search books',
            onChanged: (_) {},
            onClear: () {},
          ),
          trailing: tagBar(FushiTagFilterBarPart.actions, selecting),
          appleFilterRow: tagBar(
            FushiTagFilterBarPart.appleFilterRow,
            selecting,
          ),
        ),
        Expanded(
          child: LibraryGridZoom(
            columns: 4,
            choices: const <int>[3, 4, 5],
            onColumnsChanged: (_) {},
            child: const FushiPlaceholderMessage(
              icon: Icons.book,
              message: 'Empty',
              detail: 'Drop files here',
            ),
          ),
        ),
        if (selecting)
          BatchActionBar(
            selectedCount: 1,
            onSelectAll: () {},
            onInvertSelection: () {},
            actions: const <Widget>[],
          ),
      ],
    );

    List<MediaLibraryViewSpec> featureViews({bool selecting = false}) =>
        <MediaLibraryViewSpec>[
          MediaLibraryViewSpec(
            kind: MediaLibraryViewKind.library,
            label: 'Shelf',
            builder: (BuildContext context, Widget navigation) =>
                shelfBody(selecting: selecting),
          ),
          ...views.skip(1),
        ];

    testWidgets('iOS 档：标题菜单 / 分区胶囊 / 横滑 / 导入 / 搜索 / 排序 / 筛选 / 缩放 / 空状态', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        glass: true,
        platform: TargetPlatform.iOS,
        withViews: featureViews(),
      );
      // 1 一级分组：标题下拉菜单。
      expect(
        find.byKey(const ValueKey<String>('test-library-view-title-menu')),
        findsOneWidget,
      );
      // 2 二级分区：标题下胶囊行。
      expect(
        find.byType(AppleLibraryScopeBar<MediaLibraryViewKind>),
        findsOneWidget,
      );
      // 4 横滑切分区。
      expect(
        find.byType(SectionSwipeNavigator<MediaLibraryViewKind>),
        findsOneWidget,
      );
      // 5 导入。
      expect(
        find.byKey(const ValueKey<String>('test-library-view-import')),
        findsOneWidget,
      );
      // 7 库内搜索（iOS 档在内容区）。
      expect(
        find.byKey(const ValueKey<String>('shelf_search_field')),
        findsOneWidget,
      );
      // 9 / 10 排序与筛选是两个独立 pull-down。
      expect(
        find.byKey(const ValueKey<String>('library_sort_menu_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('library_filter_menu_button')),
        findsOneWidget,
      );
      // 8 标签：iOS 档在标题下筛选行里，「筛选」胶囊后面跟标签胶囊 + 末尾
      // 「管理标签…」；筛选菜单里不再重复标签节。
      final Finder filterRow = find.byKey(
        const ValueKey<String>('library_apple_filter_row'),
      );
      expect(filterRow, findsOneWidget);
      expect(
        find.descendant(
          of: filterRow,
          matching: find.byKey(
            const ValueKey<String>('library_filter_menu_button'),
          ),
        ),
        findsOneWidget,
      );
      final Finder capsule = find.byKey(
        const ValueKey<String>('library_tag_capsule_7'),
      );
      expect(find.descendant(of: filterRow, matching: capsule), findsOneWidget);
      expect(
        find.descendant(
          of: filterRow,
          matching: find.byKey(const ValueKey<String>('library_tag_settings')),
        ),
        findsOneWidget,
      );
      // 行尾不再重复「管理标签」齿轮。
      expect(
        find.byKey(const ValueKey<String>('library_tag_settings')),
        findsOneWidget,
      );
      toggledTags.clear();
      await tester.tap(capsule);
      await tester.pumpAndSettle();
      expect(toggledTags, <int>[7]);
      await tester.tap(
        find.byKey(const ValueKey<String>('library_filter_menu_button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('library_menu_tag_7')),
        findsNothing,
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      // 11 显示：网格缩放（捏合 / ⌘±）。
      expect(find.byType(LibraryGridZoom), findsOneWidget);
      // 24 空状态：ContentUnavailable 式（图标 + 标题 + 说明）。
      expect(find.text('Empty'), findsOneWidget);
      expect(find.text('Drop files here'), findsOneWidget);
      // 3 分区自定义顺序：标题菜单末尾「调整页签顺序…」。
      await tester.tap(
        find.byKey(const ValueKey<String>('test-library-view-title-menu')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Reorder tabs'), findsOneWidget);
    });

    testWidgets('21 选择模式：底部玻璃工具栏纯图标、命中 ≥48', (WidgetTester tester) async {
      await pump(
        tester,
        glass: true,
        platform: TargetPlatform.iOS,
        withViews: featureViews(selecting: true),
      );
      for (final String key in <String>[
        'batch_select_all',
        'batch_invert_selection',
      ]) {
        final Finder button = find.byKey(ValueKey<String>(key));
        expect(button, findsOneWidget);
        final Size size = tester.getSize(button);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      expect(find.text('All'), findsNothing, reason: '文字只进 tooltip');
    });

    testWidgets('macOS 档：侧栏承载分区 + 标签节 + 搜索；工具行有缩放滑杆', (
      WidgetTester tester,
    ) async {
      final AppleSidebarLibraryHost host = AppleSidebarLibraryHost();
      addTearDown(host.dispose);
      host.reportSidebarMode(true);
      await pump(
        tester,
        glass: true,
        platform: TargetPlatform.macOS,
        size: const Size(1280, 800),
        host: host,
        withViews: featureViews(),
      );
      final List<String> ids = <String>[
        for (final AppleSidebarLibraryRow r in host.rows) r.id,
      ];
      // 2 分区 + 「在线」进侧栏；8 标签节（标题 + 标签 + 管理标签…）。
      expect(ids, contains('tags'));
      expect(ids, contains('tag-7'));
      expect(ids, contains('tags-manage'));
      // 8 宽窗档没有 iOS 的标签筛选行（标签都在侧栏）。
      expect(
        find.byKey(const ValueKey<String>('library_apple_filter_row')),
        findsNothing,
      );
      // 8 宽窗内容区不再画管理标签齿轮；菜单里也不再放标签。
      expect(
        find.byKey(const ValueKey<String>('library_tag_settings')),
        findsNothing,
      );
      // 7 侧栏不带搜索框（用户 2026-11-24）：库内搜索在内容区自己的搜索框。
      final Finder pageSearch = find.byKey(
        const ValueKey<String>('shelf_search_field'),
      );
      expect(pageSearch, findsOneWidget);
      expect(tester.getSize(pageSearch).width, greaterThan(100));
      // 11 macOS 工具栏：缩放滑杆不裸露，「每行数量」钮（命中 ≥36、有 tooltip）
      // 点开才弹出滑杆，Esc 关闭。
      final Finder slider = find.byKey(
        const ValueKey<String>('library-grid-zoom-slider'),
      );
      final Finder zoomButton = find.byKey(
        const ValueKey<String>('library-grid-zoom-button'),
      );
      expect(slider, findsNothing);
      expect(zoomButton, findsOneWidget);
      expect(find.byTooltip('Items per row'), findsOneWidget);
      await tester.tap(zoomButton);
      await tester.pumpAndSettle();
      expect(slider, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(slider, findsNothing);
      // 标签行点一下 = 切换筛选（不抛）。
      host.rows
          .firstWhere((AppleSidebarLibraryRow r) => r.id == 'tag-7')
          .onTap();
    });
  });

  group('侧栏（macOS 档）', () {
    testWidgets('侧栏不带搜索框，首节标题紧接品牌 / 折叠钮那一行', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppleSidebarLibraryHost host = AppleSidebarLibraryHost();
      addTearDown(host.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: true,
          ).copyWith(platform: TargetPlatform.macOS),
          home: FushiGlassScope(
            child: AppleSidebarTabsShell(
              items: const <AdaptiveNavItem>[
                AdaptiveNavItem(icon: Icons.book, label: 'Books'),
                AdaptiveNavItem(icon: Icons.settings, label: 'Settings'),
              ],
              currentIndex: 0,
              onTap: (_) {},
              sections: const <AppleSidebarSection>[
                AppleSidebarSection(indices: <int>[0], title: 'Library'),
              ],
              footer: const <int>[1],
              tabBar: false,
              onToggle: () {},
              libraryHost: host,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsNothing);
      // 节标题顶边 = 顶部内边距 10 + 品牌行 44 之内（不再隔一条搜索框）。
      expect(
        tester.getTopLeft(find.text('Library')).dy,
        lessThan(10 + 44 + 26),
      );
    });
  });
}
