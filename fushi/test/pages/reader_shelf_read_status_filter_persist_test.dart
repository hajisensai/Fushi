// BUG-2920：书架「阅读状态」筛选每次打开软件都重置。筛选值只活在 State 里，
// 重启（State 重建）就回到「全部」。修复后落偏好 `shelf_read_status_filter`，
// 重建页面时读回。
//
// 2026-10-10「阅读状态下拉框放在排序那」：筛选从工具行的下拉 chip 挪进排序菜单
// （单选组，含「全部」），生效时排序按钮右上角亮圆点。窄屏标签筛选同样并进排序
// 菜单（多选组），工具条只剩一行。本文件钉住：筛选仍过滤网格、写回偏好、重启读回、
// 按钮圆点随筛选出现 / 消失、工具行不再有阅读状态下拉。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

MediaItem _book(String title, {required int position}) => MediaItem(
      mediaIdentifier: 'shelf-test-$title',
      title: title,
      mediaTypeIdentifier: 'reader',
      mediaSourceIdentifier: 'shelf_test_source',
      position: position,
      duration: 100,
      canDelete: false,
      canEdit: true,
    );

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'hibiki_shelf_read_status_pp',
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
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'hibiki_shelf_read_status_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  // pageKey 变化 = 页面 State 整个重建（等价重启后重新进书架）。不拆 ProviderScope：
  // 拆掉会 dispose 注入的 AppModel。
  Widget buildApp({
    Key? pageKey,
    List<MediaItem> books = const <MediaItem>[],
  }) =>
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(books),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                key: pageKey,
                remoteBookClientLoader: () async => null,
              ),
            ),
          ),
        ),
      );

  final Finder sortButton =
      find.byKey(const ValueKey<String>('library_sort_menu_button'));

  Finder statusItem(String name) =>
      find.byKey(ValueKey<String>('shelf_filter_read_status_$name'));

  double badgeScale(WidgetTester tester) => tester
      .widget<AnimatedScale>(
        find.descendant(
          of: sortButton,
          matching:
              find.byKey(const ValueKey<String>('library_filter_badge_dot')),
        ),
      )
      .scale;

  Future<void> pickStatus(WidgetTester tester, String name) async {
    await tester.tap(sortButton);
    await tester.pumpAndSettle();
    expect(statusItem(name), findsOneWidget, reason: '阅读状态组应在排序菜单里');
    await tester.tap(statusItem(name));
    await tester.pumpAndSettle();
  }

  testWidgets('阅读状态在排序菜单里：选中落偏好、亮圆点，页面重建（重启）后读回', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    // 工具行上不再有阅读状态下拉 chip。
    expect(find.byType(LibraryFilterChip), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('shelf_filter_read_status')),
      findsNothing,
    );
    expect(badgeScale(tester), 0, reason: '首次打开默认「全部」，按钮不带筛选标记');

    await pickStatus(tester, 'reading');
    expect(prefs.shelfReadStatusFilterName, 'reading');
    expect(badgeScale(tester), 1, reason: '筛选生效时排序按钮要亮圆点');

    // 模拟重启：换 key 让页面 State 全新创建，只能从偏好读回。
    await tester.pumpWidget(buildApp(pageKey: const ValueKey<int>(2)));
    await tester.pumpAndSettle();
    expect(badgeScale(tester), 1, reason: 'BUG-2920：重启后筛选不得回到「全部」');
    await tester.tap(sortButton);
    await tester.pumpAndSettle();
    await tester.tap(statusItem('all'));
    await tester.pumpAndSettle();
    // 选回「全部」也要落库，否则下次又恢复成旧筛选。
    expect(prefs.shelfReadStatusFilterName, '');
    expect(badgeScale(tester), 0, reason: '取消筛选后圆点消失');
  });

  testWidgets('排序菜单里的阅读状态筛选仍真正过滤网格', (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        books: <MediaItem>[
          _book('Alpha', position: 0),
          _book('Beta', position: 50),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsWidgets);

    await pickStatus(tester, 'reading');
    expect(find.text('Alpha'), findsNothing, reason: '未读的书应被「在读」筛掉');
    expect(find.text('Beta'), findsWidgets);

    await pickStatus(tester, 'unread');
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('窄屏：标签筛选并进排序菜单（多选），工具条一行、选中后亮圆点', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final int tagA = await db.createTag('TagA', 0xFF4CAF50);
    await db.createTag('TagB', 0xFF2196F3);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    // 标签 chip 行不再单独占一行。
    expect(find.text('TagA'), findsNothing);
    expect(badgeScale(tester), 0);

    await tester.tap(sortButton);
    await tester.pumpAndSettle();
    final Finder tagItem =
        find.byKey(ValueKey<String>('library_menu_tag_$tagA'));
    expect(tagItem, findsOneWidget);
    await tester.tap(tagItem);
    await tester.pumpAndSettle();
    // 多选：点了菜单不关，选中写进共享的标签筛选状态。
    expect(tagItem, findsOneWidget, reason: '标签组是多选，点一个不关菜单');
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderFushiHistoryPage)),
    );
    expect(container.read(selectedTagIdsProvider), <int>{tagA});
    await tester.tapAt(const Offset(5, 830));
    await tester.pumpAndSettle();
    expect(badgeScale(tester), 1, reason: '标签筛选生效同样亮圆点');
    container.read(selectedTagIdsProvider.notifier).state = <int>{};
  });

  testWidgets('宽屏：标签 chip 嵌在工具行里（搜索框右边），不另起一行', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.reset);
    await db.createTag('TagA', 0xFF4CAF50);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    final Finder chip = find.text('TagA');
    expect(chip, findsOneWidget);
    final Rect search = tester.getRect(find.byType(LibrarySearchField));
    final Rect chipRect = tester.getRect(chip);
    expect(
      (chipRect.center.dy - search.center.dy).abs(),
      lessThan(4),
      reason: '标签 chip 与搜索框同一行',
    );
    expect(chipRect.left, greaterThan(search.right));
  });

  testWidgets('偏好里的未知值按「全部」处理', (WidgetTester tester) async {
    await prefs.setShelfReadStatusFilterName('bogus');
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(badgeScale(tester), 0);
  });
}
