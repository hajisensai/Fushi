import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1906：收藏夹导出面板「现在也没办法根据合集来导出」（用户 2026-08-28，
/// 同时指出面板是个挤在屏幕下半截的 bottom sheet、文案叫「选择书籍」但列的是视频剧集）。
///
/// 前两条是表面，第三条是结构问题：范围过滤此前按 `ExportSentence.bookTitle` 这个
/// **显示名字符串**相等做，而合集归属只能由**身份**反查
/// （`media_collection_items.entry_key` → `collection_id`）——显示名里根本没有这个信息。
/// 仓库里早有 `getPrimaryCollectionIdByEntry()` 这个单查询封装，导出链路一次都没调过。
///
/// 本测试端到端跑真页面 + 真内存 DB：两集属于同一合集、另有一本散书，断言导出面板
/// 列出的是**合集名**（而不是两条剧集），且「全部来源」仍在。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('fushi_export_by_collection_pp');
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

  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices())..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSentence({
    required String text,
    required String bookTitle,
    required String bookKey,
    String source = kFavoriteSentenceSourceVideo,
  }) {
    return FavoriteSentenceRepository(db).add(FavoriteSentence(
      text: text,
      bookTitle: bookTitle,
      createdAt: DateTime.now(),
      source: source,
      bookKey: bookKey,
    ));
  }

  Widget buildPage() => ProviderScope(
        overrides: <Override>[appProvider.overrideWith((_) => appModel)],
        child: TranslationProvider(
          child: const MaterialApp(home: CollectionsPage()),
        ),
      );

  Finder exportButton() =>
      find.widgetWithIcon(FushiIconButton, Icons.share_outlined);

  /// 焦点驱动打开导出面板（禁 tap / 坐标点击，与既有 collections_export_test 同纪律）。
  Future<void> openExportPanel(WidgetTester tester) async {
    final Finder buttonInkWell = find.descendant(
      of: exportButton(),
      matching: find.byType(InkWell),
    );
    final Element inkWellEl = buttonInkWell.evaluate().single;
    for (int i = 0; i < 60; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final BuildContext? focusCtx =
          FocusManager.instance.primaryFocus?.context;
      bool onButton = false;
      if (focusCtx is Element) {
        focusCtx.visitAncestorElements((Element e) {
          if (e == inkWellEl) {
            onButton = true;
            return false;
          }
          return true;
        });
      }
      if (onButton) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('未能通过焦点遍历到达导出按钮');
  }

  testWidgets('同一合集的多集折叠成一个合集来源；散书单列；「全部来源」仍在（BUG-1906）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 一个视频合集，两集都在里面。
    final int collectionId = await db.createMediaCollection(
      'Re Zero S4',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/rezero-e01');
    await db.addToCollection(collectionId, MediaKind.video, 'video/rezero-e02');

    await seedSentence(
      text: 'エミリアたん',
      bookTitle: 'Re Zero S4 - S04E01',
      bookKey: 'video/rezero-e01',
    );
    await seedSentence(
      text: 'スバル',
      bookTitle: 'Re Zero S4 - S04E02',
      bookKey: 'video/rezero-e02',
    );
    // 不属于任何合集的散书：必须仍以自己的名字单列。
    await seedSentence(
      text: '吾輩は猫である。',
      bookTitle: 'Loose Book',
      bookKey: 'book-loose',
      source: kFavoriteSentenceSourceBook,
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(exportButton(), findsOneWidget);

    await openExportPanel(tester);

    // 断言一律限定在弹窗子树内：页面背后的收藏列表也会渲染同名标题。
    final Finder dialog = find.byType(Dialog);
    expect(dialog, findsOneWidget);
    Finder inDialog(String text) =>
        find.descendant(of: dialog, matching: find.text(text));

    // 文案：不再是「选择书籍」。
    expect(inDialog(t.collection_export_pick_source), findsOneWidget);
    expect(inDialog(t.collection_export_all_sources), findsOneWidget);

    // 合集折叠成一项：显示合集名，而不是两条剧集标题。
    expect(inDialog('Re Zero S4'), findsOneWidget,
        reason: '合集必须作为一个可选来源出现 —— 这正是用户报「没办法按合集导出」的那一条');
    expect(inDialog('Re Zero S4 - S04E01'), findsNothing,
        reason: '已归入合集的单集不再单列，否则用户还是只能一集一集导');
    expect(inDialog('Re Zero S4 - S04E02'), findsNothing);

    // 散书仍单列。
    expect(inDialog('Loose Book'), findsOneWidget);
  });

  testWidgets('面板是大弹窗而不是 bottom sheet（BUG-1906）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedSentence(
      text: 'テスト',
      bookTitle: 'Solo',
      bookKey: 'video/solo',
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    await openExportPanel(tester);

    expect(find.byType(Dialog), findsOneWidget,
        reason: '导出面板必须是对话框；旧的裸 showModalBottomSheet 没传 '
            'isScrollControlled，被默认 9/16 屏高上限卡死');
    expect(find.byType(BottomSheet), findsNothing);
  });
}
