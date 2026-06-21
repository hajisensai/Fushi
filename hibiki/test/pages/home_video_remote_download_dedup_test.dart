import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_dl_pp');
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

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_dl_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
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
                repo: VideoBookRepository(db),
                remoteVideoClientLoader: () async => client,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  testWidgets('#6 远端与本地同 bookUid 的视频在配对区被去重隐藏', (WidgetTester tester) async {
    // 本地已有 video/dup（与远端某条同 id）。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/dup'),
      title: Value('Local Dup'),
      videoPath: Value('/abs/dup.mp4'),
    ));

    await tester.pumpWidget(buildApp(
      client: _ListFakeRemoteVideoClient(<RemoteVideoInfo>[
        RemoteVideoInfo(id: 'video/dup', title: 'Dup On Remote'),
        RemoteVideoInfo(id: 'video/only-remote', title: 'Only Remote'),
      ]),
    ));
    await tester.pumpAndSettle();

    // 去重：远端的 Dup 卡片不再出现，只剩 only-remote。
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_video_dup')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_video_only-remote')),
      findsOneWidget,
    );
  });

  testWidgets('#3 远端视频下载中显示进度徽章（进行中反馈），下载按钮被替换', (WidgetTester tester) async {
    final _GatedFakeRemoteVideoClient client = _GatedFakeRemoteVideoClient();
    await tester.pumpWidget(buildApp(client: client));
    await tester.pumpAndSettle();

    // 点下载：进入下载中态，badge 出现、原下载按钮被替换（用户看到进行中反馈）。
    await tester.tap(find.byKey(
      const ValueKey<String>('remote_video_download_remote_video-1'),
    ));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(
          const ValueKey<String>('remote_video_downloading_remote_video-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(
          const ValueKey<String>('remote_video_download_remote_video-1')),
      findsNothing,
    );

    // 收尾：放行下载让 finally 跑完，避免 pending future 泄漏告警。
    client.completer.complete();
    await tester.pump();
  });

  test('#3 源码守卫：视频/书下载 client==null 走明确提示分支（不再静默 return）', () {
    final String video =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    // _downloadRemote 的 client==null 分支里必须弹 remote_video_unavailable。
    expect(video, contains('t.remote_video_unavailable'));
    // 下载必须接 onProgress 才能给进行中反馈。
    expect(video, contains('onProgress:'));

    final String book = readReaderHistorySource();
    expect(book, contains('t.remote_book_unavailable'));
    expect(book, contains('onProgress:'));
  });
}

class _ListFakeRemoteVideoClient implements RemoteVideoClient {
  _ListFakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => _videos;

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id) async =>
      const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    await dest.writeAsBytes(<int>[1]);
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs,
  ) async {}
}

class _GatedFakeRemoteVideoClient implements RemoteVideoClient {
  final Completer<void> completer = Completer<void>();

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'remote/video-1', title: 'Gated'),
      ];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id) async =>
      const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.3);
    await completer.future;
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id,
  ) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs,
  ) async {}
}
