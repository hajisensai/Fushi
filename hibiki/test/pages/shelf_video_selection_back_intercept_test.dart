import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-250 (TODO-306): 书架/视频 tab 的批量选择模式（`_selectionMode`）活在 tab
/// 内容里、不是独立 route。修复前返回键冒泡到 HomePage 顶层 PopScope 直接退出
/// App；修复后 build 根的嵌套 `PopScope(canPop: !_selectionMode)` 在多选态拦下
/// 返回、只退出多选态。
///
/// 视频 tab 用真 pump + 系统返回（`handlePopRoute`）做行为测试；书架 tab pump
/// 依赖大量 reader/webview provider，按「最强可落地层」用源码守卫断言其 build 根
/// 包了等价的 PopScope wiring。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('hibiki_sel_back_pp');
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
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late HibikiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_sel_back_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeVideoPage(repo: VideoBookRepository(db)),
            ),
          ),
        ),
      );

  Future<void> seedVideo() async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('My Episode'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
  }

  Future<void> enterSelectionMode(WidgetTester tester) async {
    // 标签栏旁的「批量选择」按钮：HibikiIconButton 用 Semantics(label) 而非
    // Tooltip，故按 checklist 图标定位（与 home_video_page_menu_test 一致）。
    final Finder selectBtn = find.descendant(
      of: find.byType(HibikiTagFilterBar),
      matching: find.byIcon(Icons.checklist_outlined),
    );
    expect(selectBtn, findsOneWidget, reason: '视频标签栏旁应有「批量选择」按钮');
    await tester.tap(selectBtn);
    await tester.pumpAndSettle();
  }

  /// 派发一次「系统返回键」并返回是否被某个 route（含 PopScope）消费。
  Future<bool> systemBack() => WidgetsBinding.instance.handlePopRoute();

  testWidgets('视频 tab：多选态按返回被消费、只退出多选态（不退出 App）', (WidgetTester tester) async {
    await seedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 进入多选态：filter bar 选择切换可见、批量动作栏出现（含「全选」）。
    await enterSelectionMode(tester);
    expect(find.text(t.batch_select_all), findsOneWidget,
        reason: '进入多选态后底部批量动作栏应出现');

    // 系统返回：被本页 PopScope(canPop:false) 消费（返回 true = 不退 App）。
    final bool handled = await systemBack();
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: '多选态下返回必须被嵌套 PopScope 消费，否则会冒泡到顶层退出 App');
    expect(find.text(t.batch_select_all), findsNothing,
        reason: '返回应退出多选态，批量动作栏消失');
    // 仍停在视频页（页面没被弹掉）。
    expect(find.text('My Episode'), findsOneWidget);
  });

  testWidgets('视频 tab：非多选态返回不被本页消费（交给外层）', (WidgetTester tester) async {
    await seedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 普通态（canPop:true，root route 无可弹）→ handlePopRoute 返回 false，
    // 真机上交由平台关闭 App，本页不拦截。
    final bool handled = await systemBack();
    await tester.pumpAndSettle();

    expect(handled, isFalse, reason: '非多选态本页 canPop=true，不应消费返回，行为与修复前一致');
    expect(find.text('My Episode'), findsOneWidget);
  });

  test('视频/书架 build 根都包了 PopScope 拦截多选态返回（源码守卫）', () {
    String read(String path) => File(path).readAsStringSync();

    final String videoSrc =
        read('lib/src/pages/implementations/home_video_page.dart');
    final String shelfSrc =
        read('lib/src/pages/implementations/reader_hibiki_history_page.dart');

    for (final MapEntry<String, String> e in <String, String>{
      'home_video_page': videoSrc,
      'reader_hibiki_history_page': shelfSrc,
    }.entries) {
      final int buildStart = e.value.indexOf('Widget build(BuildContext');
      expect(buildStart, isNonNegative, reason: '${e.key} 应有 build 方法');
      // build 根第一个返回的 widget 必须是 PopScope（在 HibikiFileDropTarget 外）。
      final int popScope = e.value.indexOf('return PopScope(', buildStart);
      final int dropTarget =
          e.value.indexOf('HibikiFileDropTarget(', buildStart);
      expect(popScope, isNonNegative,
          reason: '${e.key} build 根应包一层 PopScope 拦截多选态返回');
      expect(popScope, lessThan(dropTarget),
          reason: '${e.key} 的 PopScope 必须包在 HibikiFileDropTarget 外层');

      final String region = e.value.substring(popScope, dropTarget);
      expect(region, contains('canPop: !_selectionMode'),
          reason: '${e.key} 多选态 canPop=false，普通态不变');
      expect(region, contains('_exitSelectionMode()'),
          reason: '${e.key} 返回被拦时应退出多选态');
    }
  });
}
