import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-1245：桌面端右键（secondary tap）应打开与移动端长按（onLongPress）
/// 完全相同的条目菜单（`_showItemDialog` → 居中的 CollectionItemDialogFrame）。
/// 本测试在真 CollectionsPage 上分别用右键和长按触发同一条收藏行，断言两者都弹出
/// 同一个 CollectionItemDialogFrame，且承载相同的条目标题——右键入口不新建菜单、
/// 不改内容，只复用既有长按逻辑。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_collection_rclick');
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

  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices())..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    await db.close();
  });

  const String sentenceText = 'これはテスト用の収集された文章です。';

  // 无 bookKey 的收藏句，避免触发音频/视频解析路径，只驱动列表渲染 + 条目菜单。
  Future<void> seedFavorite() async {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    await repo.add(
      FavoriteSentence(
        id: 'fav_rclick_test',
        text: sentenceText,
        bookTitle: 'テストブック',
        source: kFavoriteSentenceSourceBook,
        createdAt: DateTime(2026, 6, 30, 14, 5),
      ),
    );
  }

  Widget buildPage() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(home: CollectionsPage()),
        ),
      );

  testWidgets('right-click opens the item menu (same as long-press)',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);

    await seedFavorite();
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // 条目渲染出来、菜单尚未出现。
    expect(find.text(sentenceText), findsOneWidget);
    expect(find.byType(CollectionItemDialogFrame), findsNothing);

    // 桌面右键（secondary tap）→ 与长按相同的条目菜单弹出。
    await tester.tap(find.text(sentenceText), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.byType(CollectionItemDialogFrame), findsOneWidget);
    // 菜单标题承载该条目文本（与长按一致）。
    expect(
      find.descendant(
        of: find.byType(CollectionItemDialogFrame),
        matching: find.text(sentenceText),
      ),
      findsOneWidget,
    );
  });

  testWidgets('right-click and long-press open the same menu (item parity)',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);

    await seedFavorite();
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // 先走长按路径，记录菜单里出现的动作按钮标签集合。
    await tester.longPress(find.text(sentenceText));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionItemDialogFrame), findsOneWidget);
    final Set<String> longPressButtons = tester
        .widgetList<TextButton>(find.descendant(
          of: find.byType(CollectionItemDialogFrame),
          matching: find.byType(TextButton),
        ))
        .map((TextButton b) => _labelOf(tester, b))
        .whereType<String>()
        .toSet();
    expect(longPressButtons, isNotEmpty);

    // 关掉长按弹出的菜单。
    Navigator.of(tester.element(find.byType(CollectionItemDialogFrame))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(CollectionItemDialogFrame), findsNothing);

    // 再走右键路径，收集同一集合。
    await tester.tap(find.text(sentenceText), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(CollectionItemDialogFrame), findsOneWidget);
    final Set<String> rightClickButtons = tester
        .widgetList<TextButton>(find.descendant(
          of: find.byType(CollectionItemDialogFrame),
          matching: find.byType(TextButton),
        ))
        .map((TextButton b) => _labelOf(tester, b))
        .whereType<String>()
        .toSet();

    // 两条入口打开的是内容完全一致的同一个菜单。
    expect(rightClickButtons, longPressButtons);
  });
}

/// 取 TextButton 里第一个 Text 的字面文本，用于比较两条入口的菜单项集合。
String? _labelOf(WidgetTester tester, TextButton button) {
  final Finder textFinder = find.descendant(
    of: find.byWidget(button),
    matching: find.byType(Text),
  );
  if (textFinder.evaluate().isEmpty) {
    return null;
  }
  final Text text = tester.widget<Text>(textFinder.first);
  return text.data;
}
