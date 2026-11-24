import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/apple/apple_import_drop_overlay.dart';
import 'package:fushi/src/media/import/apple/apple_import_layout.dart';
import 'package:fushi/src/media/import/apple/apple_import_sources.dart';
import 'package:fushi/src/media/import/import_collage_page.dart';
import 'package:fushi/src/media/import/import_page_layout.dart';
import 'package:fushi/src/media/import/import_source_blocks.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_import_surface.dart';
import 'package:fushi/src/pages/implementations/library_layout/apple/apple_sidebar_library_section.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup;
import 'package:fushi/src/pages/implementations/video_import_page.dart'
    show buildVideoImportSpec;
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/adaptive/apple_sidebar_library_host.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

import '../../helpers/source_guard.dart';

/// Cupertino 导入页独立布局（2026-11-24 用户拍板方案 A）守卫：
///
/// - [ImportPageLayout] 只按 `isGlassDesign` 分派：M3E 主题任何平台都走
///   [MaterialImportLayout]，Cupertino 主题走 [AppleImportLayout]；
/// - Apple：副标题「到 〈库〉」、三组（添加到 / 网络与服务器 / 常驻来源）、方式
///   进行中、来源状态（进度 / 失败重试 / 刮削摘要 / 私密 / 自动添加）、编辑模式、
///   macOS 双栏、拖放覆盖层、查词空态；
/// - macOS 侧栏库分区末尾的「导入」项。
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    required bool glass,
    TargetPlatform platform = TargetPlatform.iOS,
    Size size = const Size(420, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glassDesign: glass,
        ).copyWith(platform: platform),
        home: FushiGlassScope(child: Scaffold(body: child)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  ImportMethod method(
    String id,
    ImportMethodKind kind, {
    ImportDestination? destination,
    Future<void> Function()? onTap,
    bool reportsProgress = false,
  }) => ImportMethod(
    id: id,
    kind: kind,
    icon: FushiIcons.folder,
    label: 'label-$id',
    description: 'desc-$id',
    destination: destination,
    reportsProgress: reportsProgress,
    onTap: onTap ?? () async {},
  );

  ImportSurfaceSpec spec({String id = 'book', List<ImportMethod>? methods}) =>
      ImportSurfaceSpec(
        id: id,
        tone: ImportTone.coral,
        guideIcon: FushiIcons.folder,
        guideTitle: 'guide-title',
        guideDescription: 'guide-desc',
        methods:
            methods ??
            <ImportMethod>[
              method(
                'primary',
                ImportMethodKind.primary,
                destination: ImportDestination.dialog,
              ),
              method(
                'folder',
                ImportMethodKind.folder,
                destination: ImportDestination.choice,
              ),
              method(
                'network',
                ImportMethodKind.network,
                destination: ImportDestination.source,
              ),
            ],
        formatGroups: const <ImportFormatGroup>[
          ImportFormatGroup(title: 'Books', labels: <String>['EPUB', 'PDF']),
        ],
      );

  group('ImportPageLayout dispatch', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      testWidgets('M3E theme on ${platform.name} keeps MaterialImportLayout', (
        WidgetTester tester,
      ) async {
        await pump(
          tester,
          ImportPageLayout(spec: spec()),
          glass: false,
          platform: platform,
        );
        expect(find.byType(MaterialImportLayout), findsOneWidget);
        expect(find.byType(AppleImportLayout), findsNothing);
      });
    }

    testWidgets('Cupertino theme switches to AppleImportLayout', (
      WidgetTester tester,
    ) async {
      await pump(tester, ImportPageLayout(spec: spec()), glass: true);
      expect(find.byType(AppleImportLayout), findsOneWidget);
      expect(find.byType(MaterialImportLayout), findsNothing);
    });
  });

  group('Apple import page (scheme A)', () {
    testWidgets('header + add group + network group from the spec', (
      WidgetTester tester,
    ) async {
      await pump(tester, ImportPageLayout(spec: spec()), glass: true);
      expect(
        find.text(t.import_header_destination(library: t.books)),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('import-formats-book')),
        findsOneWidget,
      );
      expect(
        find.text(t.import_section_add_to(library: t.books)),
        findsOneWidget,
      );
      expect(find.text(t.import_section_network), findsOneWidget);
      // 每个方式都有一行；网络方式改名「网络共享」进「网络与服务器」组。
      for (final String id in <String>['primary', 'folder', 'network']) {
        expect(
          find.byKey(ValueKey<String>('import-method-$id')),
          findsOneWidget,
        );
      }
      expect(find.text(t.import_method_network_share), findsOneWidget);
      expect(find.text('label-network'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('import-apple-network-section'),
          ),
          matching: find.byKey(const ValueKey<String>('import-method-network')),
        ),
        findsOneWidget,
      );
      // 组脚注 = 原引导首块说明。
      expect(find.text('guide-desc'), findsOneWidget);
    });

    testWidgets('a progress-reporting method spins and dims the rest', (
      WidgetTester tester,
    ) async {
      final Completer<void> gate = Completer<void>();
      int calls = 0;
      await pump(
        tester,
        ImportPageLayout(
          spec: spec(
            methods: <ImportMethod>[
              method(
                'primary',
                ImportMethodKind.primary,
                destination: ImportDestination.pickFolder,
                reportsProgress: true,
                onTap: () {
                  calls++;
                  return gate.future;
                },
              ),
              method('folder', ImportMethodKind.folder),
            ],
          ),
        ),
        glass: true,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('import-method-primary')),
      );
      await tester.pump();
      expect(find.text(t.import_in_progress), findsOneWidget);
      // 防重入：在跑时再点不触发第二次。
      await tester.tap(
        find.byKey(const ValueKey<String>('import-method-primary')),
      );
      await tester.pump();
      expect(calls, 1);
      final AnimatedOpacity dimmed = tester.widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byKey(const ValueKey<String>('import-method-folder')),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(dimmed.opacity, lessThan(1));
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(t.import_in_progress), findsNothing);
    });

    testWidgets('sources: rows, states, add row and network rows', (
      WidgetTester tester,
    ) async {
      final _Harness harness = _Harness();
      await pump(
        tester,
        ImportPageLayout(spec: spec(), sources: harness.view()),
        glass: true,
        platform: TargetPlatform.macOS,
        size: const Size(700, 1600),
      );
      expect(find.text(t.media_source_section_title), findsOneWidget);
      for (final int id in <int>[1, 2, 3]) {
        expect(
          find.byKey(ValueKey<String>('media-source-$id')),
          findsOneWidget,
        );
      }
      // 进度 / 扫描失败 + 重试 / 刮削摘要 / 私密 / 自动添加。
      expect(find.text('scanning 3/10'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('media_source_scan_error_2')),
        findsOneWidget,
      );
      expect(find.text(t.retry), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('media-source-scrape-summary-3')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('media-source-scrape-summary-3')),
      );
      expect(harness.scrapeSummaryTaps, 1);
      expect(find.text(t.media_source_privacy_badge), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('media_source_auto_owner_3')),
        findsOneWidget,
      );
      // macOS 档行尾平铺重新扫描。
      expect(
        find.byKey(const ValueKey<String>('media_source_rescan_1')),
        findsOneWidget,
      );
      // 「添加来源」末行、连接服务器、互联开关、浏览对端。
      await tester.tap(
        find.byKey(const ValueKey<String>('import-sources-add')),
      );
      expect(harness.addTaps, 1);
      expect(
        find.byKey(const ValueKey<String>('import-connect-server')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('import-interconnect')),
      );
      expect(harness.interconnect, isTrue);
      expect(
        find.byKey(const ValueKey<String>('import-interconnect-browse')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('import-apple-network-section'),
          ),
          matching: find.byKey(const ValueKey<String>('import-interconnect')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('iOS tier keeps only the more button (rescan goes into it)', (
      WidgetTester tester,
    ) async {
      final _Harness harness = _Harness();
      await pump(
        tester,
        ImportPageLayout(spec: spec(), sources: harness.view()),
        glass: true,
      );
      expect(
        find.byKey(const ValueKey<String>('media_source_rescan_1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('import-source-more-1')),
        findsOneWidget,
      );
    });

    testWidgets('edit mode: delete + reorder handle, done leaves it', (
      WidgetTester tester,
    ) async {
      final _Harness harness = _Harness();
      await pump(
        tester,
        ImportPageLayout(spec: spec(), sources: harness.view()),
        glass: true,
      );
      // 非编辑态没有常驻拖动手柄。
      expect(find.byIcon(FushiIcons.dragHandle), findsNothing);
      expect(find.text(t.dialog_edit), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('import-sources-edit')),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(t.dialog_done), findsOneWidget);
      expect(find.byIcon(FushiIcons.dragHandle), findsNWidgets(3));
      expect(
        find.byKey(const ValueKey<String>('import-source-more-1')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('import-source-delete-1')),
      );
      expect(harness.removed, <int>[1]);
      // 读屏「下移」走同一个重排回调。
      final Semantics handle = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byIcon(FushiIcons.dragHandle).first,
              matching: find.byWidgetPredicate(
                (Widget w) =>
                    w is Semantics &&
                    w.properties.customSemanticsActions != null,
              ),
            )
            .first,
      );
      handle.properties.customSemanticsActions!.values.single();
      expect(harness.moves, <(int, int)>[(0, 1)]);
      await tester.tap(
        find.byKey(const ValueKey<String>('import-sources-edit')),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byIcon(FushiIcons.dragHandle), findsNothing);
    });

    testWidgets('macOS wide window lays out two columns', (
      WidgetTester tester,
    ) async {
      final _Harness harness = _Harness();
      await pump(
        tester,
        ImportPageLayout(spec: spec(), sources: harness.view()),
        glass: true,
        platform: TargetPlatform.macOS,
        size: const Size(1300, 1200),
      );
      expect(
        find.byKey(const ValueKey<String>('import-apple-two-columns')),
        findsOneWidget,
      );
      // 两栏组标题基线 / 分组卡顶边严格齐平（右栏组标题带「编辑」也不变高）。
      final Finder addSection = find.byKey(
        const ValueKey<String>('import-apple-add-section'),
      );
      final Finder sourcesSection = find.descendant(
        of: find.byType(AppleImportSourcesSection),
        matching: find.byType(AdaptiveSettingsSection),
      );
      expect(
        find.byKey(const ValueKey<String>('import-sources-edit')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(addSection).dy,
        tester.getTopLeft(sourcesSection).dy,
      );
      Finder card(Finder section) => find
          .descendant(
            of: section,
            matching: find.byType(AdaptiveSettingsSurface),
          )
          .first;
      expect(
        tester.getTopLeft(card(addSection)).dy,
        tester.getTopLeft(card(sourcesSection)).dy,
      );
      // 两栏等宽且封顶，右栏不拉满到窗口边。
      final double leftWidth = tester.getSize(addSection).width;
      expect(tester.getSize(sourcesSection).width, leftWidth);
      expect(leftWidth, lessThanOrEqualTo(kAppleImportColumnMaxWidth));
    });

    testWidgets('real video spec: every method has a row', (
      WidgetTester tester,
    ) async {
      final ImportSurfaceSpec video = buildVideoImportSpec(
        onImportVideo: () async {},
        onImportFolder: () async {},
        onImportIptv: () async {},
        onAddNetworkSource: () async {},
        busy: false,
        showAudioCdNote: true,
        onImportFromInbox: () async {},
      );
      await pump(tester, ImportPageLayout(spec: video), glass: true);
      for (final ImportMethod m in video.methods) {
        expect(
          find.byKey(ValueKey<String>('import-method-${m.id}')),
          findsOneWidget,
          reason: m.id,
        );
      }
      expect(
        find.text(t.import_header_destination(library: t.nav_video)),
        findsOneWidget,
      );
    });

    testWidgets('dictionary empty state: ContentUnavailable header', (
      WidgetTester tester,
    ) async {
      final ImportSurfaceSpec dict = dictionaryImportSurfaceSpec(
        onAction: (DictionaryImportAction _) async {},
        folderImportAvailable: true,
        desktopDrop: false,
      );
      await pump(tester, ImportPageLayout(spec: dict), glass: true);
      expect(find.text(t.dictionaries_menu_empty), findsOneWidget);
      expect(find.text(t.import_section_network), findsNothing);
      for (final ImportMethod m in dict.methods) {
        expect(
          find.byKey(ValueKey<String>('import-method-${m.id}')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey<String>('import-formats-dictionary')),
        findsOneWidget,
      );
    });

    testWidgets('drop overlay: hidden at rest, release card while hovering', (
      WidgetTester tester,
    ) async {
      Future<double> opacity({required bool visible}) async {
        await pump(
          tester,
          AppleImportDropOverlay(visible: visible),
          glass: true,
          platform: TargetPlatform.macOS,
          size: const Size(800, 600),
        );
        return tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey<String>('import-drop-overlay')),
            )
            .opacity;
      }

      expect(await opacity(visible: false), 0);
      expect(await opacity(visible: true), 1);
      expect(find.text(t.import_drop_release_title), findsOneWidget);
      expect(find.text(t.import_drop_release_hint), findsOneWidget);
    });

    test('drop overlay is driven by the page drop target hover state', () {
      final String layout = maskComments(
        File(
          'lib/src/media/import/apple/apple_import_layout.dart',
        ).readAsStringSync(),
      );
      // 悬停态只读外层落点（拖进来才出现），落点包在整页最外层。
      expect(layout, contains('FushiFileDropTarget.dragHoveringOf(context)'));
      expect(layout, contains('AppleImportDropOverlay(visible: dragging)'));
      expect(
        layout.indexOf('body = FushiFileDropTarget('),
        greaterThan(layout.indexOf('body = _AppleImportDropStage(')),
      );
    });
  });

  group('macOS sidebar import row', () {
    LibraryChromeSpec<String> chrome({bool importSelected = false}) =>
        LibraryChromeSpec<String>(
          title: 'Books',
          groups: const <LibraryChromeGroup<String>>[
            LibraryChromeGroup<String>(
              group: LibrarySectionGroup.library,
              label: 'Library',
              value: 'shelf',
              members: <LibrarySectionTab<String>>[
                LibrarySectionTab<String>(value: 'shelf', label: 'Shelf'),
                LibrarySectionTab<String>(value: 'servers', label: 'Servers'),
              ],
              subFocusIdPrefix: 's',
            ),
          ],
          selected: 'shelf',
          currentGroup: importSelected ? null : LibrarySectionGroup.library,
          onSelect: (_) {},
          focusIdPrefix: 'b',
          actionsSlot: FushiShellActionsSlot(),
          chrome: FushiFloatingChromeController(),
          import: LibraryChromeImport(
            selected: importSelected,
            onTap: () {},
            focusIdPrefix: 'b',
          ),
        );

    List<AppleSidebarLibraryRow> rows(LibraryChromeSpec<String> s) =>
        appleSidebarLibraryRows<String>(
          spec: s,
          ordered: (LibraryChromeGroup<String> g) => g.members,
        );

    test('import is the last row of the library sections', () {
      final List<AppleSidebarLibraryRow> r = rows(chrome());
      expect(r.last.label, t.library_view_import);
      expect(r.last.selected, isFalse);
    });

    test('on the import page only the import row is selected', () {
      final List<AppleSidebarLibraryRow> r = rows(chrome(importSelected: true));
      expect(
        r.where((AppleSidebarLibraryRow e) => e.selected).map((e) => e.label),
        <String>[t.library_view_import],
      );
    });
  });

  group('source guards', () {
    test('six import surfaces build ImportPageLayout', () {
      for (final String path in <String>[
        'lib/src/pages/implementations/book_import_page.dart',
        'lib/src/media/manga/manga_sources_page.dart',
        'lib/src/pages/implementations/video_import_page.dart',
        'lib/src/pages/implementations/music/music_import_view.dart',
        'lib/src/pages/implementations/home_game_page.dart',
        'lib/src/pages/implementations/dictionary_import_surface.dart',
      ]) {
        final String source = maskComments(File(path).readAsStringSync());
        expect(source, contains('ImportPageLayout('), reason: path);
        expect(source, isNot(contains('MaterialImportLayout(')), reason: path);
      }
    });

    test('book / manga headers ask isGlassDesign, not the platform', () {
      for (final String path in <String>[
        'lib/src/pages/implementations/book_import_page.dart',
        'lib/src/media/manga/manga_sources_page.dart',
      ]) {
        final String source = maskComments(File(path).readAsStringSync());
        expect(source, contains('if (!isGlassDesign(context)) _buildHeader()'));
        expect(source, isNot(contains('isCupertinoPlatform(context)')));
      }
    });

    test('Apple layout never reads the M3E module tones', () {
      final Directory dir = Directory('lib/src/media/import/apple');
      for (final FileSystemEntity f in dir.listSync()) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final String source = maskComments(f.readAsStringSync());
        for (final String banned in <String>[
          'ImportTone',
          'FushiCoverBlockColors',
          'importToneColors',
          'package:flutter/material.dart',
          'package:flutter/cupertino.dart',
        ]) {
          expect(source, isNot(contains(banned)), reason: '${f.path}: $banned');
        }
      }
    });
  });
}

