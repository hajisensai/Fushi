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
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 「全部视频」的系列归属筛选。
///
/// 「全部视频」逐条平铺整库（BUG-1839：它与系列页的区别只是折叠方式），于是一部
/// 番的几十集会把还没归进系列的散片淹掉。这个档位让用户按**在系列视图里的折叠
/// 形态**筛：全部 / 只看系列内的集 / 只看非系列的散片。
///
/// 下面钉死三件事：
/// * 三档过滤真的作用在条目上（不是只改 UI）；
/// * 归属指向已删合集的孤儿条目算「非系列」——判据与库网格折叠
///   （`collection_grouping.dart` 的 `collectionIdOf`）同源，不许分叉；
/// * 控件只在「全部视频」露出，且别的分区不被它隐形过滤（三个分区共用同一个
///   State 实例，档位泄漏会在没有控件可复位的页面上吃掉条目）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_series_filter_pp',
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
    storeDir = Directory.systemTemp.createTempSync('fushi_series_filter');
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

  Widget buildApp(VideoLibrarySection section) => ProviderScope(
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
                section: section,
              ),
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

  Future<void> seedVideo(String uid, String title) => db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(title),
          videoPath: Value<String>('/abs/$uid.mp4'),
          importedAt: Value<int>(DateTime(2026, 1, 4).millisecondsSinceEpoch),
        ),
      );

  /// 一部两集的番（合集）+ 一部没归系列的散片。
  Future<int> seedSeriesAndLoose() async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/loose', '散片');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');
    return cid;
  }

  /// 打开系列归属下拉并选中 [label] 那一档。
  Future<void> pickSeriesFilter(WidgetTester tester, String label) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_filter_series')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Finder cardOf(String uid) => find.byKey(ValueKey<String>('home_video_$uid'));

  testWidgets('默认档位「全部」：系列的集与散片同时平铺', (WidgetTester tester) async {
    await seedSeriesAndLoose();

    await pumpSection(tester, VideoLibrarySection.allVideos);

    expect(cardOf('video/ep1'), findsOneWidget);
    expect(cardOf('video/ep2'), findsOneWidget);
    expect(cardOf('video/loose'), findsOneWidget);
  });

  testWidgets('选「非系列」后系列的集被收掉，只剩散片', (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);

    await pickSeriesFilter(tester, t.video_filter_series_standalone);

    expect(
      cardOf('video/ep1'),
      findsNothing,
      reason: '已归进系列的集必须从「全部视频」平铺里消失——这正是本档位的目的',
    );
    expect(cardOf('video/ep2'), findsNothing);
    expect(
      cardOf('video/loose'),
      findsOneWidget,
      reason: '没归系列的散片必须留下',
    );
  });

  testWidgets('选「系列内」后只剩系列的集', (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);

    await pickSeriesFilter(tester, t.video_filter_series_in);

    expect(cardOf('video/ep1'), findsOneWidget);
    expect(cardOf('video/ep2'), findsOneWidget);
    expect(
      cardOf('video/loose'),
      findsNothing,
      reason: '反向档位必须是同一判据取反，不能两处口径漂开',
    );
  });

  testWidgets('归属指向已删合集的孤儿条目按「非系列」算（与库网格折叠同口径）',
      (WidgetTester tester) async {
    await seedVideo('video/orphan', '孤儿归属');
    final int cid = await db.createMediaCollection(
      '待删合集',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/orphan');
    // 只删合集行、留下成员行：`collection_grouping.dart` 的 `collectionIdOf` 对
    // 这种孤儿引用退化为散条目（无 DB FK 兜底，读取期过滤），筛选必须同口径。
    await db.customStatement(
      'DELETE FROM media_collections WHERE id = ?',
      <Object?>[cid],
    );
    expect(
      await db.getCollectionItems(cid),
      isNotEmpty,
      reason: '前提：成员行必须还在，否则这条测的不是孤儿归属',
    );

    await pumpSection(tester, VideoLibrarySection.allVideos);
    await pickSeriesFilter(tester, t.video_filter_series_standalone);

    expect(
      cardOf('video/orphan'),
      findsOneWidget,
      reason: '合集已不存在 = 墙上本来就是散卡，不能被当成系列成员筛掉',
    );
  });

  testWidgets('档位不泄漏到别的分区（三分区共用同一个 State 实例）',
      (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);
    await pickSeriesFilter(tester, t.video_filter_series_in);
    expect(cardOf('video/loose'), findsNothing, reason: '前提：档位已生效');

    // 同一 widget 位置换 section（与 video_library_shell 换 section: 参数同构）
    // → State 复用，_seriesFilter 仍是「系列内」。
    await tester.pumpWidget(buildApp(VideoLibrarySection.series));
    await tester.pumpAndSettle();

    expect(
      cardOf('video/loose'),
      findsOneWidget,
      reason: '系列页没有这个筛选控件，绝不能被「全部视频」留下的档位隐形吃掉散片',
    );

    // 证明上一条不是因为 State 被重建、档位复位成「全部」才通过的：切回去档位
    // 还在。没有这一步，去掉 _effectiveSeriesFilter 门控也能让上一条恒绿。
    await tester.pumpWidget(buildApp(VideoLibrarySection.allVideos));
    await tester.pumpAndSettle();
    expect(
      cardOf('video/loose'),
      findsNothing,
      reason: 'State 确实被复用、档位确实还挂着——上一条测的才是门控',
    );
  });

  testWidgets('「系列内」档位下全选真的勾得上（候选取可见散卡序，不再二次推导资格）',
      (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);
    await pickSeriesFilter(tester, t.video_filter_series_in);

    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.batch_select_all));
    await tester.pumpAndSettle();

    expect(
      find.text(t.batch_selected_count(n: 2)),
      findsOneWidget,
      reason: '「全部视频」墙上没有合集卡，每一集都是独立散卡——全选必须把它们'
          '都勾上。按「跳过合集成员」的旧资格判据这里会是 0（no-op）',
    );
  });

  testWidgets('筛选控件只在「全部视频」露出', (WidgetTester tester) async {
    await seedSeriesAndLoose();

    await pumpSection(tester, VideoLibrarySection.series);

    expect(
      find.byKey(const ValueKey<String>('home_video_filter_series')),
      findsNothing,
      reason: '系列页本身就按合集折叠，再给它这个档位没有意义',
    );
    expect(
      find.byKey(const ValueKey<String>('home_video_filter_year')),
      findsOneWidget,
      reason: '另外两个筛选照常在（确认这条断言不是因为整栏没渲染而假绿）',
    );
  });
}
