import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/collections/collection_shelf_row.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 视频首页横滚行的卡片尺寸门（用户实报「动画缩略图太大」）。
///
/// 2026-10 首页重设计后行卡统一画 2:3 竖封面，宽度走 [videoHomePosterCardWidth]
/// （按内容宽：手机约 3.3 张一行，平板 / 桌面夹在 120–140），不再按封面朝向
/// 探测横 / 竖卡、也不再沿用库墙目标卡宽。这里量**真渲染出来的卡宽**而不是复述
/// 公式：退回库墙卡宽（桌面 ~200+）时立刻红。
///
/// 2026-10-28 起继续观看全在首屏 FushiContinueSpotlight（16:9 剧照卡，不是行卡），
/// 横滚行只剩「已更新未看」「最近添加」；这里用「最近添加」行验行卡宽。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_row_card_size_pp',
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
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_row_card_size_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp() => ProviderScope(
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
            section: VideoLibrarySection.home,
          ),
        ),
      ),
    ),
  );

  testWidgets('「最近添加」行卡是 videoHomePosterCardWidth 宽的竖卡，不再与库墙目标卡宽同宽', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 刚导入、没播过的单片：进「最近添加」行。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/loose-1'),
        title: const Value('Loose One'),
        videoPath: const Value('/abs/loose-1.mp4'),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('home_video_recent_video/loose-1'),
    );
    expect(card, findsOneWidget, reason: '刚导入的散片必须出现在「最近添加」行');

    // 页面自己看到的可用宽 = LayoutBuilder 给 CustomScrollView 的宽度，直接量，
    // 不在测试里复刻外层 padding。
    final double layoutWidth = tester
        .getSize(find.byType(CustomScrollView))
        .width;
    final FushiDesignTokens tokens = FushiDesignTokens.of(
      tester.element(find.byType(CustomScrollView)),
    );
    final double contentWidth = layoutWidth - tokens.spacing.card * 2;
    final double expectedWidth = videoHomePosterCardWidth(contentWidth);

    expect(
      tester.getSize(card).width,
      closeTo(expectedWidth, 0.5),
      reason: '行卡宽必须来自 videoHomePosterCardWidth（2026-10 首页重设计）',
    );
    // 库墙目标卡宽是「太大」的那个旧值——必须被真正甩开，否则这条门恒真。
    final ({int columns, double cardWidth}) wallLayout = unifiedShelfCardLayout(
      availableWidth: contentWidth,
      targetWidth: readerShelfGridExtentForWidth(layoutWidth),
    );
    expect(
      tester.getSize(card).width,
      lessThan(wallLayout.cardWidth - 1),
      reason: '行卡不得回到库墙目标卡宽（用户实报缩略图太大）',
    );
    // 恒竖版：封面区是 2:3（无封面 / 横图都不改槽向）。
    final Rect cover = tester.getRect(
      find.descendant(of: card, matching: find.byType(ShelfCoverFrame)).first,
    );
    expect(
      cover.height,
      closeTo(videoCoverHeightForPortraitWidth(cover.width), 0.5),
      reason: '首页行卡封面恒 2:3 竖槽',
    );
  });
}
