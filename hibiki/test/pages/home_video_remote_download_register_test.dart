import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki_core/hibiki_core.dart';

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

  late HibikiDatabase db;
  late AppModel appModel;
  late VideoBookRepository repo;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
                remoteVideoClientLoader: () async => client,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  /// 触发下载并等到 VideoBooks 行落库为止。下载注册关键路径有真实文件 IO（下载写盘、
  /// 字幕读盘、封面抽帧跑 ffmpeg 子进程），fake async 在 widget 测试里必须经
  /// [WidgetTester.runAsync] 才会真正完成；不用 pumpAndSettle（会等 ffmpeg 进程静止
  /// 而超时）。建行在封面抽帧之前落库，故这里轮询建行落库即可、不必等封面。
  Future<void> tapDownloadAwaitRow(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(
        const ValueKey<String>('remote_video_download_remote-clip'),
      ));
      bool saved = false;
      for (int i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (!saved && await repo.getByBookUid('remote-clip') != null) {
          saved = true;
        }
        // 建行已落库后再多等几拍，让 _downloadRemote 整链（封面抽帧 ffmpeg ~0.03s +
        // updateCover 回写 + _refresh）在本 runAsync zone 内收尾，避免 pending 真实
        // 异步泄漏到下个测试（否则上一个测试的 ffmpeg future 会干扰后续测试挂起）。
        if (saved && i > 6) return;
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