/// 来源区替身：实现 [AppleImportSourcesComposer]，像 `MediaSourcesView` 一样把
/// 数据交给 Apple 布局的 compose。
class _Harness {
  int addTaps = 0;
  int scrapeSummaryTaps = 0;
  bool interconnect = false;
  final List<int> removed = <int>[];
  final List<(int, int)> moves = <(int, int)>[];

  Widget view() => _FakeSources(harness: this);

  ImportSourceBlockData source(
    int id, {
    String? progress,
    bool scanError = false,
    String? scrape,
    String? owner,
    bool private = false,
  }) => ImportSourceBlockData(
    id: id,
    name: 'source-$id',
    location: '/path/$id',
    countText: '$id items',
    lastScanText: 'last scan',
    isPrivate: private,
    autoOwnerText: owner,
    scanError: scanError,
    working: progress != null,
    progressValue: progress == null ? null : 0.3,
    progressText: progress,
    scrapeSummaryText: scrape,
    scrapeSummaryFailed: scrape != null,
    onScrapeSummary: scrape == null ? null : () => scrapeSummaryTaps++,
    onRescan: () {},
    menu: <ImportSourceMenuAction>[
      ImportSourceMenuAction(
        label: t.media_source_remove,
        icon: FushiIcons.delete,
        destructive: true,
        onTap: () => removed.add(id),
      ),
    ],
  );

