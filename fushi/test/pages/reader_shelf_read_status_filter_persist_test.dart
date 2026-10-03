// BUG-2920：书架搜索栏「阅读状态」筛选每次打开软件都重置。筛选值只活在 State
// 里，重启（State 重建）就回到「全部」。修复后落偏好 `shelf_read_status_filter`，
// 重建页面时读回。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart';

import '../helpers/test_platform_services.dart';

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
  Widget buildApp({Key? pageKey}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) =>
                Future<List<MediaItem>>.value(const <MediaItem>[]),
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

  final Finder dropdown =
      find.byKey(const ValueKey<String>('shelf_filter_read_status'));

  ShelfReadStatus? dropdownValue(WidgetTester tester) => tester
      .widget<LibraryFilterDropdown<ShelfReadStatus>>(dropdown)
      .value;

  testWidgets('选中的阅读状态落偏好，页面重建（重启）后读回', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(dropdownValue(tester), isNull, reason: '首次打开默认「全部」');

    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.shelf_filter_read_status_reading).last);
    await tester.pumpAndSettle();
    expect(dropdownValue(tester), ShelfReadStatus.reading);
    expect(prefs.shelfReadStatusFilterName, 'reading');

    // 模拟重启：换 key 让页面 State 全新创建，只能从偏好读回。
    await tester.pumpWidget(buildApp(pageKey: const ValueKey<int>(2)));
    await tester.pumpAndSettle();
    expect(
      dropdownValue(tester),
      ShelfReadStatus.reading,
      reason: 'BUG-2920：重启后筛选不得回到「全部」',
    );

    // 选回「全部」也要落库，否则下次又恢复成旧筛选。
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.home_filter_all).last);
    await tester.pumpAndSettle();
    expect(dropdownValue(tester), isNull);
    expect(prefs.shelfReadStatusFilterName, '');
  });

  testWidgets('偏好里的未知值按「全部」处理', (WidgetTester tester) async {
    await prefs.setShelfReadStatusFilterName('bogus');
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(dropdownValue(tester), isNull);
  });
}
