import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_book_client.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

// TODO-768 / BUG-416: long-press on a remote book/video card must open the
// options dialog (like local cards) instead of downloading (book card) or doing
// nothing (video card). Short-press behaviour is unchanged.
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_longpress_pp');
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
  late File remoteCover;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_longpress_store');
    remoteCover = File('${storeDir.path}/remote-cover.png')
      ..writeAsBytesSync(_tinyPngBytes);
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildBookShelf(_FakeRemoteBookClient client) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          hibikiBooksProvider.overrideWith(
            (ref, language) =>
                Future<List<MediaItem>>.value(const <MediaItem>[]),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) => Spacing(
              dataBuilder: (_) => SpacingData.generate(10),
              child: child ?? const SizedBox.shrink(),
            ),
            home: Scaffold(
              body: ReaderHibikiHistoryPage(
                remoteBookClientLoader: () async => client,
                remoteBookDownloadDestination: (RemoteBookInfo book) async =>
                    File('${pathProviderDir.path}/${book.title.hashCode}.epub'),
                remoteBookImporter: (File file) async => 'local-book-key',
              ),
            ),
          ),
        ),
      );

  testWidgets(
      'long-press remote book card opens the action dialog instead of '
      'downloading (BUG-416)', (WidgetTester tester) async {
    final _FakeRemoteBookClient client =
        _FakeRemoteBookClient(coverPath: remoteCover.path);
    await tester.pumpWidget(buildBookShelf(client));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(
      const ValueKey<String>('remote_book_card_Remote_Book'),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.remote_book_info), findsOneWidget);
    expect(client.downloadedTitles, isEmpty,
        reason: 'long-press must open the dialog, not download immediately');
  });

  testWidgets('tapping the remote book card still downloads (BUG-416)',
      (WidgetTester tester) async {
    final _FakeRemoteBookClient client =
        _FakeRemoteBookClient(coverPath: remoteCover.path);
    await tester.pumpWidget(buildBookShelf(client));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(
        const ValueKey<String>('remote_book_card_Remote_Book'),
      ));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (client.downloadedTitles.isNotEmpty) break;
      }
    });
    await tester.pump();

    expect(client.downloadedTitles, <String>['Remote Book'],
        reason: 'short tap on a remote book card downloads it');
  });

  Widget buildVideoTab(_FakeRemoteVideoClient client) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
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

  testWidgets(
      'long-press remote video card opens the action dialog without starting '
      'playback (BUG-416)', (WidgetTester tester) async {
    final _FakeRemoteVideoClient client =
        _FakeRemoteVideoClient(coverPath: remoteCover.path);
    await tester.pumpWidget(buildVideoTab(client));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(
      const ValueKey<String>('remote_video_card_remote_video-1'),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.remote_video_info), findsOneWidget);
    expect(find.byType(VideoHibikiPage), findsNothing,
        reason: 'long-press must open the dialog, not the remote player');
  });

  test(
      'remote book card onLongPress is bound to _showRemoteBookDialog '
      '(BUG-416 guard)', () {
    final String src =
        File('lib/src/pages/implementations/reader_history/remote.part.dart')
            .readAsStringSync();
    expect(src, contains('onLongPress: () => _showRemoteBookDialog(book)'),
        reason: 'long-press must open the options dialog');
    expect(src, isNot(contains('onLongPress: () => _downloadRemoteBook(book)')),
        reason: 'long-press must NOT download directly (regression guard)');
  });

  test(
      'remote video card onLongPress is bound to _showRemoteVideoDialog '
      '(BUG-416 guard)', () {
    final String src =
        File('lib/src/pages/implementations/home_video_page.dart')
            .readAsStringSync();
    expect(src, contains('onLongPress: () => _showRemoteVideoDialog(video)'),
        reason: 'long-press must open the options dialog');
  });
}

class _FakeRemoteBookClient implements RemoteBookClient {
  _FakeRemoteBookClient({required this.coverPath});

  final String coverPath;
  final List<String> downloadedTitles = <String>[];

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => <RemoteBookInfo>[
        RemoteBookInfo.fromJson(<String, Object?>{
          'title': 'Remote Book',
          'hasContent': true,
          'coverPath': coverPath,
        }),
      ];

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    downloadedTitles.add(title);
    await destination.writeAsBytes(<int>[1, 2, 3]);
    onProgress?.call(1);
  }

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

class _FakeRemoteVideoClient implements RemoteVideoClient {
  _FakeRemoteVideoClient({required this.coverPath});

  final String coverPath;
  final List<String> streamUrlRequests = <String>[];

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => <RemoteVideoInfo>[
        RemoteVideoInfo.fromJson(<String, Object?>{
          'id': 'remote_video-1',
          'title': 'Remote Episode',
          'hasSubtitle': true,
          'coverPath': coverPath,
        }),
      ];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id) async {
    streamUrlRequests.add(id);
    return const RemoteVideoStreamUrls(
      streamUrl: 'http://127.0.0.1:1/api/library/videos/remote/video-1/stream',
    );
  }

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
  }) async {}

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

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
