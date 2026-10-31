import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart'
    show selectedTagIdsProvider;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-1808：视频首页（[VideoLibrarySection.home]）横滚行卡必须画用户标签。
///
/// series-first 拆分把墙格从首页移去「系列 / 全部视频」后，首页只剩 hero + 三条
/// 横滚行；标签层当时只写在墙卡 `_buildCard` 上，于是「打了标签，首页一个都看不
/// 见」。这几条断言就是那个缺口的行为门：继续观看行的散卡、合集卡与最近添加行卡
/// 各自认自己那条标签，没打标签的卡不得凭空长出 chip。
///
/// 2026-10 首页重设计：继续观看的第一项提成首屏主卡（key 沿用继续观看卡），主卡
/// 是大图 + 标题 + 按钮的版式、**不画标签**；「下一集」行并入继续观看。所以测
/// 继续观看行卡时先种一部更近播放的「主卡占位」（[seedHeroDecoy]），被测卡才会
/// 落进横滚行。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_home_row_tags_pp',
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
    storeDir = Directory.systemTemp.createTempSync('fushi_home_row_tags_store');
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

  Widget buildApp({
    VideoLibrarySection section = VideoLibrarySection.home,
    List<RemoteVideoInfo> remote = const <RemoteVideoInfo>[],
  }) => ProviderScope(
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
            remoteVideoClientLoader: remote.isEmpty
                ? null
                : () async => _ListFakeRemoteVideoClient(remote),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpHome(
    WidgetTester tester, {
    VideoLibrarySection section = VideoLibrarySection.home,
    List<RemoteVideoInfo> remote = const <RemoteVideoInfo>[],
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section: section, remote: remote));
    await tester.pumpAndSettle();
  }

  /// 有播放痕迹（未看完）→ 进首屏继续观看区（FushiContinueSpotlight）。
  Future<void> seedInProgress(String uid, String title) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(title),
      videoPath: Value<String>('/abs/$title.mp4'),
      lastPositionMs: const Value<int>(60000),
    ),
  );

  /// 一部最近刚播放（`lastPlayedAt` = 现在）的在看合集：它是继续观看的第一项、
  /// 占首屏主卡，其余在看条目落到首屏小卡。返回合集 id。
  Future<int> seedHeroDecoy() async {
    final int cid = await db.createMediaCollection(
      'HeroDecoy',
      collectionType: 'playlist',
    );
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/hero-decoy'),
        title: const Value<String>('HeroDecoy Ep1'),
        videoPath: const Value<String>('/abs/hero-decoy.mp4'),
        lastPositionMs: const Value<int>(60000),
        lastPlayedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    await db.addToCollection(cid, MediaKind.video, 'video/hero-decoy');
    return cid;
  }

  // 2026-10-25 库页材质定版：封面上不再压标签 chip，标签收成封面下副行尾部的
  // 色点，全名在 tooltip（与无障碍语义）里——按 tooltip 文案定位。
  Finder tagTextIn(String cardKey, String tagName) => find.descendant(
    of: find.byKey(ValueKey<String>(cardKey)),
    matching: find.byWidgetPredicate(
      (Widget w) =>
          w is Tooltip && (w.message ?? '').split(' · ').contains(tagName),
    ),
  );

  // 2026-10-28 方案 F：继续观看全在首屏 FushiContinueSpotlight（16:9 剧照卡，
  // 图下只有一行片名），与原首屏主卡同一口径不画标签；标签（BUG-1808）留在
  // 「已更新未看」「最近添加」行卡与库墙卡上。散片 / 合集 / 远端三种卡一起钉：
  // 任一种悄悄长出标签都会红。
  testWidgets('首屏继续观看卡不画标签（散片 / 合集 / 远端）', (WidgetTester tester) async {
    await seedHeroDecoy();
    await seedInProgress('video/tagged', 'Tagged Show');
    final int looseTag = await db.createTag('WatchLater', 0xFF2196F3);
    await db.addTagToVideoBook('video/tagged', looseTag);
    final int cid = await db.createMediaCollection(
      'MyShow',
      collectionType: 'playlist',
    );
    await seedInProgress('video/ep1', 'Ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    final int collectionTag = await db.createTag('Airing', 0xFFFF9800);
    await db.addTagToCollection(cid, collectionTag);

    await pumpHome(
      tester,
      remote: const <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/remote-watching',
          title: 'Remote Watching',
          positionMs: 60000,
          positionUpdatedAtMs: 1700000000000,
          tags: <String>['HostTag'],
        ),
      ],
    );

    for (final (String key, String tag) in <(String, String)>[
      ('home_video_continue_video/tagged', 'WatchLater'),
      ('home_video_continue_collection_$cid', 'Airing'),
      ('home_video_continue_remote_video_remote-watching', 'HostTag'),
    ]) {
      final Finder card = find.byKey(ValueKey<String>(key));
      expect(card, findsOneWidget, reason: '前提：$key 在首屏继续观看区');
      expect(
        find.ancestor(of: card, matching: find.byType(FushiContinueSpotlight)),
        findsOneWidget,
        reason: '前提：$key 是首屏卡，不是横滚行卡',
      );
      expect(tagTextIn(key, tag), findsNothing, reason: '首屏继续观看卡不画标签');
    }
  });

  testWidgets('最近添加行的卡显示该视频的标签', (WidgetTester tester) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/fresh'),
        title: const Value<String>('Fresh Show'),
        videoPath: const Value<String>('/abs/fresh.mp4'),
        importedAt: Value<int>(nowMs),
      ),
    );
    final int tagId = await db.createTag('Backlog', 0xFF4CAF50);
    await db.addTagToVideoBook('video/fresh', tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_recent_video/fresh', 'Backlog'),
      findsOneWidget,
      reason: '「最近添加」行卡与「继续观看」同一标签口径',
    );
  });

  // 首页 overview 原有**三条**横滚行（继续观看 / 下一集 / 最近添加），每条都可能
  // 出合集卡。上面三条只覆盖了继续观看的散卡/合集卡与最近添加的散卡，剩下两处
  // 合集卡当初就是这么漏掉的——补画时同样漏了一遍。按行 × 卡型逐格补齐。
  // 2026-10 重设计后「下一集」并入继续观看；2026-10-28 继续观看全在首屏、不画
  // 标签。这条留着钉 Next-Up 合集卡的副标题：首屏小卡压的是完整的「下一集 ·
  // 第 N 集」（曾按分隔符切成只剩「下一集」，集数丢了）。
  testWidgets('首屏 Next-Up 合集小卡压完整的「下一集 · 第 N 集」、不画标签', (
    WidgetTester tester,
  ) async {
    await seedHeroDecoy();
    final int cid = await db.createMediaCollection(
      'NextShow',
      collectionType: 'playlist',
    );
    // Next-Up 落到下一集：最后实际播放的那集已看完，且序列里还有下一集。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/next-ep1'),
        title: const Value<String>('NextShow Ep1'),
        videoPath: const Value<String>('/abs/next-ep1.mp4'),
        lastPositionMs: const Value<int>(60000),
        completedAt: Value<DateTime>(DateTime.now()),
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/next-ep2'),
        title: const Value<String>('NextShow Ep2'),
        videoPath: const Value<String>('/abs/next-ep2.mp4'),
      ),
    );
    await db.addToCollection(cid, MediaKind.video, 'video/next-ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/next-ep2');
    final int tagId = await db.createTag('NextUp', 0xFF9C27B0);
    await db.addTagToCollection(cid, tagId);

    await pumpHome(tester);

    expect(
      find.descendant(
        of: find.byKey(ValueKey<String>('home_video_continue_collection_$cid')),
        matching: find.text(t.video_home_next_episode_number(n: 2)),
      ),
      findsOneWidget,
      reason: '小卡必须压完整的「下一集 · 第 2 集」，不能只剩「下一集」',
    );
    expect(
      tagTextIn('home_video_continue_collection_$cid', 'NextUp'),
      findsNothing,
      reason: '首屏继续观看卡不画标签',
    );
  });

  testWidgets('「最近添加」行的合集卡显示合集自己的标签', (WidgetTester tester) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int cid = await db.createMediaCollection(
      'FreshShow',
      collectionType: 'playlist',
    );
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/fresh-ep1'),
        title: const Value<String>('FreshShow Ep1'),
        videoPath: const Value<String>('/abs/fresh-ep1.mp4'),
        importedAt: Value<int>(nowMs),
      ),
    );
    await db.addToCollection(cid, MediaKind.video, 'video/fresh-ep1');
    final int tagId = await db.createTag('JustAdded', 0xFF00BCD4);
    await db.addTagToCollection(cid, tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_recent_collection_$cid', 'JustAdded'),
      findsOneWidget,
      reason: '「最近添加」行的合集卡与其它行同一标签口径（BUG-1808 补齐）',
    );
  });
  testWidgets('首屏主卡不画标签（标签只在横滚行卡 / 墙卡上）', (WidgetTester tester) async {
    final int heroCid = await seedHeroDecoy();
    final int tagId = await db.createTag('HeroTag', 0xFF3F51B5);
    await db.addTagToCollection(heroCid, tagId);

    await pumpHome(tester);

    final Finder hero = find.byKey(
      ValueKey<String>('home_video_continue_collection_$heroCid'),
    );
    expect(hero, findsOneWidget, reason: '唯一在看的一部被提成首屏主卡');
    expect(
      find.ancestor(of: hero, matching: find.byType(FushiContinueSpotlight)),
      findsOneWidget,
      reason: '前提：这张是首屏主卡（FushiContinueSpotlight），不是横滚行卡',
    );
    expect(
      tagTextIn('home_video_continue_collection_$heroCid', 'HeroTag'),
      findsNothing,
      reason: '首屏主卡是剧照 + 片名 + 进度版式，不画标签',
    );
  });

  // ── 远端占位卡：host 清单下发的是标签**名**（标签本身每设备本地） ──────────

  testWidgets('远端标签借本机同名标签的颜色，本机没有则走 chip 默认色', (WidgetTester tester) async {
    const int knownColor = 0xFF9C27B0;
    await db.createTag('Known', knownColor);

    // 远端卡要落进画标签的横滚行：刚入库、没播过 →「最近添加」行（继续观看
    // 全在首屏、不画标签）。
    await pumpHome(
      tester,
      remote: <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/remote-colored',
          title: 'Remote Colored',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          tags: const <String>['Known', 'Unknown'],
        ),
      ],
    );

    // 标签色点按标签顺序排（Known、Unknown），全名在 tooltip 里。
    final Finder dots = find.descendant(
      of: find.byTooltip('Known · Unknown'),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle,
      ),
    );
    expect(dots, findsNWidgets(2));
    Color? dotColor(int i) =>
        ((tester.widget<DecoratedBox>(dots.at(i)).decoration) as BoxDecoration)
            .color;
    final ColorScheme cs = Theme.of(
      tester.element(find.byTooltip('Known · Unknown')),
    ).colorScheme;

    expect(
      dotColor(0),
      const Color(knownColor),
      reason: '本机有同名标签就借它的颜色，两端看同一条标签颜色才一致',
    );
    expect(
      dotColor(1),
      cs.onSurfaceVariant,
      reason: 'host 只下发名字，本机没这条标签时不得凭空造颜色（走中性默认色）',
    );
  });

  testWidgets('「全部视频」墙格里的远端占位卡也显示标签（封面无字幕角标）', (WidgetTester tester) async {
    await pumpHome(
      tester,
      section: VideoLibrarySection.allVideos,
      remote: const <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/remote-wall',
          title: 'Remote Wall',
          hasSubtitle: true,
          tags: <String>['WallTag'],
        ),
      ],
    );

    expect(
      tagTextIn('remote_video_card_video_remote-wall', 'WallTag'),
      findsOneWidget,
      reason: '墙格远端卡此前左上角只有字幕角标，标签整层缺失',
    );
    // 2026-10-25「全部都不用角标设计」：字幕角标撤掉（「包含字幕」在长按信息
    // 面板里），封面上不再压任何角标。
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('remote_video_card_video_remote-wall'),
        ),
        matching: find.byIcon(Icons.subtitles_outlined),
      ),
      findsNothing,
      reason: '封面上不再压字幕角标',
    );
  });

  // 反馈 ZjKzpkfZ1N：首页分区没有任何筛选入口，标签选中状态却与系列 / 全部视频
  // （以及书架）共享。在系列页选中一个首页条目都没打的标签后切回首页，首页不能
  // 被静默筛空——继续观看主卡 / 行照常出现。
  testWidgets('在别的分区选中的标签不筛首页', (WidgetTester tester) async {
    await seedHeroDecoy();
    await seedInProgress('video/untagged', 'Untagged Show');
    final int tagId = await db.createTag('Elsewhere', 0xFF607D8B);

    await pumpHome(tester);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(HomeVideoPage)),
    );
    container.read(selectedTagIdsProvider.notifier).state = <int>{tagId};
    await tester.pumpAndSettle();

    expect(container.read(selectedTagIdsProvider), <int>{tagId});
    expect(
      find.byKey(const ValueKey<String>('home_video_continue_video/untagged')),
      findsOneWidget,
      reason: '首页不吃标签筛选：没打该标签的在看条目照样出现在继续观看',
    );
  });
}

class _ListFakeRemoteVideoClient implements RemoteVideoClient {
  _ListFakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => _videos;

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async => const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    void Function(double progress)? onProgress,
    int episodeIndex = 0,
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}
