import 'dart:async';
import 'dart:io';

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
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_interconnect_pp');
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

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_interconnect_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp({
    required RemoteVideoClient client,
    required InterconnectDownloadManager manager,
  }) =>
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          interconnectDownloadManagerProvider.overrideWith((ref) => manager),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeVideoPage(
                repo: VideoBookRepository(db),
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

  testWidgets(
      'page badge subscribes to app-level manager progress (survives across '
      'rebuilds)', (WidgetTester tester) async {
    final _GatedClient client = _GatedClient();
    // app 级 manager 由测试持有，模拟跨页面存活的真相源。
    // Riverpod 持有 override 的 ChangeNotifier 生命周期（ProviderScope 拆除时自动
    // dispose）；测试不再手动 dispose 以免二次释放。
    final InterconnectDownloadManager manager = InterconnectDownloadManager();

    await tester.pumpWidget(buildApp(client: client, manager: manager));
    await tester.pumpAndSettle();

    // UI 巡检 PR-4：封面内嵌下载按钮已撤，下载入口 = 长按卡片弹面板 → 「下载」。
    await tester.longPress(find.byKey(
      const ValueKey<String>('remote_video_card_remote_video-1'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.remote_video_download));
    await tester.pump();
    await tester.pump();

    // 进度徽章出现（页面从 manager 读 isRunning）。
    expect(
      find.byKey(
          const ValueKey<String>('remote_video_downloading_remote_video-1')),
      findsOneWidget,
    );
    // manager（app 级真相源）确实持有该 running 任务。
    expect(manager.isRunning('remote/video-1'), isTrue);
    expect(manager.progressFor('remote/video-1'), 0.3);

    client.completer.complete();
    await tester.pumpAndSettle();
  });

  test('source guard: page delegates download to InterconnectDownloadManager',
      () {
    final String src =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    // 必须走 app 级 manager，而非页面 State Map。
    expect(src, contains('interconnectDownloadManagerProvider'));
    expect(src, contains('startVideoDownload'));
    // 旧的页面 State Map 必须已移除（任务不再挂页面 State）。
    expect(src.contains('_downloadingVideos'), isFalse);
  });
}

class _GatedClient implements RemoteVideoClient {
  final Completer<void> completer = Completer<void>();

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'remote/video-1', title: 'Gated'),
      ];

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
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.3);
    await completer.future;
    await dest.writeAsBytes(<int>[1]);
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
