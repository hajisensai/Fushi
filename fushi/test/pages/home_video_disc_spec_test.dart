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
import 'package:fushi/src/media/video/cover_ui/disc_format_badge.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 视频库页的原盘规格（2026-10-24 原盘交接第 3、9 项）：卡片封面左上角的
/// `BD` / `UHD` / `DVD` 角标（多盘合集 `BD ×3`），以及筛选面板「规格」组真的作用在
/// 条目上。盘的规格由注入的解析器给（不读磁盘）：盘根名含 `UHD` 的判 UHD。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_disc_spec_pp');
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
    try {
      pathProviderDir.deleteSync(recursive: true);
    } catch (_) {}
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
    // 「全部视频」默认只看散片；这里把散片 / 合集都放出来。
    await prefs.setVideoAllSeriesFilterName('all');
    storeDir = Directory.systemTemp.createTempSync('fushi_disc_spec');
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

  Widget buildApp(VideoLibrarySection section) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
      discFormatResolverProvider.overrideWithValue(
        DiscFormatResolver(
          readFormat: (String root) async => p.basename(root).contains('UHD')
              ? DiscFormat.uhdBluray
              : DiscFormat.bluray,
        ),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeVideoPage(repo: VideoBookRepository(db), section: section),
        ),
      ),
    ),
  );

  Future<void> pumpSection(
    WidgetTester tester,
    VideoLibrarySection section,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section));
    await tester.pumpAndSettle();
  }

  Future<void> seedVideo(String uid, String title, String path) =>
      db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(title),
          videoPath: Value<String>(path),
          importedAt: Value<int>(DateTime(2026, 1, 4).millisecondsSinceEpoch),
        ),
      );

  String mpls(String disc, [String id = '00001']) =>
      p.join(p.separator, 'lib', disc, 'BDMV', 'PLAYLIST', '$id.mpls');

  Finder cardOf(String uid) => find.byKey(ValueKey<String>('home_video_$uid'));

  Finder badgeOf(String uid) =>
      find.byKey(ValueKey<String>('home_video_disc_badge_$uid'));

  /// 散片：一条 DVD title、一张 UHD 盘的正片、一个普通文件。
  Future<void> seedLoose() async {
    await seedVideo(
      'video/dvd',
      'DVD 正片',
      dvdTitlePath(p.join(p.separator, 'lib', 'Show'), 2),
    );
    await seedVideo('video/uhd', 'UHD 正片', mpls('Movie UHD'));
    await seedVideo('video/plain', '普通', p.join(p.separator, 'lib', 'a.mkv'));
  }

  testWidgets('单作品卡：DVD / UHD 角标，普通文件没有角标', (WidgetTester tester) async {
    await seedLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);

    expect(
      find.descendant(of: badgeOf('video/dvd'), matching: find.text('DVD')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: badgeOf('video/uhd'), matching: find.text('UHD')),
      findsOneWidget,
    );
    expect(badgeOf('video/plain'), findsNothing);
    expect(cardOf('video/plain'), findsOneWidget);
  });

  testWidgets('三张盘归进一个合集：合集卡 BD ×3', (WidgetTester tester) async {
    for (int i = 1; i <= 3; i++) {
      await seedVideo('video/vol$i', 'Vol.$i', mpls('Vol$i'));
    }
    final int cid = await db.createMediaCollection(
      '魔女之旅',
      collectionType: 'playlist',
    );
    for (int i = 1; i <= 3; i++) {
      await db.addToCollection(cid, MediaKind.video, 'video/vol$i');
    }
    await pumpSection(tester, VideoLibrarySection.series);

    final Finder badge = find.byKey(
      ValueKey<String>('home_video_collection_disc_badge_$cid'),
    );
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('BD ×3')),
      findsOneWidget,
    );
  });

  testWidgets('筛选面板「规格」：多选命中、清除后复原', (WidgetTester tester) async {
    await seedLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);

    Future<void> togglePanel(String label) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('video-library-filter-button')),
      );
      await tester.pumpAndSettle();
      final Finder section = find.byKey(
        const ValueKey<String>('video_filter_panel_spec'),
      );
      expect(section, findsOneWidget, reason: '「规格」组在看完状态之后');
      await tester.tap(
        find.descendant(of: section, matching: find.text(label)),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }

    await togglePanel(t.video_filter_spec_dvd);
    expect(cardOf('video/dvd'), findsOneWidget);
    expect(cardOf('video/uhd'), findsNothing);
    expect(cardOf('video/plain'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('video_active_filter_spec')),
      findsOneWidget,
    );

    await togglePanel(t.video_filter_spec_uhd_bluray);
    expect(cardOf('video/dvd'), findsOneWidget);
    expect(cardOf('video/uhd'), findsOneWidget);
    expect(cardOf('video/plain'), findsNothing);

    await togglePanel(t.video_filter_spec_bluray);
    await togglePanel(t.video_filter_spec_dvd);
    await togglePanel(t.video_filter_spec_uhd_bluray);
    expect(cardOf('video/uhd'), findsNothing, reason: 'UHD 盘不算「BD 原盘」档');
    expect(cardOf('video/dvd'), findsNothing);

    await togglePanel(t.video_filter_spec_plain_file);
    expect(cardOf('video/plain'), findsOneWidget);

    // 生效 chip 的 ✕ 一键复位。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('video_active_filter_spec')),
        matching: find.byIcon(FushiIcons.close),
      ),
    );
    await tester.pumpAndSettle();
    expect(cardOf('video/dvd'), findsOneWidget);
    expect(cardOf('video/uhd'), findsOneWidget);
    expect(cardOf('video/plain'), findsOneWidget);
  });
}
