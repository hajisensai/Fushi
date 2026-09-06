import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/collections/collection_shelf_row.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 视频首页横滚行的卡片尺寸门（用户实报「动画缩略图太大」）。
///
/// 行卡高必须走 [videoRowCoverHeightForPortraitWidth]，不是库墙的
/// [videoCoverHeightForPortraitWidth]——后者按竖卡定高，同一卡宽下横卡会撑到
/// 竖卡目标宽的 8/3 倍（桌面 ~626px，一屏只剩 3 张）。这里量**真渲染出来的卡宽**
/// 而不是复述公式：换回库墙口径时竖卡宽会恰好等于目标卡宽，本测试立刻红。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('fushi_row_card_size_pp');
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

  testWidgets('「继续观看」行卡按横滚行口径定高，不再与库墙目标卡宽同宽',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/loose-1'),
      title: Value('Loose One'),
      videoPath: Value('/abs/loose-1.mp4'),
      lastPositionMs: Value(60000),
    ));

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card =
        find.byKey(const ValueKey<String>('home_video_continue_video/loose-1'));
    expect(card, findsOneWidget, reason: '有进度的散卡必须出现在「继续观看」行');

    // 页面自己看到的可用宽 = LayoutBuilder 给 CustomScrollView 的宽度，直接量，
    // 不在测试里复刻外层 padding。
    final double layoutWidth =
        tester.getSize(find.byType(CustomScrollView)).width;
    final FushiDesignTokens tokens =
        FushiDesignTokens.of(tester.element(find.byType(CustomScrollView)));
    final ({int columns, double cardWidth}) wallLayout = unifiedShelfCardLayout(
      availableWidth: layoutWidth - tokens.spacing.card * 2,
      targetWidth: readerShelfGridExtentForWidth(layoutWidth),
    );
    // 无封面 → 朝向未知 → 竖卡（[videoCardOrientationForAspect] 的默认）。
    final double expectedWidth = videoCardWidthForOrientation(
      orientation: VideoCardOrientation.portrait,
      coverHeight: videoRowCoverHeightForPortraitWidth(wallLayout.cardWidth),
    );

    expect(
      tester.getSize(card).width,
      closeTo(expectedWidth, 0.5),
      reason: '行卡高必须来自 videoRowCoverHeightForPortraitWidth',
    );
    // 库墙口径下竖卡宽恰等于目标卡宽——旧值必须被真正甩开，否则这条门恒真。
    expect(
      tester.getSize(card).width,
      lessThan(wallLayout.cardWidth - 1),
      reason: '换回 videoCoverHeightForPortraitWidth 会让卡宽回到目标卡宽',
    );
  });
}
