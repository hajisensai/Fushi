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

  testWidgets('切档位后被筛走的选中项不再计数（幽灵选中）', (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);

    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
    await tester.tap(cardOf('video/ep1'));
    await tester.pump();
    await tester.tap(cardOf('video/loose'));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    await pickSeriesFilter(tester, t.video_filter_series_standalone);

    expect(
      find.text(t.batch_selected_count(n: 1)),
      findsOneWidget,
      reason: 'ep1 已被筛走、屏幕上没有它，底栏就不能还把它算进「已选」——'
          '用户是照着这个数字点删除的',
    );

    // 但它只是看不见，不是被系统替用户取消了：切回来还在。
    await pickSeriesFilter(tester, t.home_filter_all);
    expect(
      find.text(t.batch_selected_count(n: 2)),
      findsOneWidget,
      reason: '先勾后筛是合法用法，筛选切回来选中必须原样还在',
    );
  });

  testWidgets('切到首页分区后计数归零（首页没有可勾选的格）',
      (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
    await tester.tap(cardOf('video/ep1'));
    await tester.pump();
    await tester.tap(cardOf('video/loose'));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    // 三个分区共用同一个 State，批量栏不按分区门控：切到首页后它照样显示，
    // 而首页只有 hero + 横滚行（横滚行卡不参与勾选），一个可勾选的格都没有。
    await tester.pumpWidget(buildApp(VideoLibrarySection.home));
    await tester.pumpAndSettle();

    expect(
      find.text(t.batch_selected_count(n: 2)),
      findsNothing,
      reason: '首页从不登记可见序，计数会停在「全部视频」那一档——批量删除于是'
          '作用在一批首页上根本没画出来的条目上',
    );

    // 证明上一条不是因为 State 被重建、选中丢了：切回去还在。
    await tester.pumpWidget(buildApp(VideoLibrarySection.allVideos));
    await tester.pumpAndSettle();
    expect(
      find.text(t.batch_selected_count(n: 2)),
      findsOneWidget,
      reason: '选中集无损保留，只是首页那一帧不暴露',
    );
  });

  testWidgets('筛到一条不剩时计数归零（空态帧也要如实登记「屏幕上没有卡」）',
      (WidgetTester tester) async {
    // 库里只有系列成员，没有任何散片：选「非系列」会筛到 0 条，走筛选空态。
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    await pumpSection(tester, VideoLibrarySection.allVideos);
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
    await tester.tap(cardOf('video/ep1'));
    await tester.pump();
    await tester.tap(cardOf('video/ep2'));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    await pickSeriesFilter(tester, t.video_filter_series_standalone);

    expect(
      find.text(t.tag_no_books_for_filter),
      findsOneWidget,
      reason: '前提：这一档确实筛到 0 条，走的是筛选空态那条分支',
    );
    expect(
      find.text(t.batch_selected_count(n: 2)),
      findsNothing,
      reason: '空态帧此前在登记可见序之前就提前 return，可见序停在上一档——'
          '墙上一张卡都没有，底栏却还写着「已选 2」，点删除会真的删掉它们',
    );
  });

  testWidgets('筛到一条不剩时全选勾不中任何条目（空态帧照样登记可见序）',
      (WidgetTester tester) async {
    // 上一条量的是「已选计数」，这一条量的是「全选候选集」：同一份可见序
    // 喂给两条不同的消费路径，只修其中一条都会把另一条留成真删错条目。
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    await pumpSection(tester, VideoLibrarySection.allVideos);
    // 前提：这一帧登记了两张可见散卡——空态帧要清掉的正是它。
    expect(cardOf('video/ep1'), findsOneWidget);

    await pickSeriesFilter(tester, t.video_filter_series_standalone);
    expect(cardOf('video/ep1'), findsNothing, reason: '前提：确实筛成了空态');
    expect(cardOf('video/ep2'), findsNothing);

    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.batch_select_all));
    await tester.pumpAndSettle();

    expect(
      find.text(t.batch_selected_count(n: 0)),
      findsOneWidget,
      reason: '空态是提前 return 的，可见序若不在早退处登记就留着上一帧那两张卡'
          '——「筛到一条不剩 → 全选 → 批量删除」会删掉屏幕上根本不存在的条目',
    );
    expect(
      find.text(t.batch_selected_count(n: 2)),
      findsNothing,
      reason: '兜住上一条：别因为计数控件整个没渲染而假绿',
    );
  });

  testWidgets('chip 在「全部」态显示维度名，选中档位后显示档位名',
      (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home_video_filter_series')),
        matching: find.text(t.video_filter_series),
      ),
      findsOneWidget,
      reason: '「全部」态的 chip 要回答「这个下拉管什么」',
    );

    await pickSeriesFilter(tester, t.video_filter_series_standalone);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home_video_filter_series')),
        matching: find.text(t.video_filter_series_standalone),
      ),
      findsOneWidget,
      reason: '选了档位后 chip 显示当前档位',
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
