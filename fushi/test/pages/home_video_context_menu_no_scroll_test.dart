import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart'
    show MediaItemDialogFrame;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/series_scrape_seed.dart';
import '../helpers/test_platform_services.dart';

/// 反馈 1120 #i10：Windows 视频页「系列」墙右键合集卡，菜单弹出的同时页面自己
/// 往下滚了一大段，大标题 / 筛选条 / 星级分组条跟着收起。
///
/// 右键不该改页面状态：主滚动区的 pixels 不变、浮动顶栏（[FushiFloatingChromeController]
/// ——库页外壳的显隐真相，滚动通知喂给它）不收起；Esc 关菜单、焦点回落之后同样不变。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_ctx_noscroll');
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
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late Directory storeDir;

  setUp(() async {
    VideoCoverMutationGate.debugResetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_ctx_noscroll_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<List<int>> seedCollections(int count) async {
    final List<int> ids = <int>[];
    for (int i = 0; i < count; i++) {
      final String uid = 'video/c$i';
      final String title = '作品$i';
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(title),
          videoPath: Value<String>('/abs/c$i.mp4'),
          importedAt: Value<int>(DateTime(2026, 1, 1).millisecondsSinceEpoch),
        ),
      );
      await seedAniDbLooseIdentity(db, uid, title: title);
      final int cid = await createSeriesCollection(db, '合集$i');
      await db.addToCollection(cid, MediaKind.video, uid);
      ids.add(cid);
    }
    return ids;
  }

  testWidgets('桌面右键系列墙合集卡：不滚动、不收顶栏；Esc 关菜单后仍不变', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final FushiFloatingChromeController chrome =
        FushiFloatingChromeController();
    try {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final List<int> ids = await seedCollections(30);

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformServicesProvider.overrideWithValue(platformServices),
            ankiRepositoryProvider.overrideWithValue(ankiRepository),
            appProvider.overrideWith((ref) => appModel),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              // 与 main.dart 同形：焦点根包住整个 Navigator（卡片据此挂
              // FushiFocusTarget，桌面鼠标按下把方向导航焦点带到卡上）。
              builder: (BuildContext context, Widget? child) =>
                  FushiFocusRoot(child: child!),
              home: Scaffold(
                body: FushiFloatingChromeScope(
                  controller: chrome,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: chrome.handleScrollNotification,
                    child: HomeVideoPage(
                      repo: VideoBookRepository(db),
                      section: VideoLibrarySection.series,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 先往下滚过「允许收起」的阈值再回一点，让顶栏处于展开态、页面离开顶部：
      // 这样任何非用户的下行滚动都会把它收起，断言才有力。
      final ScrollableState mainScroll = tester.state<ScrollableState>(
        find
            .ancestor(
              of: find.byKey(
                ValueKey<String>('home_video_collection_card_${ids.first}'),
              ),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final ScrollPosition position = mainScroll.position;
      expect(position.axis, Axis.vertical);
      expect(position.maxScrollExtent, greaterThan(400), reason: '墙要够长才能复现');
      final TestGesture wheel = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await wheel.moveTo(const Offset(640, 400));
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(640, 400),
          scrollDelta: Offset(0, 200),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(640, 400),
          scrollDelta: Offset(0, -60),
        ),
      );
      await tester.pumpAndSettle();
      expect(chrome.visible, isTrue, reason: '前置：上行一格后顶栏是展开的');
      final double pixelsBefore = position.pixels;
      expect(pixelsBefore, greaterThan(64));

      // 挑一张卡顶露在视口下沿附近（部分可见）的合集卡：任何「把焦点卡滚进视野 /
      // 居中」的副作用都会让它带着页面往下滚。
      final double viewportBottom = tester
          .getBottomLeft(find.byWidget(mainScroll.widget))
          .dy;
      int? targetId;
      for (final int cid in ids) {
        final Finder card = find.byKey(
          ValueKey<String>('home_video_collection_card_$cid'),
        );
        if (card.evaluate().isEmpty) continue;
        final Rect rect = tester.getRect(card);
        if (rect.top < viewportBottom - 24 && rect.bottom > viewportBottom) {
          targetId = cid;
          break;
        }
      }
      expect(targetId, isNotNull, reason: '要有一张跨视口下沿的合集卡');
      final Rect targetRect = tester.getRect(
        find.byKey(ValueKey<String>('home_video_collection_card_$targetId')),
      );
      final Offset pressAt = Offset(targetRect.center.dx, targetRect.top + 12);

      final TestGesture right = await tester.startGesture(
        pressAt,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await tester.pumpAndSettle();

      expect(find.byType(MediaItemDialogFrame), findsOneWidget, reason: '菜单弹出');
      expect(position.pixels, pixelsBefore, reason: '右键不滚动页面');
      expect(chrome.visible, isTrue, reason: '右键不收起顶栏');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        find.byType(MediaItemDialogFrame),
        findsNothing,
        reason: 'Esc 关菜单',
      );
      expect(position.pixels, pixelsBefore, reason: '关菜单焦点回落也不滚动');
      expect(chrome.visible, isTrue, reason: '关菜单后顶栏仍展开');
      await wheel.removePointer();
    } finally {
      chrome.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
