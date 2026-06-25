import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-829 收藏句/词导出·分享：widget 行为测试（焦点驱动 Tab/Enter，禁 tap/坐标）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_collections_export_pp');
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

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  late HibikiDatabase db;
  late AppModel appModel;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
    required String source,
    String? bookKey,
  }) {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    return repo.add(FavoriteSentence(
      text: text,
      bookTitle: bookTitle,
      createdAt: DateTime.now(),
      source: source,
      bookKey: bookKey,
    ));
  }

  Widget buildPage() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(home: CollectionsPage()),
        ),
      );

  Finder exportButton() => find.widgetWithIcon(
        HibikiIconButton,
        Icons.ios_share_outlined,
      );

  testWidgets('export button hidden when there are no favorite sentences',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    expect(exportButton(), findsNothing);
  });

  testWidgets(
      'export button shows; focus-driven open reveals books, video-source '
      'book title (non-empty) and format chips', (WidgetTester tester) async {
    await seedSentence(
      text: '吾輩は猫である。',
      bookTitle: '吾輩は猫である',
      source: kFavoriteSentenceSourceBook,
      bookKey: 'book-1',
    );
    // video 来源收藏句：bookTitle 必须非空、非占位地出现在面板里。
    await seedSentence(
      text: '走れメロス。',
      bookTitle: 'メロス映画',
      source: kFavoriteSentenceSourceVideo,
      bookKey: 'video-uid-1',
    );

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    expect(exportButton(), findsOneWidget);

    // 焦点驱动：Tab 遍历直到导出按钮的 InkWell 持焦，再 Enter 激活打开面板。
    // （CollectionsPage 测试树外无 HibikiFocusRoot，HibikiIconButton 退化为可聚焦
    //  InkWell，标准焦点遍历可达。）
    final Finder buttonInkWell = find.descendant(
      of: exportButton(),
      matching: find.byType(InkWell),
    );
    final Element inkWellEl = buttonInkWell.evaluate().single;
    bool opened = false;
    for (int i = 0; i < 40 && !opened; i++) {
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
        // 焦点节点本身可能就是 InkWell 的 Focus（在其上方），也算命中。
        if (!onButton) {
          inkWellEl.visitAncestorElements((Element e) {
            if (e == focusCtx) {
              onButton = true;
              return false;
            }
            return true;
          });
        }
      }
      if (onButton) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        opened = find.text(t.collection_export_all_words).evaluate().isNotEmpty;
      }
    }
    expect(opened, isTrue,
        reason: 'Tab/Enter focus-driven open of export sheet failed');

    // 面板渲染：两本书的标题（含 video 来源书名，非空非占位）+「全部收藏词」+ 格式。
    expect(find.text('吾輩は猫である'), findsWidgets);
    expect(find.text('メロス映画'), findsWidgets);
    expect(find.text(t.collection_export_all_words), findsOneWidget);
    expect(find.text('Markdown'), findsOneWidget);
    expect(find.text('CSV'), findsOneWidget);
    expect(find.text('JSON'), findsOneWidget);
  });
}
