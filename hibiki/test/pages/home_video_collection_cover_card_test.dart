import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/media/video/scraper/collection_poster_store.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// [FilePicker] 桩：桌面（Windows FFI / Linux zenity）实现不走 MethodChannel，
/// 无法用 channel mock 拦截，改用公开的 `FilePicker.platform` setter 注入固定结果。
class _StubFilePicker extends FilePicker {
  _StubFilePicker(this._result);
  final FilePickerResult? _result;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      _result;
}

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
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_cover_card_pp');
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

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_cover_card');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    // 尽力清理：Windows 下若有 FileImage 句柄未及释放，删临时目录会 errno=32（文件
    // 占用），非测试失败——OS 会回收，吞掉不让它污染结果（Linux 下 unlink 恒成功）。
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> seedEpisode(
    String uid,
    String title, {
    String? coverPath,
    DateTime? completedAt,
    int lastPositionMs = 0,
  }) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(uid),
      title: Value(title),
      videoPath: Value('/abs/$uid.mp4'),
      coverPath: Value(coverPath),
      completedAt: Value(completedAt),
      lastPositionMs: Value(lastPositionMs),
      importedAt: Value(DateTime(2026, 1, 1)),
    ));
  }

  Future<int> seedCollection(List<String> uids, {String name = '某番剧'}) async {
    final int cid = await db.createMediaCollection(
      name,
      collectionType: 'playlist',
    );
    for (final String uid in uids) {
      await db.addToCollection(cid, 'video', uid);
    }
    return cid;
  }

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: HomeVideoPage(repo: VideoBookRepository(db))),
          ),
        ),
      );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    // 页面 initState 里 `VideoStorage.coversDir().then(setState)` 是真实 IO 期约，
    // fake-async 的 pump 不会推进它 → `_coversDirCache` 保持 null（合集级海报路径判
    // 定失效）。用 runAsync 冲刷真实事件循环让该期约完成，再 settle 消化 setState。
    await tester.runAsync(() async {
      await VideoStorage.coversDir();
    });
    await tester.pumpAndSettle();
  }

  Finder cardFinder(int cid) =>
      find.byKey(ValueKey<String>('home_video_collection_card_$cid'));

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
    expect(images, findsOneWidget, reason: '合集卡必须渲染成员封面');
    final Image image = tester.widget<Image>(images);
    final ImageProvider provider = image.image;
    final FileImage fileImage = (provider is ResizeImage
        ? provider.imageProvider
        : provider) as FileImage;
    expect(fileImage.file.path, cover.path, reason: '封面必须借用组内首个有封面的本地成员（ep2）');
    // 有封面时不显示占位图标。
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.byIcon(Icons.movie_outlined),
      ),
      findsNothing,
    );
  });

  testWidgets('无封面 → 占位图标；集数角标 = 全部成员数；默认进度「已看完 0/N」',
      (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);

    expect(cardFinder(cid), findsOneWidget);
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.byIcon(Icons.movie_outlined),
      ),
      findsOneWidget,
      reason: '全员无封面 → 占位（与散卡同款 movie 图标）',
    );
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.text(t.video_playlist_episodes(count: 2)),
      ),
      findsOneWidget,
      reason: '集数角标 = 全部成员数',
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

  testWidgets('进度行：有痕迹未看完 → 「继续看 第n集」；全看完 → 「已看完 N/N」',
      (WidgetTester tester) async {
    // ep1 已看完 → 继续看候选 = 第2集。
    await seedEpisode('video/ep1', '第1集', completedAt: DateTime(2026, 1, 2));
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);
    expect(
      find.descendant(
        of: cardFinder(cid),
        matching: find.text(t.collection_continue_progress(n: 2)),
      ),
      findsOneWidget,
      reason: 'ep1 看完 → 继续看候选落在第2集（continueMemberIndex 同源）',
    );

    // 全部看完 → 「已看完 2/2」。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/ep2'),
      title: const Value('第2集'),
      videoPath: const Value('/abs/video/ep2.mp4'),
      completedAt: Value(DateTime(2026, 1, 3)),
      importedAt: Value(DateTime(2026, 1, 1)),
    ));
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

  testWidgets('点击合集卡 → 打开合集详情页（原「查看全部」行为）', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);
    await tester.tap(cardFinder(cid));
    await tester.pumpAndSettle();

    expect(find.byType(MediaCollectionDetailPage), findsOneWidget,
        reason: '整卡即详情入口（点某集从详情页进播放器带连播上下文）');
  });

  testWidgets('拖标签到合集卡 → 给整个合集打标签（真写穿 DB）', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);
    final int tagId = await db.createTag('Anime', 0xFF2196F3);

    await pumpPage(tester);

    final Finder tagChip = find
        .descendant(
          of: find.byType(HibikiTagFilterBar),
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
    expect(tags.map((BookTagRow t) => t.id), contains(tagId),
        reason: '拖标签到封面卡必须写穿合集标签（原横排行行头能力保留）');
  });

  // ── 合集卡长按/右键菜单（自定义封面入口，用户真机反馈「自定义封面这个按钮好像没加」）──

  /// 在 [WidgetTester.runAsync] 里点菜单项并等其触发的真实文件 IO 完成。菜单动作
  /// （_pickCollectionCover / _restoreCollectionCover）是 fire-and-forget 的 async：
  /// onPressed 必须在 runAsync 的真实 zone 里同步发起，其 File / 平台通道期约才会在
  /// 真实事件循环上跑完（fake-async 的 pump 不推进真实 IO）。
  Future<void> tapMenuActionAndSettleIo(
    WidgetTester tester,
    Finder action,
    bool Function() done,
  ) async {
    await tester.runAsync(() async {
      await tester.tap(action);
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!done() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('长按合集卡弹菜单：含查看详情/自定义封面/在线匹配海报；无海报时不出恢复默认封面',
      (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    await seedEpisode('video/ep2', '第2集');
    final int cid = await seedCollection(<String>['video/ep1', 'video/ep2']);

    await pumpPage(tester);
    await tester.longPress(cardFinder(cid));
    await tester.pumpAndSettle();

    expect(find.byType(MediaItemDialogFrame), findsOneWidget,
        reason: '长按合集卡应弹封面背景动作面板');
    expect(find.text(t.collection_view_all), findsOneWidget,
        reason: '第一项「查看详情」等价 onTap');
    expect(find.text(t.srt_import_pick_cover), findsOneWidget,
        reason: '「自定义封面」入口（复用选择封面文案）');
    expect(find.text(t.video_scrape_online_match), findsOneWidget,
        reason: '有本地成员 → 「在线匹配海报」可用');
    expect(find.text(t.video_collection_restore_cover), findsNothing,
        reason: '无合集级海报文件 → 不显示「恢复默认封面」');
  });

  testWidgets('多选态长按合集卡不弹菜单（onLongPress 置 null）', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    final int cid = await seedCollection(<String>['video/ep1']);

    await pumpPage(tester);

    // 进入多选态：标签栏旁「批量选择」按钮。
    final Finder selectBtn = find.descendant(
      of: find.byType(HibikiTagFilterBar),
      matching: find.byIcon(Icons.checklist_outlined),
    );
    await tester.tap(selectBtn);
    await tester.pumpAndSettle();

    await tester.longPress(cardFinder(cid));
    await tester.pumpAndSettle();

    expect(find.byType(MediaItemDialogFrame), findsNothing,
        reason: '多选态长按整卡 = 整选合集，不弹管理菜单');
    expect(find.text(t.srt_import_pick_cover), findsNothing);
  });

  testWidgets('恢复默认封面项仅在海报存在时出现，点击删海报文件 + 元数据', (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    final int cid = await seedCollection(<String>['video/ep1']);

    // 预置合集级海报 + manual 元数据（模拟「自定义封面」已设过）；真实 File IO 走
    // runAsync 冲刷落盘。
    late final CollectionPosterStore posterStore;
    late final CoverMetaStore metaStore;
    await tester.runAsync(() async {
      final Directory covers = await VideoStorage.coversDir();
      posterStore = CollectionPosterStore(covers);
      metaStore = CoverMetaStore(covers);
      await posterStore.savePoster(collectionId: cid, bytes: onePixelPng);
      await metaStore.set(
        CollectionPosterStore.metaKey(cid),
        const CoverMeta(origin: CoverOrigin.manual),
      );
    });
    expect(posterStore.fileFor(cid).existsSync(), isTrue);

    await pumpPage(tester);
    await tester.longPress(cardFinder(cid));
    await tester.pumpAndSettle();

    expect(find.text(t.video_collection_restore_cover), findsOneWidget,
        reason: '有合集级海报文件 → 显示「恢复默认封面」');

    await tapMenuActionAndSettleIo(
      tester,
      find.text(t.video_collection_restore_cover),
      () => !posterStore.fileFor(cid).existsSync(),
    );

    // 恢复后卡片重建切回成员封面借用；被删合集海报的**在途** FileImage 解码会抛
    // PathNotFound（真机上等价于封面无缝回退，无害）。清图片缓存释放文件句柄 +
    // 冲刷真实事件循环让该在途解码错误浮出，再统一吞掉，否则 flutter_test 计为失败。
    await tester.runAsync(() async {
      imageCache.clear();
      imageCache.clearLiveImages();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    for (Object? e = tester.takeException();
        e != null;
        e = tester.takeException()) {
      expect(e, isA<Exception>());
    }

    expect(posterStore.fileFor(cid).existsSync(), isFalse,
        reason: '「恢复默认封面」删合集级海报文件');
    // 用**新** CoverMetaStore 读盘（老实例内存缓存里还留着预置时的 manual，会掩盖
    // _restoreCollectionCover 对文件的删除——那是它自己的独立实例改的盘）。
    CoverMeta? meta;
    await tester.runAsync(() async {
      meta = await CoverMetaStore(metaStore.directory)
          .get(CollectionPosterStore.metaKey(cid));
    });
    expect(meta, isNull, reason: '同时清来源元数据（回退成员封面借用）');
  });

  testWidgets('自定义封面成功路径：选图 → 落合集级海报 + 标 manual（FilePicker 桩）',
      (WidgetTester tester) async {
    await seedEpisode('video/ep1', '第1集');
    final int cid = await seedCollection(<String>['video/ep1']);

    // 源图片文件（_pickCollectionCover 从选中路径 readAsBytes，不依赖 result.bytes）。
    final File src = File('${storeDir.path}/picked.png')
      ..writeAsBytesSync(onePixelPng);
    // file_picker 8.x 的 `_instance` 是 late 字段（无插件注册时读 `.platform` 会
    // LateInitializationError），故不读旧值、直接注入桩；本文件仅此用例用到 picker，
    // 无需还原（各 test file 独立 isolate，不跨文件泄漏）。
    FilePicker.platform = _StubFilePicker(
      FilePickerResult(<PlatformFile>[
        PlatformFile(
          path: src.path,
          name: 'picked.png',
          size: onePixelPng.length,
        ),
      ]),
    );

    late final CollectionPosterStore posterStore;
    late final CoverMetaStore metaStore;
    await tester.runAsync(() async {
      final Directory covers = await VideoStorage.coversDir();
      posterStore = CollectionPosterStore(covers);
      metaStore = CoverMetaStore(covers);
    });
    expect(posterStore.fileFor(cid).existsSync(), isFalse);

    await pumpPage(tester);
    await tester.longPress(cardFinder(cid));
    await tester.pumpAndSettle();

    await tapMenuActionAndSettleIo(
      tester,
      find.text(t.srt_import_pick_cover),
      () => posterStore.fileFor(cid).existsSync(),
    );

    expect(posterStore.fileFor(cid).existsSync(), isTrue,
        reason: '「自定义封面」把选中图片落合集级海报');
    CoverMeta? meta;
    await tester.runAsync(() async {
      meta = await metaStore.get(CollectionPosterStore.metaKey(cid));
    });
    expect(meta, isNotNull);
    expect(meta!.origin, CoverOrigin.manual, reason: '手动封面标 manual → 批量刮削永不覆盖');
  });
}
