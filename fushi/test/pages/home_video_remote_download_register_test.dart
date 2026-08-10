import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

/// TODO-820：互联下载对端视频后必须建 VideoBooks 行，否则下载好的文件躺磁盘但视频
/// 列表（唯一数据源是 VideoBooks 行）根本看不到。这里在真实下载路径上断言「下载完
/// DB 确有该行」「重复下载 upsert 同行不重复」「host 有字幕则连带写入 cue」。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_dl_register_pp');
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
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_dl_register_store');
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
            home: Scaffold(
              body: HomeVideoPage(
                repo: repo,
                // #792 分区化：home 分区只渲染 dashboard 概览，远端占位卡所在的
                // 混排墙（_buildLocalVideoSlivers）搬进了 series 分区，钉住它。
                section: VideoLibrarySection.series,
                remoteVideoClientLoader: () async => client,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  /// 触发下载并等到整条下载链在本 runAsync zone 内彻底排干为止。下载注册关键路径有真实
  /// 文件 IO（下载写盘、字幕读盘、封面抽帧跑 ffmpeg 子进程），fake async 在 widget 测试里
  /// 必须经 [WidgetTester.runAsync] 才会真正完成；不用 pumpAndSettle（会等 ffmpeg 进程静止
  /// 而超时）。
  ///
  /// 完成信号取 [InterconnectDownloadManager] 任务的**终态**而非「DB 行出现 + 固定多等几拍」：
  /// [InterconnectDownloadManager.startVideoDownload] 在标 completed 前 await 了整链（下载 →
  /// onComplete 建行 + 字幕 + ffmpeg 封面抽帧），故任务到达 completed/failed = 全部真实异步
  /// 已排干，无 pending ffmpeg future 泄漏到下个测试（旧实现靠 `i > 6` 固定迭代数瞎猜排干
  /// 时机）。等待用 [Stopwatch] 墙钟兜底（高分辨率、不受 Windows ~15.6ms 定时器粒度影响，
  /// 早退保持快路径）——旧实现固定 200 次 20ms 迭代在满负载多 isolate 争用下会被批量 timer
  /// 饿死（isolate 长时间被抢占后 200 个到期定时器瞬间连发、下载续体尚未调度就退出）而误红。
  Future<void> tapDownloadAwaitRow(WidgetTester tester) async {
    final InterconnectDownloadManager manager =
        ProviderScope.containerOf(tester.element(find.byType(HomeVideoPage)))
            .read(interconnectDownloadManagerProvider);
    // UI 巡检 PR-4：封面内嵌下载按钮已撤，下载入口 = 长按卡片弹面板 → 「下载」。
    await tester.longPress(find.byKey(
      const ValueKey<String>('remote_video_card_remote-clip'),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text(t.remote_video_download));
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final InterconnectDownloadTask? task = manager.tasks['remote-clip'];
        if (task != null && task.status != InterconnectDownloadStatus.running) {
          return;
        }
      }
    });
    await tester.pump();
  }

  testWidgets('下载对端视频后建出 VideoBooks 行（bookUid=video.id，videoPath=落地路径）',
      (WidgetTester tester) async {
    final _FakeRemoteVideoClient client = _FakeRemoteVideoClient(
      videos: <RemoteVideoInfo>[
        const RemoteVideoInfo(id: 'remote-clip', title: 'Remote Clip'),
      ],
    );
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    // 下载前列表无该行（根因：下载前视频不在 VideoBooks）。
    expect(await repo.getByBookUid('remote-clip'), isNull);

    await tapDownloadAwaitRow(tester);

    // 撤掉 saveVideoBook 建行后此断言转红（行不存在）。
    final VideoBookRow? row = await repo.getByBookUid('remote-clip');
    expect(row, isNotNull);
    expect(row!.title, 'Remote Clip');
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
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('remote-clip'),
      title: Value('Remote Clip'),
      videoPath: Value('/dl/remote-clip.mp4'),
    ));
    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('remote-clip'),
      title: Value('Remote Clip Re-downloaded'),
      videoPath: Value('/dl/remote-clip-2.mp4'),
    ));
    final List<VideoBookRow> rows = await repo.listAll();
    expect(rows.where((VideoBookRow r) => r.bookUid == 'remote-clip'),
        hasLength(1));
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
}

class _FakeRemoteVideoClient implements RemoteVideoClient {
  _FakeRemoteVideoClient({
    required this.videos,
    this.subtitleContent,
  });

  final List<RemoteVideoInfo> videos;
  final String? subtitleContent;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => videos;

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id,
          {int episodeIndex = 0}) async =>
      const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

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
  }) async {
    await dest.create(recursive: true);
    await dest.writeAsBytes(<int>[0, 0, 0]);
    onProgress?.call(1.0);
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}
