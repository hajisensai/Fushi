// BUG-2458（视频侧）：视频库多选态点远端占位卡必须是勾选，不能直接开流播；勾选
// 后经批量栏「下载」串行下载；本地三动作（组合 / 标签 / 删除）对纯远端选中集禁用。
// 网格与列表两种布局各钉一次——两者此前各抄一份 handleTap，现统一走 _dispatchCardTap。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_msel_pp');
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
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late _GatedRemoteVideoClient remoteClient;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_video_msel_store');
    final File cover = File('${storeDir.path}/cover.png')
      ..writeAsBytesSync(_tinyPngBytes);
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    remoteClient = _GatedRemoteVideoClient(coverPath: cover.path);
  });

  tearDown(() async {
    await db.close();
  });

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
                section: VideoLibrarySection.allVideos,
                remoteVideoClientLoader: () async => remoteClient,
                remoteVideoDownloadDestination: (RemoteVideoInfo video) async =>
                    File('${pathProviderDir.path}/${video.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  /// 默认 800×600 视口下网格第一行落在底部批量栏（多选态出现）之下，tap 命不中；
  /// 放大视口让卡片与批量栏互不遮挡。
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Finder remoteCard(int n) =>
      find.byKey(ValueKey<String>('remote_video_card_remote_video-$n'));

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
  }

  bool batchButtonEnabled(WidgetTester tester, String key) =>
      tester.widget<FushiIconButton>(find.byKey(ValueKey<String>(key))).enabled;

  testWidgets('多选态点远端视频卡 = 勾选，不建流播；本地动作对纯远端选中集禁用', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(remoteCard(1), findsOneWidget);

    await enterSelectionMode(tester);
    await tester.tap(remoteCard(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(remoteClient.streamUrlRequests, isEmpty,
        reason: '多选态点远端卡必须是勾选，不能像 BUG-2458 那样直接开流播');
    expect(remoteClient.downloadedIds, isEmpty);
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget,
        reason: '远端卡要真进选中集（底栏计数）');
    expect(batchButtonEnabled(tester, 'home_video_batch_download'), isTrue,
        reason: '选了远端卡，批量「下载」可用');
    expect(batchButtonEnabled(tester, 'home_video_batch_delete'), isFalse,
        reason: '删除是本地动作，纯远端选中集不能启用');
    expect(batchButtonEnabled(tester, 'home_video_batch_combine'), isFalse,
        reason: '组合是本地动作，纯远端选中集不能启用');

    // 再点一次 = 取消勾选。
    await tester.tap(remoteCard(1));
    await tester.pump();
    expect(find.text(t.batch_selected_count(n: 0)), findsOneWidget);
    expect(remoteClient.streamUrlRequests, isEmpty);
  });

  testWidgets('列表布局：多选态点远端行 = 勾选，不建流播', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(
        find.byKey(const ValueKey<String>('video-all-videos-layout-toggle')));
    await tester.pumpAndSettle();
    final Finder remoteRow =
        find.byKey(const ValueKey<String>('remote_video_list_remote_video-2'));
    expect(remoteRow, findsOneWidget);

    await enterSelectionMode(tester);
    await tester.tap(remoteRow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(remoteClient.streamUrlRequests, isEmpty,
        reason: '列表行与网格卡同走 _dispatchCardTap，多选态不能开流播');
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);
    expect(batchButtonEnabled(tester, 'home_video_batch_download'), isTrue);
    expect(batchButtonEnabled(tester, 'home_video_batch_delete'), isFalse);
  });

  testWidgets('勾选两个远端视频 → 批量「下载」串行只下勾选项并退出多选', (WidgetTester tester) async {
    await pumpPage(tester);

    await enterSelectionMode(tester);
    await tester.tap(remoteCard(1));
    await tester.pump();
    await tester.tap(remoteCard(3));
    await tester.pump();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_batch_download')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(remoteClient.downloadedIds, <String>['remote/video-1'],
        reason: '串行：第一个挂在闸门上时第二个不起');
    expect(find.byIcon(Icons.checklist_outlined), findsOneWidget,
        reason: '批量下载一开始就退出多选态');

    remoteClient.release();
    for (int i = 0; i < 200 && remoteClient.downloadedIds.length < 2; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(remoteClient.downloadedIds,
        <String>['remote/video-1', 'remote/video-3'],
        reason: '只下勾选的两个、按目录序串行，未勾的 video-2 不动');
    expect(remoteClient.streamUrlRequests, isEmpty);
  });
}

/// 三个远端视频；下载体挂在 [release] 之前不结束，好让「串行」在第一个卡住时可断言。
class _GatedRemoteVideoClient implements RemoteVideoClient {
  _GatedRemoteVideoClient({required this.coverPath});

  final String coverPath;
  final List<String> downloadedIds = <String>[];
  final List<String> streamUrlRequests = <String>[];
  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => <RemoteVideoInfo>[
        for (int n = 1; n <= 3; n++)
          RemoteVideoInfo.fromJson(<String, Object?>{
            'id': 'remote/video-$n',
            'title': 'Remote Episode $n',
            'sizeBytes': 1024,
            'hasSubtitle': false,
            'coverPath': coverPath,
          }),
      ];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id,
      {int episodeIndex = 0}) async {
    streamUrlRequests.add(id);
    return const RemoteVideoStreamUrls(
      streamUrl: 'http://127.0.0.1:1/stream',
      subtitleUrl: null,
      subtitleFileName: null,
    );
  }

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
    downloadedIds.add(id);
    await _gate.future;
    await dest.writeAsBytes(<int>[1, 2, 3]);
    onProgress?.call(1);
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

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