  AppleImportSourcesData data(void Function() rebuild) =>
      AppleImportSourcesData(
        sources: <ImportSourceBlockData>[
          source(1, progress: 'scanning 3/10', private: true),
          source(2, scanError: true),
          source(3, scrape: 'scrape summary', owner: 'owned by X'),
        ],
        interconnectEnabled: interconnect,
        onInterconnectChanged: (bool v) {
          interconnect = v;
          rebuild();
        },
        onReorder: (int from, int to) => moves.add((from, to)),
        onAddSource: () => addTaps++,
        addSourceHint: 'add hint',
        onBrowseInterconnect: () {},
        browseLabel: 'browse peers',
        browseDisabledHint: 'turn on first',
        onConnectServer: () {},
        connectServerHint: 'Kavita · OPDS',
      );
}

class _FakeSources extends StatefulWidget
    implements AppleImportSourcesComposer {
  const _FakeSources({required this.harness});

  final _Harness harness;

  @override
  bool get composesAppleImport => true;

  @override
  State<_FakeSources> createState() => _FakeSourcesState();
}

class _FakeSourcesState extends State<_FakeSources> {
  @override
  Widget build(BuildContext context) {
    final AppleImportScope scope = AppleImportScope.maybeOf(context)!;
    return scope.compose(context, widget.harness.data(() => setState(() {})));
  }
}
