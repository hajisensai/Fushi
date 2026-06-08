import 'dart:io';

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

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_pp');
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
  late _FakeRemoteVideoClient remoteClient;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    remoteClient = _FakeRemoteVideoClient();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeVideoPage(
                repo: VideoBookRepository(db),
                remoteVideoClientLoader: () async => remoteClient,
                remoteVideoDownloadDestination: (RemoteVideoInfo video) async =>
                    File('${pathProviderDir.path}/${video.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  testWidgets('video tab exposes Hibiki interconnect remote videos',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text(t.remote_video_interconnect), findsOneWidget);
    expect(find.text(t.remote_video_paired_device), findsOneWidget);
    expect(find.text('Remote Episode'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'remote_video_download_remote_video-1',
      )),
      findsOneWidget,
    );

    final String source =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    expect(source, isNot(contains('浏览电脑')));
    expect(source.toLowerCase(), isNot(contains('computer')));
  });

  testWidgets('remote video download action downloads to this device',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>(
      'remote_video_download_remote_video-1',
    )));
    await _pumpUntil(
      tester,
      () => remoteClient.downloadedIds.isNotEmpty,
    );

    expect(remoteClient.downloadedIds, <String>['remote/video-1']);
  });
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done,
) async {
  for (int i = 0; i < 20; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _FakeRemoteVideoClient implements RemoteVideoClient {
  final List<String> downloadedIds = <String>[];

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      const <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'remote/video-1',
          title: 'Remote Episode',
          sizeBytes: 1024,
          hasSubtitle: true,
        ),
      ];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id) async =>
      const RemoteVideoStreamUrls(
        streamUrl:
            'http://127.0.0.1:1/api/library/videos/remote/video-1/stream',
        subtitleUrl:
            'http://127.0.0.1:1/api/library/videos/remote/video-1/subtitle',
      );

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    await dest.writeAsString('1\n00:00:00,000 --> 00:00:01,000\n字幕\n');
    onProgress?.call(1);
  }

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    downloadedIds.add(id);
    await dest.writeAsBytes(<int>[1, 2, 3]);
    onProgress?.call(1);
  }
}
