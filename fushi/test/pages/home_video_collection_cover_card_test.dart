import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 合集封面卡渲染守卫（用户拍板 2026-07-22：视频页合集从全宽横排行改回封面卡，
/// 「一进去就是封面，跟小说那种一样，一眼认出是哪部」）：
///  - 有封面成员 → 卡显该成员封面（借用组内首个有封面的本地成员）；
///  - 无封面 → 占位（surfaceContainer + movie 图标，与散卡同款）；
///  - 集数角标 = 全部成员数；进度行「已看完 x/N」/「继续看 第n集」；
///  - 点击整卡 → 进合集详情页（原「查看全部」）；
///  - 拖标签到卡 → 给整个合集打标签（真写穿内存 DB）。
/// 多选整选另见 home_video_batch_collection_ops_test（块2）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  /// 1x1 透明 PNG（真实可解码文件，喂 Image.file）。
  final List<int> onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
    'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_cover_card_pp',
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
      pathProviderDir.deleteSync(recursive: true);
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
    storeDir = Directory.systemTemp.createTempSync('fushi_cover_card');
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

  Future<void> seedEpisode(
    String uid,
    String title, {
    String? coverPath,
    DateTime? completedAt,
    int lastPositionMs = 0,
    int? lastPlayedAt,
  }) async {
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/abs/$uid.mp4'),
        coverPath: Value(coverPath),
        completedAt: Value(completedAt),
        lastPositionMs: Value(lastPositionMs),
        lastPlayedAt: Value(lastPlayedAt),
        importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
      ),
    );
  }

  /// 建合集并给它一条 **AniDB 主身份**。
  ///
  /// 系列墙的入墙资格是「有 AniDB primary identity 的规范作品」（
  /// `aniDbScrapedVideoCollectionIds()`，见 video_library_series_structure_guard）。
  /// 本文件测的是封面借用链与角标，不是入墙资格；不种身份的话每条用例都会停在
  /// 「合集卡根本没渲染」上，测不到它真正要守的东西。
  Future<int> seedCollection(List<String> uids, {String name = '某番剧'}) async {
    final int cid = await db.createMediaCollection(
      name,
      collectionType: 'playlist',
    );
    for (final String uid in uids) {
      await db.addToCollection(cid, MediaKind.video, uid);
    }
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        mediaType: 'tv',
        title: name,
        collectionId: Value<int?>(cid),
        updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:anidb',
          provider: 'anidb',
          externalId: 'anidb-$cid',
          isPrimary: const Value<bool>(true),
          updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
        ),
      ],
    );
    return cid;
  }

  /// BUG-3756：封面存在性改为 async 探测（build 里不再同步 stat），真实 IO 在
  /// fakeAsync 下不会完成。回退链每级候选一次探测 + 一次重建，按链深各给一轮
  /// runAsync + pump；最后让 FileImage 在真实事件循环里读完（Windows 下 tearDown
  /// 删临时目录要求句柄已关）。
  Future<void> settleCoverProbes(WidgetTester tester, {int rounds = 4}) async {
    // 封面链每级一次探测 + 一次重建；之后封面图源的真实文件读取（打开 → 读 → 关）
    // 每一步的续体都排在 fakeAsync 里，要 runAsync 让 IO 回话、再 pump 跑续体，多给
    // 几轮让句柄关掉，否则 tearDown 删临时目录会撞「文件被占用」（Windows）。
    for (int i = 0; i < rounds + 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

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
            section: VideoLibrarySection.series,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    // TODO-2486：顶部新增 hero 轮播 + 横滚行，800 高视口下墙 sliver 会被懒构建
    // 跳过（根本不 build）；抬高视口让墙可见，交互/断言不受顶部区块高度影响。
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await settleCoverProbes(tester);
  }

  Finder cardFinder(int cid) =>
      find.byKey(ValueKey<String>('home_video_collection_card_$cid'));

  testWidgets('触屏未进选择态长按视频合集卡仍弹合集菜单', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    final int cid = await seedCollection(<String>['video/ep1']);

    await pumpPage(tester);
    await tester.longPress(cardFinder(cid));
    await tester.pumpAndSettle();

    expect(
      find.text(t.rename_collection),
      findsOneWidget,
      reason: '触屏长按合集卡必须保留上下文菜单',
    );
    expect(
      find.text(t.batch_selected_count(n: 1)),
      findsNothing,
      reason: '未点明确「选择」入口时不得暗中整选合集',
    );
  });

  testWidgets('有封面成员 → 卡显该成员封面（借用组内首个有封面的本地成员）', (WidgetTester tester) async {
    // ep1 无封面、ep2 有封面：组内序首成员缺封面时向后借。
    final File cover = File('${storeDir.path}/ep2_cover.png')
      ..writeAsBytesSync(onePixelPng);
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集', coverPath: cover.path);
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);

    final Finder images = find.descendant(
      of: cardFinder(cid),
      matching: find.byType(Image),
    );
    // 材质库页：合集是碟盒叠层（后两层 + 前层），前层最后绘制 = 最后一张。
    expect(images, findsWidgets, reason: '合集卡必须渲染成员封面');
    final Image image = tester.widget<Image>(images.last);
    final ImageProvider provider = image.image;
    final FileImage fileImage =
        (provider is ResizeImage ? provider.imageProvider : provider)
            as FileImage;
    expect(fileImage.file.path, cover.path, reason: '封面必须借用组内首个有封面的本地成员（ep2）');
    // 有封面时不显示占位图标。
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.byIcon(FushiIcons.video),
      ),
      findsNothing,
    );
  });

  // BUG-1211：合集有了自己的封面列（MediaCollections.coverPath, schema v61）。
  // 它必须**压过**成员借用链——否则「给合集换封面」写了库也看不见变化。
  testWidgets('BUG-1211 合集自有封面优先于成员借用；成员封面原封不动', (WidgetTester tester) async {
    final File memberCover = File('${storeDir.path}/ep1_cover.png')
      ..writeAsBytesSync(onePixelPng);
    final File ownCover = File('${storeDir.path}/collection_own.png')
      ..writeAsBytesSync(onePixelPng);
    await seedEpisode('video/ep1', '第1集', coverPath: memberCover.path);
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);
    await db.updateMediaCollectionCoverPath(cid, ownCover.path);

    await pumpPage(tester);

    // 叠层前层最后绘制 = 最后一张 Image。
    final Image image = tester.widget<Image>(
      find.descendant(of: cardFinder(cid), matching: find.byType(Image)).last,
    );
    final ImageProvider provider = image.image;
    final FileImage fileImage =
        (provider is ResizeImage ? provider.imageProvider : provider)
            as FileImage;
    expect(
      fileImage.file.path,
      ownCover.path,
      reason: '合集卡必须显示合集自有封面，而不是借来的成员封面',
    );
    // 成员那张封面一个字节没动（换合集封面绝不写成员）。
    expect(
      (await VideoBookRepository(db).getByBookUid('video/ep1'))?.coverPath,
      memberCover.path,
    );
  });

  // 老库/从没换过封面的合集：coverPath 为 NULL → 行为与 v61 之前逐像素一致。
  testWidgets('BUG-1211 合集自有封面为空 → 仍回落成员借用链（老数据不变白）', (
    WidgetTester tester,
  ) async {
    final File memberCover = File('${storeDir.path}/ep1_fallback.png')
      ..writeAsBytesSync(onePixelPng);
    await seedEpisode('video/ep1', '第1集', coverPath: memberCover.path);
    final int cid = await seedCollection(<String>['video/ep1']);
    expect((await db.getMediaCollectionById(cid))?.coverPath, isNull);

    await pumpPage(tester);

    // 叠层前层最后绘制 = 最后一张 Image。
    final Image image = tester.widget<Image>(
      find.descendant(of: cardFinder(cid), matching: find.byType(Image)).last,
    );
    final ImageProvider provider = image.image;
    final FileImage fileImage =
        (provider is ResizeImage ? provider.imageProvider : provider)
            as FileImage;
    expect(fileImage.file.path, memberCover.path);
  });

  // 悬空路径（overwrite 备份恢复会把源机绝对路径原样带过来，备份不打包 video_covers/）：
  // 必须表现得像「没设过封面」，不能出破图 / 空白卡。
  testWidgets('BUG-1211 合集自有封面文件不存在 → 回落成员封面，不出破图', (
    WidgetTester tester,
  ) async {
    final File memberCover = File('${storeDir.path}/ep1_dangling.png')
      ..writeAsBytesSync(onePixelPng);
    await seedEpisode('video/ep1', '第1集', coverPath: memberCover.path);
    final int cid = await seedCollection(<String>['video/ep1']);
    await db.updateMediaCollectionCoverPath(
      cid,
      '${storeDir.path}/does_not_exist.png',
    );

    await pumpPage(tester);

    // 叠层前层最后绘制 = 最后一张 Image。
    final Image image = tester.widget<Image>(
      find.descendant(of: cardFinder(cid), matching: find.byType(Image)).last,
    );
    final ImageProvider provider = image.image;
    final FileImage fileImage =
        (provider is ResizeImage ? provider.imageProvider : provider)
            as FileImage;
    expect(fileImage.file.path, memberCover.path);
  });

  testWidgets('无封面 → 占位图标；封面无角标；默认副行「已看完 0/N」', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);

    expect(cardFinder(cid), findsOneWidget);
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.byIcon(FushiIcons.video),
      ),
      findsWidgets,
      reason: '全员无封面 → 占位（与散卡同款 movie 图标，叠层每层都是占位）',
    );
    // 2026-10-25「全部都不用角标设计」：封面上不再有集数角标，成员数进副行
    // （「已看完 x/N」的 N）。
    expect(
      find.descendant(of: cardFinder(cid), matching: find.byType(CoverBadge)),
      findsNothing,
      reason: '合集封面上不压任何角标',
    );
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.text(t.collection_watched_progress(done: 0, total: 2)),
      ),
      findsOneWidget,
      reason: '无观看痕迹 → 进度行「已看完 0/N」',
    );
    // 封面卡形态：成员卡不在库页。
    expect(find.text('第1集'), findsNothing);
  });

  testWidgets('进度行：有痕迹未看完 → 「继续看 第n集」；全看完 → 「已看完 N/N」', (
    WidgetTester tester,
  ) async {
    // ep1 已看完 → 继续看候选 = 第2集。
    await seedEpisode('video/ep1', '第1集', completedAt: DateTime(2026, 1, 2));
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.textContaining(t.collection_continue_progress(n: 2)),
      ),
      findsOneWidget,
      reason: 'ep1 看完 → 继续看候选落在第2集（continueMemberIndex 同源）',
    );

    // 全部看完 → 「已看完 2/2」。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/ep2'),
        title: const Value('第2集'),
        videoPath: const Value('/abs/video/ep2.mp4'),
        completedAt: Value(DateTime(2026, 1, 3)),
        importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
      ),
    );
    HomeVideoPage.debugRefreshVideos?.call();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.text(t.collection_watched_progress(done: 2, total: 2)),
      ),
      findsOneWidget,
      reason: '全部看完 → 「已看完 N/N」',
    );
  });

  // BUG-1740：卡片进度行与详情页 hero 必须同一套续播答案。锚点时刻要认行级
  // lastPlayedAt（互联对端回灌只写它、不产生本机统计行）——此前卡片只读本机
  // 统计时钟，锚点退化成「位置最靠后的有痕迹成员」，与详情页（continueMemberIndex
  // 按 lastPlayedAt 选锚）各说各话，出现「外面第8集、进去第9集」。
  testWidgets('BUG-1740 续播标签认行级 lastPlayedAt，与详情页同锚点', (
    WidgetTester tester,
  ) async {
    // 用户在对端刚回头看了第1集（lastPlayedAt 最新）；第3集有更早的半截进度。
    // 旧实现（无统计行时取位置最靠后的痕迹成员）会答「第3集」；正确答案与
    // 详情页一致 = 锚在最近播放的第1集。
    await seedEpisode(
      'video/ep1',
      '第1集',
      lastPositionMs: 1000,
      lastPlayedAt: DateTime(2026, 2, 2).millisecondsSinceEpoch,
    );
    await seedEpisode('video/ep2', '第2集');
    await seedEpisode(
      'video/ep3',
      '第3集',
      lastPositionMs: 5000,
      lastPlayedAt: DateTime(2026, 2, 1).millisecondsSinceEpoch,
    );
    final int cid = await seedCollection(<String>[
      'video/ep1',
      'video/ep2',
      'video/ep3',
    ]);

    await pumpPage(tester);
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.textContaining(t.collection_continue_progress(n: 1)),
      ),
      findsOneWidget,
      reason:
          '锚点必须取 lastPlayedAt 最新的第1集（与详情页 continueMemberIndex 同源），'
          '不得退回「位置最靠后的痕迹成员」第3集',
    );

    // 最近播放的那集已完成 → 与详情页同规则推进到下一集。
    await seedEpisode(
      'video/ep1',
      '第1集',
      lastPositionMs: 1000,
      completedAt: DateTime(2026, 2, 2),
      lastPlayedAt: DateTime(2026, 2, 2).millisecondsSinceEpoch,
    );
    HomeVideoPage.debugRefreshVideos?.call();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.textContaining(t.collection_continue_progress(n: 2)),
      ),
      findsOneWidget,
      reason: '锚点集已完成 → 推进到下一集（第2集），与详情页 hero 同答案',
    );
  });

  testWidgets('点击合集卡 → 打开合集详情页（原「查看全部」行为）', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);
    await tester.tap(cardFinder(cid));
    await tester.pumpAndSettle();

    expect(
      find.byType(MediaCollectionDetailPage),
      findsOneWidget,
      reason: '整卡即详情入口（点某集从详情页进播放器带连播上下文）',
    );
  });

  testWidgets('拖标签到合集卡 → 给整个合集打标签（真写穿 DB）', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);
    final int tagId = await db.createTag('Anime', 0xFF2196F3);

    await pumpPage(tester);

    final Finder tagChip = find
        .descendant(
          of: find.byType(FushiTagFilterBar),
          matching: find.text('Anime'),
        )
        .first;
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(tagChip),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(cardFinder(cid)));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final List<BookTagRow> tags = await db.getTagsForCollection(cid);
    expect(
      tags.map((BookTagRow t) => t.id),
      contains(tagId),
      reason: '拖标签到封面卡必须写穿合集标签（原横排行行头能力保留）',
    );
  });

  testWidgets('BUG-3756：合集海报在网络盘上 → build 零同步文件调用，探测落定后回落成员封面', (
    WidgetTester tester,
  ) async {
    // 合集自有海报落在「网络盘」（rclone / SMB 挂载）：冷目录一次同步 stat 要数秒，
    // 旧实现在合集卡 build 里 existsSync，整页与同 isolate 的互联 host 一起冻结。
    // 这里网络盘上的任何同步文件 API 都记账；海报在网络盘上已不存在（搬家后的悬空
    // 路径），探测落定后必须回落到成员封面。
    final String netPoster = '${storeDir.path}/__fushi_net_mount__/poster.jpg';
    final File memberCover = File('${storeDir.path}/ep1_member.png')
      ..writeAsBytesSync(onePixelPng);
    await seedEpisode('video/ep1', '第1集', coverPath: memberCover.path);
    final int cid = await seedCollection(<String>['video/ep1']);
    await db.updateMediaCollectionCoverPath(cid, netPoster);

    final List<String> syncCalls = <String>[];
    final List<String> asyncProbes = <String>[];
    final Zone outer = Zone.current;
    await IOOverrides.runZoned<Future<void>>(
      () async {
        await pumpPage(tester);
        // 多重建几轮（库数据变更 / 滚动），同一候选不得重复探测。
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
      },
      createFile: (String path) => path.contains('__fushi_net_mount__')
          ? _NetMountFile(path, syncCalls, asyncProbes)
          : outer.run(() => File(path)),
    );

    expect(tester.takeException(), isNull);
    expect(syncCalls, isEmpty, reason: 'build 路径不得对网络盘封面做同步文件调用');
    // 首探一次；书架行重取（回填结束刷新）时「已知不在」的路径会 revalidateMissing
    // 再探一次。关键是全走 async，且不随每次 build 重探。
    expect(asyncProbes.toSet(), <String>{netPoster});
    expect(
      asyncProbes.length,
      lessThanOrEqualTo(2),
      reason: '结果进缓存，不随 build 重探',
    );
    // 叠层前层最后绘制 = 最后一张 Image。
    final Image image = tester.widget<Image>(
      find.descendant(of: cardFinder(cid), matching: find.byType(Image)).last,
    );
    final ImageProvider provider = image.image;
    final FileImage fileImage =
        (provider is ResizeImage ? provider.imageProvider : provider)
            as FileImage;
    expect(fileImage.file.path, memberCover.path);
  });
}

/// BUG-3756 用的「网络盘」假文件：同步 API 记账并抛错，`exists()` 记账后回 false。
class _NetMountFile implements File {
  _NetMountFile(this.path, this.syncCalls, this.asyncProbes);

  @override
  final String path;
  final List<String> syncCalls;
  final List<String> asyncProbes;

  @override
  Future<bool> exists() async {
    asyncProbes.add(path);
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    syncCalls.add('${invocation.memberName} $path');
    throw StateError('unexpected File.${invocation.memberName} on $path');
  }
}
