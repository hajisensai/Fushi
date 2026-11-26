import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';
import '../helpers/fake_image_bytes.dart';
import '../helpers/shell_layout.dart';

/// TODO-820：互联下载对端视频后必须建 VideoBooks 行，否则下载好的文件躺磁盘但视频
/// 列表（唯一数据源是 VideoBooks 行）根本看不到。这里在真实下载路径上断言「下载完
/// DB 确有该行」「重复下载 upsert 同行不重复」「host 有字幕则连带写入 cue」。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_remote_dl_register_pp',
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
  late AppModel appModel;
  late VideoBookRepository repo;

  setUp(() async {
    // BUG-1400（本文件此前 flaky，第三个用例约 20% 概率红在 `expect(row, isNotNull)`）：
    // 登记链路要经 [AppPaths.videoSubtitlesDirectory] 派生字幕落点，而 `AppPaths` 的每次
    // 根解析都 await `SharedPreferences.getInstance()`。不装 mock 时该调用落到**真实**
    // 平台通道，应答只能由真实事件循环投递；`testWidgets` 的 fake async 相位里投递不到，
    // 而 `SharedPreferences` 把首次调用的 completer 记在**进程级静态字段**上——于是一次
    // 在 fake async 相位发起的解析会把整个 isolate 的 prefs 永久钉死，后面所有 `AppPaths`
    // 解析（包括 `runAsync` 里的下载登记链）都 join 这条死 future 而挂住，任务停在
    // running、行永远写不出来。装上 mock 后应答在**进程内**以 microtask 完成，fake async
    // 相位内即解析完毕，跨相位依赖被彻底消除（守卫见
    // `test/storage/app_paths_fakeasync_prefs_channel_test.dart`）。
    // 同目录 20+ 个 `home_video_*` / `galgame_*` widget 测试早已是这个约定，本文件漏了。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 封面锁是进程级静态量，上一条用例 fake zone 里没跑完的持锁者不会再被推进；
    // 契约见 VideoCoverMutationGate.debugResetForTesting。
    VideoCoverMutationGate.debugResetForTesting();
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    // BUG-2835：「全部视频」默认只看非系列，而这里的对端视频带合集归属——本文件测
    // 的是下载登记，不是系列筛选，固定看全部。
    await prefs.setVideoAllSeriesFilterName('all');
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_remote_dl_register_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    repo = VideoBookRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp({required RemoteVideoClient client}) => ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        theme: gridShellTheme(),
        home: Scaffold(
          body: HomeVideoPage(
            repo: repo,
            // #792 分区化：home 分区只渲染 dashboard 概览，远端占位卡所在的
            // 混排墙（_buildLocalVideoSlivers）搬进了 series 分区，钉住它。
            section: VideoLibrarySection.allVideos,
            remoteVideoClientLoader: () async => client,
            remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
          ),
        ),
      ),
    ),
  );

  /// 触发下载并等到整条下载链彻底排干为止。下载登记关键路径有真实文件 IO（下载写盘、
  /// 字幕读盘、封面落盘 / ffmpeg 抽帧），fake async 在 widget 测试里必须经
  /// [WidgetTester.runAsync] 才会真正完成；不用 pumpAndSettle（会等 ffmpeg 进程静止而超时）。
  ///
  /// 完成信号 = [InterconnectDownloadManager] 任务到达**终态**且 [VideoCoverMutationGate]
  /// 空闲：startVideoDownload 在标 completed 前 await 了整条登记链（建行 + 字幕 + 封面），
  /// 锁空闲说明没有封面写入者留在锁里泄漏到下一条用例。
  ///
  /// 等待循环**交替**推进两个 zone：`runAsync` 一小片让真实 IO 与登记链（点击发生在
  /// runAsync 里，登记链跑在真实 zone）往前走，随后 `pump` 推进 fake zone 的假时钟与
  /// 微任务。后者不可省——页面自己的后台封面任务（视频 uid 流触发的
  /// `_maybeBackfillCovers`、进页的 `runMemberCoverCleanup`）挂在 fake zone，会抢到进程级
  /// [VideoCoverMutationGate] 后停在下一个假微任务 / 假定时器上；只在 runAsync 里空转
  /// 时它永远不放锁，登记链的封面步骤排在后面直到墙钟上限（Linux CI 上 31～32 秒、
  /// coverPath 为 null 的间歇红就是这个；由「fake 区后台任务持封面锁时」那条用例钉住）。
  ///
  /// 墙钟上限到点**直接判失败**并带出任务状态与封面锁持有者调用栈，不静默往下走到
  /// 后面的断言上去（那样只会看到一个与根因无关的 `coverPath == null`）。
  Future<void> tapDownloadAwaitRow(WidgetTester tester) async {
    final InterconnectDownloadManager manager = ProviderScope.containerOf(
      tester.element(find.byType(HomeVideoPage)),
    ).read(interconnectDownloadManagerProvider);
    // UI 巡检 PR-4：封面内嵌下载按钮已撤，下载入口 = 长按卡片弹面板 → 「下载」。
    // BUG-2835：「全部视频」多了一行筛选，800x600 视口里卡片可能落在折线下。
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('remote_video_card_remote-clip')),
    );
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey<String>('remote_video_card_remote-clip')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text(t.remote_video_download)));
    final Stopwatch sw = Stopwatch()..start();
    while (true) {
      final InterconnectDownloadTask? task = manager.tasks['remote-clip'];
      final bool taskDone =
          task != null && task.status != InterconnectDownloadStatus.running;
      if (taskDone && VideoCoverMutationGate.debugIsIdle) return;
      if (sw.elapsed >= const Duration(seconds: 30)) {
        fail(
          '下载登记链 30 秒内未排干：'
          'task=${task == null ? '(未建)' : '${task.status} error=${task.error}'}；'
          '封面锁 ${VideoCoverMutationGate.debugDescribeState()}',
        );
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// 卸掉页面并让封面图的真实读盘收尾（打开 → 读 → 关）。
  ///
  /// 书架卡经 `FileImage` 读落盘的 `<uid>.cover.jpg`，读盘的续体排在 fake zone 里：用例体
  /// 结束后没人再 pump，句柄就一直开着。本文件的路径提供目录跨用例共享，下一条用例的
  /// 登记链会先删同名封面再写——Windows 上删一个还开着的文件直接抛「另一个程序正在
  /// 使用此文件」，封面落不了盘（`coverPath == null`）。所以显示过落盘封面的用例在
  /// 用例体内卸页，交替给真实 I/O 时间与 pump，直到句柄关掉。
  Future<void> releaseCoverFileHandles(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    imageCache.clear();
    imageCache.clearLiveImages();
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('下载对端视频后建出 VideoBooks 行（bookUid=video.id，videoPath=落地路径）', (
    WidgetTester tester,
  ) async {
    final _FakeRemoteVideoClient client = _FakeRemoteVideoClient(
      videos: <RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: 'remote-clip',
          title: 'Remote Clip',
          collection: RemoteCollectionMembership(
            collectionName: 'Series',
            collectionType: 'playlist',
            sortIndex: 3,
          ),
        ),
      ],
    );
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    // 下载前列表无该行（根因：下载前视频不在 VideoBooks）。
    expect(await repo.getByBookUid('remote-clip'), isNull);
    final List<MediaCollectionRow> listedCollections = await db
        .getAllMediaCollections();
    expect(listedCollections, hasLength(1), reason: '目录加载建立合集壳');
    expect(
      (await db.getCollectionItems(
        listedCollections.single.id,
      )).single.entryKey,
      'remote-clip',
    );
    // 模拟目录之后关系缺失，证明下载登记自身也走收养服务。
    await db.delete(db.mediaCollectionItems).go();
    await db.delete(db.mediaCollections).go();

    await tapDownloadAwaitRow(tester);

    // 撤掉 saveVideoBook 建行后此断言转红（行不存在）。
    final VideoBookRow? row = await repo.getByBookUid('remote-clip');
    expect(row, isNotNull);
    expect(row!.title, 'Remote Clip');
    final List<MediaCollectionRow> collections = await db
        .getAllMediaCollections();
    expect(collections, hasLength(1));
    expect(
      (await db.getCollectionItems(collections.single.id)).single.entryKey,
      row.bookUid,
    );
    expect(
      row.videoPath,
      '${pathProviderDir.path}/${'remote-clip'.hashCode}.mp4',
    );
  });

  // 重复下载去重的保证来自「bookUid 恒为稳定 video.id + saveVideoBook 是 upsert」。
  // 首测试已验证 UI 下载路径建行用 bookUid=video.id；这里在 repo 层验证「同 bookUid
  // 二次写只覆盖同一行、不新增条目」（第一次下载后该卡已从配对区去重消失，UI 无法重复
  // tap，故去重不靠 UI 二次点击而靠稳定身份 + upsert）。
  test('重复下载同一对端视频 upsert 同一行（同 video.id 不新增条目）', () async {
    await repo.saveVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('remote-clip'),
        title: Value('Remote Clip'),
        videoPath: Value('/dl/remote-clip.mp4'),
      ),
    );
    await repo.saveVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('remote-clip'),
        title: Value('Remote Clip Re-downloaded'),
        videoPath: Value('/dl/remote-clip-2.mp4'),
      ),
    );
    final List<VideoBookRow> rows = await repo.listAll();
    expect(
      rows.where((VideoBookRow r) => r.bookUid == 'remote-clip'),
      hasLength(1),
    );
    final VideoBookRow row =
        await repo.getByBookUid('remote-clip') as VideoBookRow;
    expect(row.title, 'Remote Clip Re-downloaded');
    expect(row.videoPath, '/dl/remote-clip-2.mp4');
  });

  testWidgets('host 有外挂字幕时连带下载并解析成 cue 写入', (WidgetTester tester) async {
    final _FakeRemoteVideoClient client = _FakeRemoteVideoClient(
      videos: <RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: 'remote-clip',
          title: 'Remote Clip',
          hasSubtitle: true,
          subtitleFileName: 'remote-clip.srt',
        ),
      ],
      subtitleContent: '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n',
    );
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    await tapDownloadAwaitRow(tester);

    final VideoBookRow? row = await repo.getByBookUid('remote-clip');
    expect(row, isNotNull);
    expect(row!.subtitleFormat, 'srt');
    expect(row.subtitleSource, isNotNull);
    final List<dynamic> cues = await repo.loadCues('remote-clip');
    expect(cues, isNotEmpty);
  });

  // 7c：host 已刮好的封面 / importedAt / completedAt 此前下载后全部丢失（无条件抽帧、
  // importedAt 写本机 now、completedAt 不写）。
  testWidgets('下载登记镜像 host 封面（coverUrl）、importedAt 与 completedAt', (
    WidgetTester tester,
  ) async {
    final _FakeCoverRemoteVideoClient client = _FakeCoverRemoteVideoClient(
      videos: <RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: 'remote-clip',
          title: 'Remote Clip',
          coverUrl: 'http://x/videos/remote-clip/cover',
          importedAt: 1700000000000,
          completedAt: 1700000500000,
        ),
      ],
      // 写侧唯一入口只收可解码字节（BUG-2496）；远端卡片还会经 RemoteCoverImage
      // 真的解码同一份字节，只有外形合法的假图会抛 Invalid image data，所以用真图。
      coverBytes: decodableTinyPngBytes(),
    );
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    await tapDownloadAwaitRow(tester);

    final VideoBookRow? row = await repo.getByBookUid('remote-clip');
    expect(row, isNotNull);
    expect(
      row!.importedAt,
      1700000000000,
      reason: 'importedAt 镜像 host 值，下载后不该在「按导入时间」里跳位',
    );
    expect(
      row.completedAt?.millisecondsSinceEpoch,
      1700000500000,
      reason: 'completedAt 镜像 host 值，已看完角标不丢',
    );
    // 远端卡片本身也经 RemoteCoverImage 显示 host 封面（同一 URL；widget 测试的假异步里
    // 磁盘读盘缓存落不了地，重绘会再拉），所以不钉次数：登记路径拉的是 host 封面，
    // 由下面「落盘字节 = host 下发字节」（而不是抽帧）钉住。
    expect(client.coverFetches.toSet(), <String>{
      'http://x/videos/remote-clip/cover',
    }, reason: 'host 有 coverUrl 时先拉 host 封面');
    expect(row.coverPath, isNotNull);
    expect(File(row.coverPath!).readAsBytesSync(), decodableTinyPngBytes());
    await releaseCoverFileHandles(tester);
  });

  // 上一条在 Linux CI 上的间歇红（coverPath 为 null、用例卡满 30 秒）：页面自己的后台
  // 封面任务（视频 uid 流触发的 `_maybeBackfillCovers`、进页的 `runMemberCoverCleanup`）
  // 跑在 testWidgets 的 fake-async zone，而下载登记链跑在 runAsync 的真实 zone。两者争
  // 进程级 [VideoCoverMutationGate]：fake 区持锁者的续体只在 pump（推进假时钟 / 抽干假
  // 微任务）时才走，等待循环若只在 runAsync 里空转，登记链就排在锁后面直到墙钟上限。
  // 这里在 fake 区确定性地造一个「要推进假时钟才会放锁」的持锁者，钉住等待循环必须
  // 一边给真实 IO 时间、一边 pump fake 区，否则登记永远拿不到锁。
  testWidgets('fake 区后台任务持封面锁时，下载登记仍拿到 host 封面', (WidgetTester tester) async {
    final _FakeCoverRemoteVideoClient client = _FakeCoverRemoteVideoClient(
      videos: <RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: 'remote-clip',
          title: 'Remote Clip',
          coverUrl: 'http://x/videos/remote-clip/cover',
        ),
      ],
      coverBytes: decodableTinyPngBytes(),
    );
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    // 持锁者跨过「点下载」：要等下载任务出现（登记链已起跑）才放锁，而它轮询用的是
    // fake 区定时器——与真实的回填 / 清理一样，只有 pump 推进假时钟它才会往下走。
    final InterconnectDownloadManager manager = ProviderScope.containerOf(
      tester.element(find.byType(HomeVideoPage)),
    ).read(interconnectDownloadManagerProvider);
    bool holderReleased = false;
    unawaited(
      VideoCoverMutationGate.runExclusive(() async {
        while (manager.tasks['remote-clip'] == null) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        holderReleased = true;
      }),
    );

    await tapDownloadAwaitRow(tester);

    expect(holderReleased, isTrue);
    final VideoBookRow? row = await repo.getByBookUid('remote-clip');
    expect(row, isNotNull);
    expect(row!.coverPath, isNotNull);
    expect(File(row.coverPath!).readAsBytesSync(), decodableTinyPngBytes());
  });
}

class _FakeCoverRemoteVideoClient extends _FakeRemoteVideoClient
    implements RemoteCoverFetcher {
  _FakeCoverRemoteVideoClient({
    required super.videos,
    required this.coverBytes,
  });

  final List<int> coverBytes;
  final List<String> coverFetches = <String>[];

  @override
  String get coverCacheNamespace => 'test';

  @override
  Future<Uint8List> fetchRemoteCover(String coverUrl) async {
    coverFetches.add(coverUrl);
    return Uint8List.fromList(coverBytes);
  }
}

class _FakeRemoteVideoClient implements RemoteVideoClient {
  _FakeRemoteVideoClient({required this.videos, this.subtitleContent});

  final List<RemoteVideoInfo> videos;
  final String? subtitleContent;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => videos;

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
  }) async {
    await dest.create(recursive: true);
    await dest.writeAsString(subtitleContent ?? '');
  }

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    await dest.create(recursive: true);
    await dest.writeAsBytes(<int>[0, 0, 0]);
    onProgress?.call(1.0);
  }

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
