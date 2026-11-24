import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

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
import 'package:fushi/src/utils/adaptive/apple_sidebar_library_host.dart';
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
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget shell = MediaLibraryShell(
      focusIdPrefix: 'test-library-view',
      views: views,
    );
    if (host != null) {
      shell = AppleSidebarLibraryScope(host: host, child: shell);
    }
    await tester.pumpWidget(
      MaterialApp(
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
      // 侧栏行：书架 / 媒体服务器 / 在线（折叠成一行）。
      expect(
        host.rows.map((AppleSidebarLibraryRow r) => r.label).toList(),
        <String>['Shelf', 'Servers', 'Online'],
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
}
