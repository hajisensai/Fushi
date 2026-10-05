import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi_engine/media/video/video_storage.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show videoRemotePositionAtPrefKey;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 永不被真调用的刮削 runner：菜单测试只需要一个在场的 controller 来点亮入口。
class _IdleScrapeRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async =>
      SourceScrapeReport(sourceIds: <int>[source.id]);
}

/// 支持手动候选搜索的 runner（BUG-2955 在线搜索封面）：只记录搜了什么。
class _CoverSearchScrapeRunner extends _IdleScrapeRunner
    implements VideoSourceScrapeManualBinding {
  final List<String> queries = <String>[];

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) async {
    queries.add(query);
    return const <VideoSourceScrapeConfirmationCandidate>[];
  }

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(
          VideoMetadataLookup lookup) async =>
      null;

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) =>
      throw UnimplementedError();
}

class PausingBatchDeleteVideoBookRepository extends VideoBookRepository {
  PausingBatchDeleteVideoBookRepository(
    super.db, {
    required this.pauseAfterDeleteCount,
  });

  final int pauseAfterDeleteCount;
  final Completer<void> deletesCommitted = Completer<void>();
  final Completer<void> allowDeleteReturn = Completer<void>();
  int deleteCalls = 0;
  int compactCalls = 0;

  // BUG-2754 起批量删除一个事务落库（单条删也委托到这里），按真删掉的行计数。
  @override
  Future<List<VideoBookRow>> deleteVideoBooks(
    Iterable<String> bookUids, {
    DeleteScope scope = DeleteScope.keepLocalOnly,
  }) async {
    final List<VideoBookRow> deleted =
        await super.deleteVideoBooks(bookUids, scope: scope);
    deleteCalls += deleted.length;
    if (deleteCalls >= pauseAfterDeleteCount && !deletesCommitted.isCompleted) {
      deletesCommitted.complete();
      await allowDeleteReturn.future;
    }
    return deleted;
  }

  @override
  Future<void> compactAfterVideoDeleteBestEffort() async {
    compactCalls++;
    await super.compactAfterVideoDeleteBestEffort();
  }
}

/// HomeVideoPage 行为测试：验证「视频长按弹菜单」与「视频卡渲染共享标签」真生效
/// （而非只看源码）。AppModel 用 [AppModel.wireDatabaseForTesting] /
/// [AppModel.wireLocalAudioForTesting] 注入内存库，跳过完整 initialise。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_home_video_pp');
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
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory externalVideoDir;
  late Directory storeDir;
  late GlobalKey<NavigatorState> toastNavigatorKey;

  setUp(() async {
    // 视频删除与封面回填共用 VideoCoverMutationGate（进程级锁）。带真实资产的用例
    // 会真跑一次抽帧，用例结束时那个 action 若还在飞，它的 Zone 不再推进、锁永不
    // 释放；下一条用例于是排进一条永不被移交的队列——删除静默不执行，断言只会说
    // 「没删掉」，看不出因果。逐条清锁（与下面 resetAppOwnedVideoAssetDirs 同性质）。
    VideoCoverMutationGate.debugResetForTesting();
    // TODO-935 E1：桌面测试宿主 isDesktopPlatform=true，AppPaths._resolveDataRoot
    // 会读 SharedPreferences 的 data_root。未 mock 时 getInstance() 在本绑定下挂起，
    // 连累经 VideoStorage→AppPaths 的资产回收（封面/字幕目录解析永不返回 → 回收
    // 不完整，断言计数偏少）。给空初值让其即时回退默认根（mock 的 path_provider）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_home_video_store');
    externalVideoDir =
        Directory.systemTemp.createTempSync('hibiki_home_video_external');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    toastNavigatorKey = GlobalKey<NavigatorState>();
  });

  tearDown(() async {
    await db.close();
    if (externalVideoDir.existsSync()) {
      externalVideoDir.deleteSync(recursive: true);
    }
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  void resetAppOwnedVideoAssetDirs() {
    for (final String name in <String>[
      VideoStorage.coversDirName,
      VideoStorage.subtitlesDirName,
    ]) {
      final Directory dir = Directory(p.join(pathProviderDir.path, name));
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      dir.createSync(recursive: true);
    }
  }

  File writeAppOwnedAsset({
    required String dirName,
    required String fileName,
    List<int>? bytes,
    String? text,
  }) {
    final File file = File(p.join(pathProviderDir.path, dirName, fileName));
    file.parent.createSync(recursive: true);
    if (bytes != null) {
      file.writeAsBytesSync(bytes);
    } else {
      file.writeAsStringSync(text ?? 'asset');
    }
    return file;
  }

  File writeOriginalVideo(String fileName) {
    final File file = File(p.join(externalVideoDir.path, fileName));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(<int>[0, 1, 2, 3, 4, 5]);
    return file;
  }

  Directory writeEmbeddedSubtitleCache(File video) {
    final Directory dir = embeddedSubtitleCacheDir(video.path);
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'sub_0.srt'))
        .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello');
    return dir;
  }

  Future<({File cover, Directory embeddedCache, File subtitle, File video})>
      seedVideoWithAssets({
    required String bookUid,
    required String title,
    required File cover,
    required File subtitle,
    String? videoFileName,
  }) async {
    final File video = writeOriginalVideo(
      videoFileName ?? '${bookUid.replaceAll('/', '_')}.mp4',
    );
    final Directory embeddedCache = writeEmbeddedSubtitleCache(video);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(video.path),
      coverPath: Value(cover.path),
      subtitleSource: Value(subtitle.path),
    ));
    return (
      cover: cover,
      embeddedCache: embeddedCache,
      subtitle: subtitle,
      video: video,
    );
  }

  Future<void> waitForAsyncCleanup(
    WidgetTester tester,
    bool Function() isDone,
  ) async {
    // TODO-1383：轮询「页面卸载后的异步资产回收（跨临时目录删若干文件）」完成。原 2s
    // 上界在并发全量 flutter test（8 个 isolate 抢盘 IO + CPU 时间片）下不够——回收本身
    // 会完成，只是拿不到足够 wall-clock 片，2s 内没删完 → 后续 existsSync 断言误红。放宽
    // 到 30s 纯属等待上界（isDone 一真即刻退出，通过路径零变慢），不弱化任何断言；若回收
    // 真的永不完成（真 bug）仍会在更宽上界后照样失败。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!isDone() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    await tester.pumpAndSettle();
  }

  Future<void> seedTaggedVideo() async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('My Episode'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    final int tagId = await db.createTag('Anime', 0xFF2196F3);
    await db.addTagToVideoBook('video/1', tagId);
  }

  Future<int> seedVideoAndLooseTag() async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('My Episode'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    return db.createTag('Anime', 0xFF2196F3);
  }

  /// 定位某一行视频的库页卡片。
  ///
  /// 不能用 `find.byType(FushiCard).first`：页面正文之上还挂着若干横幅
  /// （`VideoOnlineServicesBanner` 的「配置可选在线服务」、待确认身份提醒条…），
  /// 它们同样是 [FushiCard]、且排在墙卡之前，`.first` 会落到一张没有任何手势
  /// 回调的横幅上——长按/右键于是什么都不弹，断言只会说「面板没出现」，看不出
  /// 是找错了卡。卡片 key 是 `home_video_<bookUid>`（`_buildVideoCard`），按它
  /// 定位与横幅数量无关。
  Finder videoCard(String bookUid) =>
      find.byKey(ValueKey<String>('home_video_$bookUid'));

  Widget buildApp({
    bool captureToasts = false,
    VideoBookRepository? repo,
    VideoSourceScrapeTaskController? scrapeTaskController,
  }) =>
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
          // 墙卡清晰度角标的规格服务不会真起 ffprobe：套件级默认探测器已在
          // test/flutter_test_config.dart 换成不起进程的假探测器
          // （helpers/fake_video_specs_probe.dart）。
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: captureToasts ? toastNavigatorKey : null,
            // HomeVideoPage 不再自带 Scaffold（与书架/词典 tab 统一，运行时挂在
            // HomePage 的外层 Scaffold 内）；测试照样在 Scaffold 内 pump，
            // FushiPageHeader 的 FushiIconButton(InkWell) 才有 Material 祖先。
            // #792 分区化后 home 分区只渲染 dashboard 概览；标签栏/选择入口与
            // 全量墙卡（tap 直接 _open 开播）都在 allVideos 分区，钉住该分区。
            home: Scaffold(
              body: HomeVideoPage(
                repo: repo ?? VideoBookRepository(db),
                section: VideoLibrarySection.allVideos,
                scrapeTaskController: scrapeTaskController,
              ),
            ),
          ),
        ),
      );

  Future<void> dragTopTagToVideoCard(WidgetTester tester) async {
    final Finder tagChip = find
        .descendant(
          of: find.byType(FushiTagFilterBar),
          matching: find.widgetWithText(FushiTagChip, 'Anime'),
        )
        .first;
    final Finder card =
        find.byKey(const ValueKey<String>('home_video_video/1'));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(tagChip),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(card));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('视频卡渲染所挂的共享标签 chip', (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('My Episode'), findsOneWidget);
    // 标签来自共享 BookTags 池，经 video_book_tag_mappings 映射。
    // 卡片与顶部筛选条现都用同款共享 FushiTagChip，故按卡片范围定位避免与
    // 筛选条里的同名标签冲突。
    expect(
      find.descendant(
        of: videoCard('video/1'),
        matching: find.widgetWithText(FushiTagChip, 'Anime'),
      ),
      findsOneWidget,
    );
  });

  /// 打开某张卡的动作面板。触屏和桌面长按都走同一条管理菜单链路。
  Future<void> openCardMenu(WidgetTester tester, Finder card) async {
    await tester.longPress(card);
    await tester.pumpAndSettle();
  }

  testWidgets('触屏未进选择态长按视频卡弹管理菜单，不进入多选', (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await openCardMenu(tester, videoCard('video/1'));

    expect(find.text(t.batch_selected_count(n: 1)), findsNothing,
        reason: '触屏必须先点明确的「选择」入口，长按不能暗中进入多选');
    expect(find.byType(FushiDialogFrame), findsOneWidget);
    expect(find.text(t.tag_label), findsOneWidget);
    expect(find.text(t.video_rename), findsOneWidget);
    expect(find.text(t.srt_import_pick_cover), findsOneWidget);
    expect(find.text(t.video_import_pick_subtitle), findsOneWidget);
    expect(find.text(t.video_scrape_info), findsNothing);
    expect(t.video_import_pick_subtitle, isNot(contains('srt')));
    expect(t.video_import_pick_subtitle, isNot(contains('vtt')));
    expect(t.video_import_pick_subtitle, isNot(contains('ass')));
    // 单卡「加入合集」（共享 showAddToCollectionDialog 入口）。
    expect(find.text(t.add_to_collection), findsOneWidget);
    expect(find.text(t.dialog_delete), findsOneWidget);
    expect(find.text(t.dialog_read), findsNothing);
  });

  testWidgets('桌面长按本地视频卡仍弹同一动作面板，不进入多选', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await seedTaggedVideo();
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await openCardMenu(tester, videoCard('video/1'));

      expect(find.text(t.batch_selected_count(n: 1)), findsNothing);
      expect(find.byType(FushiDialogFrame), findsOneWidget);
      expect(find.text(t.video_rename), findsOneWidget);
      expect(find.text(t.add_to_collection), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('桌面右键（次按钮）本地视频卡弹出同一动作面板（BUG-758）', (WidgetTester tester) async {
    // BUG-758：本地视频卡此前只挂 onLongPress、漏了 onSecondaryTap，桌面右键无反应
    // （书架书卡 / 远端视频卡都支持右键）。此处直接模拟次按钮点击，断言与长按同一面板。
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(videoCard('video/1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    // 右键与长按同链路（都走 _showVideoMenu）：应弹出同一封面背景动作面板。
    expect(find.byType(FushiDialogFrame), findsOneWidget);
    expect(find.text(t.tag_label), findsOneWidget);
    expect(find.text(t.video_rename), findsOneWidget);
    expect(find.text(t.srt_import_pick_cover), findsOneWidget);
    expect(find.text(t.video_import_pick_subtitle), findsOneWidget);
    expect(find.text(t.video_scrape_info), findsNothing);
    expect(find.text(t.add_to_collection), findsOneWidget);
    expect(find.text(t.dialog_delete), findsOneWidget);
  });

  testWidgets(
      'first video open prompts for Anime4K recommended shaders (desktop)',
      (WidgetTester tester) async {
    // TODO-874：首次提示只在桌面端弹（移动端着色器超分掉帧/发热，纯抑制）。
    // widget 测试默认平台是 android，需显式 override 到桌面端验证弹窗路径。
    // override 必须在测试体内 try/finally 复位（绑定的 invariant 检查在
    // tearDown 之前跑，用 addTearDown 复位会触发 foundation debug var 泄漏断言）。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await seedTaggedVideo();
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('My Episode'));
      await tester.pumpAndSettle();

      expect(find.text(t.video_shader_first_use_title), findsOneWidget);
      expect(find.text(t.video_shader_first_use_body), findsOneWidget);
      expect(
        await db.getPref(PreferencesRepository.videoAnime4kPromptShownKey),
        'b:true',
      );
      expect(appModel.prefsRepo.videoAnime4kPromptShown, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'TODO-874 mobile first video open suppresses Anime4K prompt (no side effect)',
      (WidgetTester tester) async {
    // 移动端首次打开视频不弹 Anime4K 提示，且不置 videoAnime4kPromptShown 标记
    // （零副作用，保证桌面端跨平台同步后仍能首次弹出）。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await seedTaggedVideo();
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('My Episode'));
      // 不能 pumpAndSettle：移动端 _open 不弹模态提示（desktop 用例靠 modal 暂停
      // _open 才停在对话框），android 路径会继续 Navigator.push 真正的视频播放页
      // （VideoFushiPage，media_kit 播放器在无头测试里永不 settle）。本用例只验
      // 「无提示 + 无副作用」，把同步的 _showAnime4kFirstUsePromptIfNeeded（android
      // 立即 early-return，无 async 对话框）跑完即可，用有界 pump 取代 pumpAndSettle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(t.video_shader_first_use_title), findsNothing);
      expect(find.text(t.video_shader_first_use_body), findsNothing);
      expect(
        await db.getPref(PreferencesRepository.videoAnime4kPromptShownKey),
        isNull,
      );
      expect(appModel.prefsRepo.videoAnime4kPromptShown, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('本地视频卡菜单含「打开文件位置」', (WidgetTester tester) async {
    // 书架书卡早有这条动作，视频卡没有（用户实报）。flutter_test 宿主恒为桌面
    // （Windows / Linux / macOS），[currentRevealHost] 必非 null，所以这里断言在场；
    // 移动端那道门由 media_open_file_location_gate_guard_test 在源码层守。
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await openCardMenu(tester, videoCard('video/1'));

    expect(find.text(t.media_file_location_open), findsOneWidget);
  });

  testWidgets('流媒体书卡菜单不出现「打开文件位置」', (WidgetTester tester) async {
    // videoPath 是 URL 的行（粘贴 URL 导入 / 远端库）本机根本没有文件可定位，
    // 画出来就是一个点了必然失败的按钮。这条用例是该门控的唯一行为级判据——
    // 上一条只能证明「桌面上会出现」，证明不了「没有本地文件时不出现」。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/stream'),
      title: Value('Stream Episode'),
      videoPath: Value('https://example.com/live/ep1.m3u8'),
    ));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await openCardMenu(tester, videoCard('video/stream'));

    expect(find.byType(FushiDialogFrame), findsOneWidget,
        reason: '菜单本身仍要弹出，缺的只是这一条动作');
    expect(find.text(t.media_file_location_open), findsNothing);
  });

  group('视频卡「重新刮削资料与封面」（BUG-2737）', () {
    late VideoSourceScrapeTaskController scrapeController;
    setUp(() {
      scrapeController = VideoSourceScrapeTaskController(_IdleScrapeRunner());
    });
    tearDown(() => scrapeController.dispose());

    /// 一条视频来源（根目录就是 [externalVideoDir]），返回来源 id。
    Future<int> seedVideoSource({
      String transport = 'local',
      String groupingMode = 'series',
    }) =>
        db.insertMediaSource(MediaSourcesCompanion.insert(
          label: 'Local videos',
          mediaKind: 'video',
          rootPath: externalVideoDir.path,
          createdAt: 1,
          transport: Value(transport),
          videoGroupingMode: Value(groupingMode),
        ));

    /// 挂在 [sourceId] 下、磁盘上真有文件的视频行。
    Future<void> seedSourcedVideo(
      String bookUid, {
      required int sourceId,
      String fileName = 'Liz (2018).mp4',
    }) async {
      final File video = writeOriginalVideo(fileName);
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(bookUid),
        title: const Value('Liz'),
        videoPath: Value(video.path),
        sourceId: Value<int?>(sourceId),
      ));
    }

    testWidgets('本机来源里的视频卡菜单出现重刮入口（列表行，与合集菜单同文案）', (WidgetTester tester) async {
      // 用户实报：刮错封面的独立电影长按后没有任何重刮入口，合集菜单那条够不着。
      await seedSourcedVideo('video/liz', sourceId: await seedVideoSource());
      await tester.pumpWidget(buildApp(scrapeTaskController: scrapeController));
      await tester.pumpAndSettle();

      await openCardMenu(tester, videoCard('video/liz'));

      // MD3 管理菜单的列表行现在是分段行（_Md3SegmentRow，取代 FushiListItem）；
      // 快捷动作是 _QuickActionButton。两者都是私有类，按类型名区分。
      Finder ancestorNamed(String typeName) => find.ancestor(
            of: find.text(t.collection_rescrape),
            matching: find.byWidgetPredicate(
              (Widget w) => w.runtimeType.toString() == typeName,
            ),
          );
      expect(
        ancestorNamed('_Md3SegmentRow'),
        findsOneWidget,
        reason: '做成列表行而不是快捷 chip：最长的标签不该压少整格 chip 的列数',
      );
      expect(ancestorNamed('_QuickActionButton'), findsNothing);
    });

    testWidgets('没有刮削 controller 时不画重刮入口', (WidgetTester tester) async {
      await seedSourcedVideo('video/liz', sourceId: await seedVideoSource());
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await openCardMenu(tester, videoCard('video/liz'));

      expect(find.byType(FushiDialogFrame), findsOneWidget);
      expect(find.text(t.collection_rescrape), findsNothing);
    });

    // 入口判据与 planScrapeWorkForVideoBook 同口径（videoBookHasScrapePlan）：
    // 这些视频在计划器里拿不到作品单元，画出来点了必然只剩「不在计划里」。
    final Map<String, Future<String> Function()> unplannable =
        <String, Future<String> Function()>{
      '手动导入（没有 sourceId）': () async {
        await seedTaggedVideo();
        return 'video/1';
      },
      '流媒体（URL，无来源）': () async {
        await db.upsertVideoBook(const VideoBooksCompanion(
          bookUid: Value('video/stream'),
          title: Value('Stream Episode'),
          videoPath: Value('https://example.com/live/ep1.m3u8'),
        ));
        return 'video/stream';
      },
      '目录分组模式的来源': () async {
        await seedSourcedVideo('video/folder',
            sourceId: await seedVideoSource(groupingMode: 'folder'));
        return 'video/folder';
      },
      '非本机来源（sftp）': () async {
        await seedSourcedVideo('video/sftp',
            sourceId: await seedVideoSource(transport: 'sftp'));
        return 'video/sftp';
      },
      '特典文件（NCOP）': () async {
        await seedSourcedVideo('video/ncop',
            sourceId: await seedVideoSource(), fileName: 'Liz NCOP.mp4');
        return 'video/ncop';
      },
    };
    unplannable.forEach((String label, Future<String> Function() seed) {
      testWidgets('不在刮削计划里的视频不画重刮入口：$label', (WidgetTester tester) async {
        final String bookUid = await seed();
        await tester
            .pumpWidget(buildApp(scrapeTaskController: scrapeController));
        await tester.pumpAndSettle();

        await openCardMenu(tester, videoCard(bookUid));

        expect(find.byType(FushiDialogFrame), findsOneWidget,
            reason: '菜单本身仍要弹出，缺的只是这一条动作');
        expect(find.text(t.collection_rescrape), findsNothing);
      });
    });

    testWidgets('菜单打开后来源被删：点重刮给可见提示，不静默', (WidgetTester tester) async {
      // 入口已与计划器同口径，「不在计划里」只剩竞态：菜单画出来之后来源被删
      // （FK setNull 把视频的 sourceId 清掉），点下去计划器已经给不出单元。
      final int sourceId = await seedVideoSource();
      await seedSourcedVideo('video/liz', sourceId: sourceId);
      FushiToast.navigatorKey = toastNavigatorKey;
      await tester.pumpWidget(buildApp(
        captureToasts: true,
        scrapeTaskController: scrapeController,
      ));
      await tester.pumpAndSettle();

      await openCardMenu(tester, videoCard('video/liz'));
      final Finder entry = find.text(t.collection_rescrape);
      expect(entry, findsOneWidget);
      await db.deleteMediaSource(sourceId);
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.text(t.video_item_rescrape_not_planned), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  // BUG-2955：设置封面曾经只剩「选择封面图片」（本地文件）。在线入口与「手动指定
  // 作品」共用同一条候选搜索，所以只有 controller 支持手动搜索时才画。
  group('视频卡「在线搜索封面」（BUG-2955）', () {
    testWidgets('支持手动搜索的 controller 下菜单有在线入口，点开按视频标题搜索',
        (WidgetTester tester) async {
      await seedTaggedVideo();
      final _CoverSearchScrapeRunner runner = _CoverSearchScrapeRunner();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(runner);
      addTearDown(controller.dispose);
      await tester.pumpWidget(buildApp(scrapeTaskController: controller));
      await tester.pumpAndSettle();

      await openCardMenu(tester, videoCard('video/1'));
      expect(find.text(t.srt_import_pick_cover), findsOneWidget,
          reason: '本地选图入口照旧在场');
      expect(find.text(t.video_cover_online_search), findsOneWidget,
          reason: '设置封面不能只剩本地文件');

      await tester.tap(find.text(t.video_cover_online_search));
      await tester.pumpAndSettle();
      expect(find.text(t.video_cover_online_search), findsOneWidget,
          reason: '弹出的是在线搜封面的候选搜索框（标题用封面文案，不是「手动指定作品」）');
      expect(find.text(t.video_cover_online_hint), findsOneWidget);

      await tester.tap(
          find.byKey(const ValueKey<String>('video-source-manual-search')));
      await tester.pumpAndSettle();
      expect(runner.queries, <String>['My Episode'],
          reason: '以视频标题作初始搜索词，打到资料源的候选搜索');
    });

    testWidgets('controller 不支持手动搜索时不画在线入口', (WidgetTester tester) async {
      await seedTaggedVideo();
      final VideoSourceScrapeTaskController controller =
          VideoSourceScrapeTaskController(_IdleScrapeRunner());
      addTearDown(controller.dispose);
      await tester.pumpWidget(buildApp(scrapeTaskController: controller));
      await tester.pumpAndSettle();

      await openCardMenu(tester, videoCard('video/1'));
      expect(find.text(t.srt_import_pick_cover), findsOneWidget);
      expect(find.text(t.video_cover_online_search), findsNothing);
    });
  });

  testWidgets('从未看过的视频卡菜单不出现「清除观看进度」', (WidgetTester tester) async {
    // 无痕迹的集画这个按钮只是一个什么都不会发生的钮；门控口径与合集续播的
    // 痕迹判据同源（videoBookHasWatchTrace）。
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await openCardMenu(tester, videoCard('video/1'));

    expect(find.byType(FushiDialogFrame), findsOneWidget);
    expect(find.text(t.video_watch_progress_clear), findsNothing);
  });

  testWidgets('有观看痕迹的视频卡菜单「清除观看进度」真清行并盖同步戳', (WidgetTester tester) async {
    // 用户实报：误点开下一集看了两秒退出，「继续看」被钉在那一集。菜单这条动作
    // 要把位置 / 时刻 / 完成标记一起清掉（只清位置锚点照样钉着）。
    // 这条动作排在菜单最末（DELETE 之前），默认 800×600 测试面上落在屏外，tap
    // 命不中；放大测试面让整张面板可见。
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seedTaggedVideo();
    await db.updateVideoBookPosition('video/1', 2000, playedAt: 5000);
    await db.markVideoCompleted('video/1', DateTime(2026, 1, 1));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await openCardMenu(tester, videoCard('video/1'));
    expect(find.text(t.video_watch_progress_clear), findsOneWidget);

    await tester.tap(find.text(t.video_watch_progress_clear));
    await tester.pumpAndSettle();
    // 先过确认框（学习记录两条勾选默认都不勾 = 统计不动）。
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();

    final VideoBookRow row = (await db.getVideoBookByBookUid('video/1'))!;
    expect(row.lastPositionMs, 0);
    expect(row.lastPlayedAt, isNull);
    expect(row.completedAt, isNull);
    expect(
      await db.getPrefTyped<int>(videoRemotePositionAtPrefKey('video/1'), 0),
      greaterThan(5000),
      reason: '互联 LWW 镜像戳要盖成现在，否则下次同步 host 把旧进度灌回来',
    );
  });

  testWidgets('顶部标签可拖到视频卡并写入视频标签映射', (WidgetTester tester) async {
    final int tagId = await seedVideoAndLooseTag();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(await db.getTagsForVideoBook('video/1'), isEmpty);

    await dragTopTagToVideoCard(tester);

    final List<BookTagRow> tags = await db.getTagsForVideoBook('video/1');
    expect(tags.map((BookTagRow tag) => tag.id), contains(tagId));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home_video_video/1')),
        matching: find.widgetWithText(FushiTagChip, 'Anime'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('顶部标签拖到视频卡成功提示使用视频文案', (WidgetTester tester) async {
    await seedVideoAndLooseTag();
    FushiToast.navigatorKey = toastNavigatorKey;
    await tester.pumpWidget(buildApp(captureToasts: true));
    await tester.pumpAndSettle();

    await dragTopTagToVideoCard(tester);

    expect(find.text('标签「Anime」已添加到视频。'), findsOneWidget);
    expect(find.text('标签「Anime」已添加到书籍。'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('重复拖同一标签到视频卡保持幂等，不新增重复映射', (WidgetTester tester) async {
    await seedVideoAndLooseTag();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await dragTopTagToVideoCard(tester);
    await dragTopTagToVideoCard(tester);

    final List<TagAssignmentRow> mappings = await db.getAllTagAssignments();
    expect(mappings, hasLength(1));
    expect(mappings.single.entryKey, 'video/1');
  });

  // ── TODO-063 视频批量选择（标签栏旁的「选择」+ 批量打标签/删除）──────────

  /// 点标签栏旁的「批量选择」按钮进入选择态。该按钮是 [FushiTagFilterBar] 末尾的
  /// checklist 图标按钮（tooltip = batch_select）。
  Future<void> enterSelectionMode(WidgetTester tester) async {
    final Finder selectBtn = find.descendant(
      of: find.byType(FushiTagFilterBar),
      matching: find.byIcon(Icons.checklist_outlined),
    );
    expect(selectBtn, findsOneWidget, reason: '视频标签栏旁应有「批量选择」按钮（用户报的「视频少了选择」）');
    await tester.tap(selectBtn);
    await tester.pumpAndSettle();
  }

  testWidgets('标签栏旁的「选择」按钮存在，进入选择态后出现批量操作栏', (WidgetTester tester) async {
    await seedTaggedVideo();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 进入前没有批量操作栏（按计数文案判定）。
    expect(find.text(t.batch_selected_count(n: 0)), findsNothing);

    await enterSelectionMode(tester);

    // 进入后底部批量操作栏出现（0 选中）。
    expect(find.text(t.batch_selected_count(n: 0)), findsOneWidget);
    expect(find.text(t.batch_select_all), findsOneWidget);
    expect(find.text(t.batch_invert_selection), findsOneWidget);
  });

  testWidgets('选择态点视频卡勾选 → 批量删除真删视频书', (WidgetTester tester) async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('Episode One'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/2'),
      title: Value('Episode Two'),
      videoPath: Value('/abs/ep2.mp4'),
    ));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect((await VideoBookRepository(db).listAll()).length, 2);

    await enterSelectionMode(tester);

    // 选择态下点卡片切换勾选（不再打开播放页）。
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);

    // 点批量删除（垃圾桶）→ 确认对话框 → 删除。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    // 确认对话框的「删除」按钮（AlertDialog 内）。
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();

    final List<VideoBookRow> remaining =
        await VideoBookRepository(db).listAll();
    expect(remaining.map((VideoBookRow b) => b.bookUid), <String>['video/2'],
        reason: 'video/1 被批量删除，video/2 保留');
  });

  testWidgets('卡片菜单单删会回收本视频 app-owned 封面字幕与内嵌字幕缓存',
      (WidgetTester tester) async {
    resetAppOwnedVideoAssetDirs();
    final deleted = await seedVideoWithAssets(
      bookUid: 'video/1',
      title: 'Episode One',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_1.png',
        bytes: _kOnePixelPng,
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_1.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\none',
      ),
    );
    final kept = await seedVideoWithAssets(
      bookUid: 'video/2',
      title: 'Episode Two',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_2.png',
        bytes: _kOnePixelPng,
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_2.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\ntwo',
      ),
    );

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await openCardMenu(
        tester, find.byKey(const ValueKey<String>('home_video_video/1')));
    // 管理菜单在 800x600 默认视口里可滚动，危险区的「删除」落在折线下，先滚到可见。
    await tester.ensureVisible(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();
    await waitForAsyncCleanup(
      tester,
      () =>
          !deleted.cover.existsSync() &&
          !deleted.subtitle.existsSync() &&
          !deleted.embeddedCache.existsSync(),
    );

    expect(await db.getVideoBookByBookUid('video/1'), isNull);
    expect(await db.getVideoBookByBookUid('video/2'), isNotNull);
    expect(deleted.cover.existsSync(), isFalse);
    expect(deleted.subtitle.existsSync(), isFalse);
    expect(deleted.embeddedCache.existsSync(), isFalse);
    expect(deleted.video.existsSync(), isTrue,
        reason: '删除视频书不得删除用户原始 videoPath');
    expect(kept.cover.existsSync(), isTrue);
    expect(kept.subtitle.existsSync(), isTrue);
    expect(kept.embeddedCache.existsSync(), isTrue);
    expect(kept.video.existsSync(), isTrue);
  });

  testWidgets('批量删除只回收选中视频资产且保留其他视频仍引用的字幕', (WidgetTester tester) async {
    resetAppOwnedVideoAssetDirs();
    final File sharedSubtitle = writeAppOwnedAsset(
      dirName: VideoStorage.subtitlesDirName,
      fileName: 'shared.srt',
      text: '1\n00:00:00,000 --> 00:00:01,000\nshared',
    );
    final selectedOne = await seedVideoWithAssets(
      bookUid: 'video/1',
      title: 'Episode One',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_1.png',
        bytes: _kOnePixelPng,
      ),
      subtitle: sharedSubtitle,
    );
    final selectedTwo = await seedVideoWithAssets(
      bookUid: 'video/2',
      title: 'Episode Two',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_2.png',
        bytes: _kOnePixelPng,
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_2.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\ntwo',
      ),
    );
    final kept = await seedVideoWithAssets(
      bookUid: 'video/3',
      title: 'Episode Three',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_3.png',
        bytes: _kOnePixelPng,
      ),
      subtitle: sharedSubtitle,
    );

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await enterSelectionMode(tester);
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pumpAndSettle();
    await waitForAsyncCleanup(
      tester,
      () =>
          !selectedOne.cover.existsSync() &&
          !selectedTwo.cover.existsSync() &&
          !selectedTwo.subtitle.existsSync() &&
          !selectedOne.embeddedCache.existsSync() &&
          !selectedTwo.embeddedCache.existsSync(),
    );

    expect(await db.getVideoBookByBookUid('video/1'), isNull);
    expect(await db.getVideoBookByBookUid('video/2'), isNull);
    expect(await db.getVideoBookByBookUid('video/3'), isNotNull);
    expect(selectedOne.cover.existsSync(), isFalse);
    expect(selectedTwo.cover.existsSync(), isFalse);
    expect(selectedTwo.subtitle.existsSync(), isFalse);
    expect(selectedOne.embeddedCache.existsSync(), isFalse);
    expect(selectedTwo.embeddedCache.existsSync(), isFalse);
    expect(selectedOne.video.existsSync(), isTrue);
    expect(selectedTwo.video.existsSync(), isTrue);
    expect(sharedSubtitle.existsSync(), isTrue,
        reason: '其他视频仍引用的 app-owned 字幕不能被选中视频删除波及');
    expect(kept.cover.existsSync(), isTrue);
    expect(kept.embeddedCache.existsSync(), isTrue);
    expect(kept.video.existsSync(), isTrue);
  });

  testWidgets('批量删除 DB 后页面卸载仍会回收 app-owned 视频资产', (WidgetTester tester) async {
    resetAppOwnedVideoAssetDirs();
    final selectedOne = await seedVideoWithAssets(
      bookUid: 'video/1',
      title: 'Episode One',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_1.png',
        bytes: _kOnePixelPng,
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_1.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\none',
      ),
    );
    final selectedTwo = await seedVideoWithAssets(
      bookUid: 'video/2',
      title: 'Episode Two',
      cover: writeAppOwnedAsset(
        dirName: VideoStorage.coversDirName,
        fileName: 'video_2.png',
        bytes: _kOnePixelPng,
      ),
      subtitle: writeAppOwnedAsset(
        dirName: VideoStorage.subtitlesDirName,
        fileName: 'video_2.srt',
        text: '1\n00:00:00,000 --> 00:00:01,000\ntwo',
      ),
    );
    final PausingBatchDeleteVideoBookRepository repo =
        PausingBatchDeleteVideoBookRepository(db, pauseAfterDeleteCount: 2);

    await tester.pumpWidget(buildApp(repo: repo));
    await tester.pumpAndSettle();
    await enterSelectionMode(tester);
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete).last);
    await tester.pump();
    await tester.runAsync(() async {
      await repo.deletesCommitted.future.timeout(const Duration(seconds: 2));
    });
    expect(await db.getVideoBookByBookUid('video/1'), isNull);
    expect(await db.getVideoBookByBookUid('video/2'), isNull);
    expect(selectedOne.cover.existsSync(), isTrue);
    expect(selectedOne.subtitle.existsSync(), isTrue);
    expect(selectedOne.embeddedCache.existsSync(), isTrue);
    expect(selectedTwo.cover.existsSync(), isTrue);
    expect(selectedTwo.subtitle.existsSync(), isTrue);
    expect(selectedTwo.embeddedCache.existsSync(), isTrue);
    final VideoScrapeOperationLease? maintenance =
        VideoScrapeOperationGate.tryEnterMaintenance();
    maintenance?.release();
    expect(maintenance, isNull, reason: '删行后、卡片卸载与资产回收前 maintenance 不得入场');

    await tester.pumpWidget(const SizedBox.shrink());
    repo.allowDeleteReturn.complete();
    await waitForAsyncCleanup(
      tester,
      () =>
          !selectedOne.cover.existsSync() &&
          !selectedOne.subtitle.existsSync() &&
          !selectedOne.embeddedCache.existsSync() &&
          !selectedTwo.cover.existsSync() &&
          !selectedTwo.subtitle.existsSync() &&
          !selectedTwo.embeddedCache.existsSync(),
    );

    expect(repo.deleteCalls, 2);
    expect(repo.compactCalls, 1);
    expect(selectedOne.cover.existsSync(), isFalse);
    expect(selectedOne.subtitle.existsSync(), isFalse);
    expect(selectedOne.embeddedCache.existsSync(), isFalse);
    expect(selectedTwo.cover.existsSync(), isFalse);
    expect(selectedTwo.subtitle.existsSync(), isFalse);
    expect(selectedTwo.embeddedCache.existsSync(), isFalse);
    expect(selectedOne.video.existsSync(), isTrue);
    expect(selectedTwo.video.existsSync(), isTrue);
  });

  testWidgets('选择态批量打标签 → 真写视频标签映射', (WidgetTester tester) async {
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('Episode One'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/2'),
      title: Value('Episode Two'),
      videoPath: Value('/abs/ep2.mp4'),
    ));
    final int tagId = await db.createTag('Anime', 0xFF2196F3);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await enterSelectionMode(tester);
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.tap(find.byKey(const ValueKey<String>('home_video_video/2')));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    // 点批量打标签按钮（批量栏的 sell_outlined）→ 打开三态 picker。dialog 打开前
    // 页面上只有批量栏一个 sell_outlined（卡片标签层用 FushiTagChip，不是该图标）。
    await tester.tap(find.byIcon(Icons.sell_outlined).last);
    await tester.pumpAndSettle();
    expect(find.text(t.batch_tag_title), findsOneWidget);

    // 把「Anime」设为「添加」（segmented 的 + 段）：在 SegmentedButton 内定位 + 图标，
    // 避开页头导入按钮（也是 Icons.add，TODO-064 起恒渲染）。
    final Finder segmentedButton = find.byWidgetPredicate(
      (Widget w) => w is SegmentedButton,
    );
    expect(segmentedButton, findsWidgets);
    await tester.tap(find.descendant(
      of: segmentedButton.first,
      matching: find.byIcon(Icons.add),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.batch_tag_apply));
    await tester.pumpAndSettle();

    expect(
      (await db.getTagsForVideoBook('video/1')).map((BookTagRow x) => x.id),
      contains(tagId),
    );
    expect(
      (await db.getTagsForVideoBook('video/2')).map((BookTagRow x) => x.id),
      contains(tagId),
    );
  });
}

/// 合法 1x1 PNG：封面 fixture 必须是**真能解码**的图片。此前写的是纯文本
/// （'cover-one'），只因当时布局下封面没被绘制才没暴露；P5-A 加了库页搜索框后
/// 布局变化让封面真的进了绘制，Image.file 解码即抛 'Invalid image data'。
const List<int> _kOnePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
